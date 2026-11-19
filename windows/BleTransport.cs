using System;
using System.Collections.Generic;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace RedMagicMonitor;

internal sealed record BleSnapshot(bool Connected, IReadOnlyDictionary<BleControl, byte> Values, string Message);

internal sealed class BleTransport(TraySettings settings)
{
    private readonly SemaphoreSlim _serial = new(1, 1);
    private WinBleLink? _link;
    private long _lastActivity = Stopwatch.GetTimestamp();
    internal const int IdleMinutes = 5;
    internal bool HasConnection => _link is not null;

    internal Task<BleSnapshot> ReadAsync() => ReadControlsAsync(inputOnly: false);
    internal Task<BleSnapshot> ReadInputAsync() => ReadControlsAsync(inputOnly: true);

    // A null result is safe to route to DDC: no input SET was submitted.
    internal async Task<bool?> TrySelectInputAsync(InputSource source)
    {
        try { await Serial(Connect); }
        catch (Exception error) when (TransportError(error))
        {
            TrayLog.Write($"快捷方式蓝牙连接不可用。{error.Message}");
            return null;
        }
        return (await SetAsync(BleControl.Input, (byte)source)).Confirmed;
    }

    private Task<BleSnapshot> ReadControlsAsync(bool inputOnly) => Serial(async () =>
    {
        var values = new Dictionary<BleControl, byte>();
        try
        {
            var link = await Connect();
            int timedOut = 0;
            foreach (var control in BleProtocol.Specs.Keys)
            {
                if (inputOnly && control != BleControl.Input) continue;
                if (IsZone(control) && values.GetValueOrDefault(BleControl.LightEffect) != 7) continue;
                try
                {
                    values[control] = await link.QueryAsync(BleProtocol.Specs[control]);
                    timedOut = 0;
                }
                catch (TimeoutException error)
                {
                    TrayLog.Write($"{BleProtocol.Specs[control].Name}查询超时。{error.Message}");
                    if (++timedOut >= 2) break;
                }
                catch (IOException error)
                {
                    TrayLog.Write(error.Message);
                    if (++timedOut >= 2) break;
                }
            }
            return new BleSnapshot(true, values, values.Count > 0 ? "蓝牙已连接，已读取可用项" : "蓝牙已连接，暂无有效回读");
        }
        catch (Exception error) when (TransportError(error))
        {
            Drop();
            TrayLog.Write(error.Message);
            return new BleSnapshot(false, values, error.Message);
        }
    });

    internal Task<WriteResult<byte>> SetAsync(BleControl control, byte value) => Serial(async () =>
    {
        var spec = BleProtocol.Specs[control];
        byte[] frame = spec.WriteFrame(value);
        var link = await Connect();

        if (IsZone(control) && await link.QueryAsync(BleProtocol.Specs[BleControl.LightEffect]) != 7)
            throw new IOException("前背灯分色只在多彩流动灯效下可调。");
        if (control == BleControl.LightPower && value == 2)
        {
            var effect = BleProtocol.Specs[BleControl.LightEffect];
            frame = effect.WriteFrame(await link.QueryAsync(effect));
        }

        // Once this operation is submitted, reconnect only to query. A lost
        // notification or a failed GATT return can occur after the monitor acted.
        try { await link.SendAsync(frame); }
        catch (Exception error) when (TransportError(error))
        {
            TrayLog.Write($"蓝牙写入结果未知。{error.Message}");
            Drop();
        }

        await Task.Delay(240);
        int reads = control == BleControl.Input ? 2 : 1;
        byte? observed = null;
        bool matched = true;
        for (int index = 0; index < reads; index++)
        {
            if (index > 0) await Task.Delay(200);
            observed = await VerifyRead(spec);
            matched &= observed == value;
        }

        return matched
            ? new WriteResult<byte>(true, value, $"{spec.Name}已读回确认")
            : new WriteResult<byte>(false, null, $"{spec.Name}回读未确认");
    });

    internal async Task<bool> AlignInputAsync(InputSource source, Func<Task<bool>> stillActive)
    {
        if (!await _serial.WaitAsync(0)) return false;
        try
        {
            var link = await Connect();
            var input = BleProtocol.Specs[BleControl.Input];
            byte target = (byte)source;
            return await AlignReportedInput(target, () => link.QueryAsync(input),
                () => link.SendAsync(input.WriteFrame(target)), stillActive);
        }
        catch (Exception error) when (TransportError(error))
        {
            TrayLog.Write($"同步菜单输入源。{error.Message}");
            Drop();
            return false;
        }
        finally
        {
            _lastActivity = Stopwatch.GetTimestamp();
            _serial.Release();
        }
    }

    internal static async Task<bool> AlignReportedInput(byte target, Func<Task<byte>> read,
        Func<Task> send, Func<Task<bool>> stillActive)
    {
        byte reported = await read();
        if (reported == target)
        {
            await Task.Delay(200);
            if (await read() == target) return true;
        }
        // Service discovery may take seconds. Recheck the physical input immediately before
        // the one possible SET to avoid undoing a newer source choice. Never queue a retry.
        if (!await stillActive()) return false;
        await send();
        await Task.Delay(240);
        byte first = await read();
        await Task.Delay(200);
        byte second = await read();
        return first == target && second == target;
    }

    private async Task<byte?> VerifyRead(BleSpec spec)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            try { return await (await Connect()).QueryAsync(spec); }
            catch (Exception error) when (TransportError(error))
            {
                TrayLog.Write($"蓝牙回读 {spec.Name}。{error.Message}");
                Drop();
            }
        }
        return null;
    }

    internal async Task<bool> DisconnectIfIdleAsync()
    {
        if (!await _serial.WaitAsync(0)) return false;
        try
        {
            if (_link is null || Stopwatch.GetElapsedTime(_lastActivity) < TimeSpan.FromMinutes(IdleMinutes)) return false;
            Drop();
            TrayLog.Write("蓝牙闲置五分钟，释放连接。");
            return true;
        }
        finally { _serial.Release(); }
    }

    internal Task<bool> DisconnectAsync() => Serial(() =>
    {
        Drop();
        return Task.FromResult(true);
    });

    private async Task<WinBleLink> Connect()
    {
        if (_link is { IsConnected: false }) Drop();
        return _link ??= await WinBleLink.ConnectAsync(settings.RequiredBleAddress());
    }

    private void Drop()
    {
        var link = _link;
        _link = null;
        if (link is null) return;
        try { link.Dispose(); }
        catch (Exception error) when (TransportError(error)) { TrayLog.Write($"释放蓝牙连接。{error.Message}"); }
    }

    private static bool IsZone(BleControl control) => control is BleControl.FrontColor or BleControl.BackColor;

    private static bool TransportError(Exception error) =>
        error is IOException or TimeoutException or COMException or UnauthorizedAccessException or InvalidOperationException or OperationCanceledException;

    private async Task<T> Serial<T>(Func<Task<T>> operation)
    {
        await _serial.WaitAsync();
        try { return await operation(); }
        finally
        {
            _lastActivity = Stopwatch.GetTimestamp();
            _serial.Release();
        }
    }
}
