using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace RedMagicMonitor;

internal sealed class DdcTransport(TraySettings settings)
{
    private readonly SemaphoreSlim _serial = new(1, 1);
    internal Task<DdcSnapshot> ReadAsync() => Serial(Read);

    internal Task<InputSource?> ReadInputAsync() => Serial(() =>
    {
        try
        {
            using var monitor = DdcDisplay.Open(settings.MonitorSerial);
            return ReadSource(monitor, OpenRaw(monitor));
        }
        catch (IOException error) { TrayLog.Write(error.Message); return null; }
    });

    private DdcSnapshot Read()
    {
        try
        {
            using var monitor = DdcDisplay.Open(settings.MonitorSerial);
            var raw = OpenRaw(monitor);
            var source = ReadSource(monitor, raw);
            int? brightness = ReadPercentage(monitor, raw, DdcControl.Brightness);
            int? contrast = ReadPercentage(monitor, raw, DdcControl.Contrast);
            int? volume = null;
            bool writable = false;
            if (raw is not null)
            {
                try { volume = raw.Read(); writable = true; }
                catch (IOException error) { TrayLog.Write(error.Message); }
            }
            if (!volume.HasValue) volume = (int?)ReadNative(monitor, (byte)DdcControl.Volume)?.Value;
            string message = source is not null || brightness is not null || contrast is not null || volume is not null
                ? "已读取显示器可用项" : "已找到显示器，DDC 暂无有效回读";
            return new(true, source, brightness, contrast, volume, writable, message,
                writable ? "显示器 3.5 mm 耳机音量" : "耳机音量写入不可用");
        }
        catch (IOException error)
        {
            TrayLog.Write(error.Message);
            return new(false, null, null, null, null, false, error.Message, "耳机音量写入不可用");
        }
    }

    internal Task<WriteResult<InputSource>> SetInputAsync(InputSource input) => Serial(() =>
    {
        string? writeError = null;
        using (var monitor = DdcDisplay.Open(settings.MonitorSerial))
        {
            try { monitor.Write(0x60, InputSources.DdcCode(input)); }
            catch (IOException error) { writeError = error.Message; }
        }
        for (int attempt = 0; attempt < 3; attempt++)
        {
            Thread.Sleep(300);
            try
            {
                using var monitor = DdcDisplay.Open(settings.MonitorSerial);
                if (ReadSource(monitor, OpenRaw(monitor)) == input)
                    return new WriteResult<InputSource>(true, input, $"已确认 {InputSources.Name(input)}");
            }
            catch (IOException error) { TrayLog.Write(error.Message); }
        }
        return new WriteResult<InputSource>(false, null, writeError ?? "已发送切源请求，回读尚未确认");
    });

    internal Task<WriteResult<int>> SetLevelAsync(DdcControl control, int percent) => Serial<WriteResult<int>>(() =>
    {
        if (percent is < 0 or > 100) throw new ArgumentOutOfRangeException(nameof(percent));
        using var monitor = DdcDisplay.Open(settings.MonitorSerial);
        if (control == DdcControl.Volume)
        {
            var raw = new NvDdcVolume(monitor.GdiName);
            raw.Read(); // Confirm this exact output can currently return a checksummed 0x62 frame.
            raw.Write(percent);
            for (int attempt = 0; attempt < 2; attempt++)
            {
                Thread.Sleep(130);
                try { if (raw.Read() == percent) return new(true, percent, "耳机音量已确认"); }
                catch (IOException error) { TrayLog.Write(error.Message); }
            }
            return new(false, null, "耳机音量回读未确认");
        }

        var transport = OpenRaw(monitor);
        var initial = ReadFeature(monitor, transport, (byte)control)
            ?? throw new IOException("显示器未返回有效的调节范围。");
        uint desired = (uint)Math.Round(percent * initial.Maximum / 100.0, MidpointRounding.AwayFromZero);
        if (desired != initial.Value) monitor.Write((byte)control, desired);
        for (int attempt = 0; attempt < 2; attempt++)
        {
            Thread.Sleep(170);
            var result = ReadFeature(monitor, transport, (byte)control);
            if (result is { } read && read.Value == desired && read.Maximum == initial.Maximum)
                return new(true, Percentage(read.Value, read.Maximum), "调节已确认");
        }
        return new(false, null, "数值回读未确认");
    });

    private static NvDdcVolume? OpenRaw(DdcDisplay monitor)
    {
        try { return new NvDdcVolume(monitor.GdiName); }
        catch (Exception error) when (error is IOException or DllNotFoundException or EntryPointNotFoundException)
        { TrayLog.Write(error.Message); return null; }
    }

    private static InputSource? ReadSource(DdcDisplay monitor, NvDdcVolume? raw) =>
        InputSources.FromDdc(ReadFeature(monitor, raw, 0x60)?.Value);

    private static int? ReadPercentage(DdcDisplay monitor, NvDdcVolume? raw, DdcControl control) =>
        ReadFeature(monitor, raw, (byte)control) is { } r ? Percentage(r.Value, r.Maximum) : null;

    private static (uint Value, uint Maximum)? ReadFeature(DdcDisplay monitor, NvDdcVolume? raw, byte code)
    {
        var native = ReadNative(monitor, code);
        if (native.HasValue) return native;
        if (raw is not null)
        {
            try { return raw.ReadStandard(code); }
            catch (IOException error) { TrayLog.Write(error.Message); }
        }
        Thread.Sleep(75);
        return ReadNative(monitor, code);
    }

    private static (uint Value, uint Maximum)? ReadNative(DdcDisplay monitor, byte code)
    {
        try
        {
            var reading = monitor.Read(code);
            bool valid = code switch
            {
                0x60 => InputSources.FromDdc(reading.Value).HasValue,
                0x62 => reading.Value <= 100,
                _ => reading.Maximum > 0 && reading.Value <= reading.Maximum
            };
            return valid ? reading : null;
        }
        catch (IOException error) { TrayLog.Write(error.Message); return null; }
    }

    private static int Percentage(uint value, uint maximum) =>
        (int)Math.Round(value * 100.0 / maximum, MidpointRounding.AwayFromZero);

    private async Task<T> Serial<T>(Func<T> work)
    {
        await _serial.WaitAsync().ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                // DXVA2 and NVAPI transactions share the same monitor reply buffer,
                // including across tray and diagnostic processes.
                using var gate = new Mutex(false, @"Local\RedMagicMonitor.Ddc.Bus");
                bool owned;
                try { owned = gate.WaitOne(TimeSpan.FromSeconds(8)); }
                catch (AbandonedMutexException) { owned = true; }
                if (!owned) throw new IOException("DDC 正在使用，请稍后重试。");
                try { return work(); }
                finally { gate.ReleaseMutex(); }
            }).ConfigureAwait(false);
        }
        finally { _serial.Release(); }
    }
}
