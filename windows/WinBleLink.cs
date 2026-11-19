using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Foundation;
using Windows.Storage.Streams;

namespace RedMagicMonitor;

internal sealed class WinBleLink : IDisposable
{
    private readonly BluetoothLEDevice _device;
    private readonly GattDeviceService _service;
    private readonly GattCharacteristic _tx, _rx;
    private readonly GattSession _session;
    private readonly object _sync = new();
    private readonly BleFrameDecoder _decoder = new();
    private PendingReply? _pending;

    private sealed record PendingReply(BleSpec Spec, TaskCompletionSource<byte> Value);

    private WinBleLink(BluetoothLEDevice device, GattDeviceService service, GattCharacteristic tx,
        GattCharacteristic rx, GattSession session)
    {
        (_device, _service, _tx, _rx, _session) = (device, service, tx, rx, session);
        _rx.ValueChanged += Received;
    }

    internal bool IsConnected => _session.SessionStatus == GattSessionStatus.Active ||
        _device.ConnectionStatus == BluetoothConnectionStatus.Connected;

    internal static async Task<WinBleLink> ConnectAsync(ulong address)
    {
        string? knownDeviceError = null;
        try
        {
            var known = await Wait(BluetoothLEDevice.FromBluetoothAddressAsync(address), L.T("查找缓存中的显示器蓝牙"));
            if (known is not null) return await ConnectDevice(known, address);
        }
        catch (Exception error) when (error is IOException or System.Runtime.InteropServices.COMException)
        {
            knownDeviceError = error.Message;
            TrayLog.Write(L.T("缓存中的蓝牙设备。{0}", knownDeviceError));
        }

        try
        {
            var found = await FindAdvertisement(address);
            TrayLog.Write(L.T("找到显示器蓝牙广播（{0}）。", found.Type));
            var device = await Wait(BluetoothLEDevice.FromBluetoothAddressAsync(found.Address, found.Type), L.T("打开显示器蓝牙"));
            if (device is null) throw new IOException(L.T("未找到广播对应的显示器蓝牙设备。"));
            return await ConnectDevice(device, address);
        }
        catch (IOException error) when (knownDeviceError is not null)
        {
            throw new IOException(L.T("{0} 缓存设备连接失败。{1}", error.Message, knownDeviceError), error);
        }
    }

    private static async Task<WinBleLink> ConnectDevice(BluetoothLEDevice device, ulong address)
    {
        GattDeviceService? control = null;
        GattSession? session = null;
        WinBleLink? connection = null;
        try
        {
            TrayLog.Write(L.T("正在建立 GATT 会话。Windows 蓝牙状态 {0}。", device.ConnectionStatus));
            session = await Wait(GattSession.FromDeviceIdAsync(device.BluetoothDeviceId), L.T("建立 GATT 会话"));
            if (session.CanMaintainConnection) session.MaintainConnection = true;

            var services = await DiscoverServices(device);
            control = services.Control;
            using (var identity = services.Identity)
            {
                var serial = await Characteristic(identity, 0xffd2);
                if (!serial.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Read))
                    throw new IOException(L.T("蓝牙身份特征 FFD2 不可读。"));
                var reply = await Wait(serial.ReadValueAsync(BluetoothCacheMode.Uncached), L.T("读取蓝牙身份"));
                Check(reply.Status, L.T("读取蓝牙身份"));
                if (!BleProtocol.IsIdentity(Bytes(reply.Value), address))
                    throw new UnauthorizedAccessException(L.T("FFD2 返回的蓝牙身份与本机配置不符。"));
            }

            var tx = await Characteristic(control, 0xffe1);
            var rx = await Characteristic(control, 0xffe2);
            if (!tx.CharacteristicProperties.HasFlag(GattCharacteristicProperties.WriteWithoutResponse) ||
                !rx.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Notify))
                throw new IOException(L.T("蓝牙控制服务没有所需的 FFE1 写入或 FFE2 通知属性。"));

            connection = new WinBleLink(device, control, tx, rx, session);
            Check(await Wait(rx.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify), L.T("订阅显示器蓝牙通知")), L.T("订阅蓝牙通知"));
            TrayLog.Write(L.T("WinRT GATT 已核验 FFD2 身份并订阅 FFE2。"));
            return connection;
        }
        catch
        {
            TrayLog.Write(L.T("GATT 建连未完成。Windows 蓝牙状态 {0}。", device.ConnectionStatus));
            if (connection is not null) connection.Dispose();
            else
            {
                using (device)
                using (control)
                    if (session is not null) ReleaseSession(session);
            }
            throw;
        }
    }

    internal async Task SendAsync(byte[] value)
    {
        using var writer = new DataWriter();
        writer.WriteBytes(value);
        var reply = await Wait(_tx.WriteValueWithResultAsync(writer.DetachBuffer(),
            GattWriteOption.WriteWithoutResponse), L.T("写入蓝牙指令"));
        Check(reply.Status, L.T("写入蓝牙指令"));
        TrayLog.Write(L.T("蓝牙 TX {0}", Convert.ToHexString(value)));
    }

    internal async Task<byte> QueryAsync(BleSpec spec)
    {
        var waiting = new PendingReply(spec, new(TaskCreationOptions.RunContinuationsAsynchronously));
        lock (_sync)
        {
            if (_pending is not null) throw new InvalidOperationException(L.T("已有蓝牙查询在进行中。"));
            _decoder.Reset();
            _pending = waiting;
        }
        try
        {
            await SendAsync(spec.QueryFrame());
            byte value = await waiting.Value.Task.WaitAsync(TimeSpan.FromMilliseconds(1050));
            if (!spec.Choices.Any(choice => choice.Code == value))
                throw new IOException(L.T("{0}返回未识别的值 0x{1:X2}。", spec.Name, value));
            return value;
        }
        finally
        {
            lock (_sync) if (ReferenceEquals(_pending, waiting)) _pending = null;
        }
    }

    private void Received(GattCharacteristic _, GattValueChangedEventArgs args)
    {
        try
        {
            byte[] chunk = Bytes(args.CharacteristicValue);
            lock (_sync)
            {
                if (_pending is not { } pending) return;
                foreach (var frame in _decoder.Feed(chunk))
                {
                    if (!pending.Spec.Matches(frame)) continue;
                    TrayLog.Write(L.T("蓝牙 RX {0}", Convert.ToHexString(frame)));
                    pending.Value.TrySetResult(frame[2]);
                    break;
                }
            }
        }
        catch (Exception error) when (error is ArgumentException or System.Runtime.InteropServices.COMException)
        {
            TrayLog.Write(L.T("读取蓝牙通知。{0}", error.Message));
        }
    }

    private static async Task<(GattDeviceService Identity, GattDeviceService Control)> DiscoverServices(BluetoothLEDevice device)
    {
        var reply = await Wait(device.GetGattServicesAsync(BluetoothCacheMode.Uncached), L.T("发现蓝牙服务"), 12);
        TrayLog.Write(L.T("GATT 服务发现返回 {0}，服务数 {1}。", reply.Status, reply.Services.Count));
        var services = reply.Services;
        bool accepted = false;
        GattDeviceService? identity = null, control = null;
        try
        {
            Check(reply.Status, L.T("发现蓝牙服务"));
            identity = RequireService(services, BleProtocol.IdentityUuid);
            control = RequireService(services, BleProtocol.ControlUuid);
            accepted = true;
            return (identity, control);
        }
        finally
        {
            foreach (var service in services)
                if (!accepted || (service != identity && service != control)) service.Dispose();
        }
    }

    private static GattDeviceService RequireService(IReadOnlyList<GattDeviceService> services, Guid uuid)
    {
        var matches = services.Where(service => service.Uuid == uuid).Take(2).ToArray();
        if (matches.Length == 1) return matches[0];
        throw new IOException(L.T("无法唯一找到显示器服务 {0}。", uuid));
    }

    private static async Task<GattCharacteristic> Characteristic(GattDeviceService service, ushort id)
    {
        var response = await Wait(service.GetCharacteristicsForUuidAsync(BleProtocol.Uuid(id),
            BluetoothCacheMode.Uncached), L.T("发现特征 {0:X4}", id));
        Check(response.Status, L.T("发现特征 {0:X4}", id));
        return response.Characteristics.Count == 1 ? response.Characteristics[0] :
            throw new IOException(L.T("无法唯一找到特征 {0:X4}。", id));
    }

    private static async Task<(ulong Address, BluetoothAddressType Type)> FindAdvertisement(ulong address)
    {
        var candidate = new TaskCompletionSource<(ulong, BluetoothAddressType)>(TaskCreationOptions.RunContinuationsAsynchronously);
        string name = $"REDMAGIC GM001J{address:X12}";
        var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        void Found(BluetoothLEAdvertisementWatcher _, BluetoothLEAdvertisementReceivedEventArgs e)
        {
            if (e.BluetoothAddress == address || name.Equals(e.Advertisement.LocalName, StringComparison.OrdinalIgnoreCase))
                candidate.TrySetResult((e.BluetoothAddress, e.BluetoothAddressType));
        }
        void Stopped(BluetoothLEAdvertisementWatcher _, BluetoothLEAdvertisementWatcherStoppedEventArgs e) =>
            candidate.TrySetException(new IOException(L.T("蓝牙扫描停止（{0}）。", e.Error)));
        watcher.Received += Found;
        watcher.Stopped += Stopped;
        try
        {
            watcher.Start();
            return await candidate.Task.WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch (TimeoutException) { throw new IOException(L.T("本机未找到与配置匹配的显示器蓝牙广播。")); }
        finally
        {
            watcher.Received -= Found;
            watcher.Stopped -= Stopped;
            watcher.Stop();
        }
    }

    private static async Task<T> Wait<T>(IAsyncOperation<T> operation, string action, int timeoutSeconds = 4)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
        try { return await operation.AsTask(deadline.Token); }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested)
        { throw new IOException(L.T("{0}超时。", action)); }
    }

    private static byte[] Bytes(IBuffer buffer)
    {
        using var reader = DataReader.FromBuffer(buffer);
        byte[] bytes = new byte[reader.UnconsumedBufferLength];
        reader.ReadBytes(bytes);
        return bytes;
    }

    private static void Check(GattCommunicationStatus status, string action)
    {
        if (status != GattCommunicationStatus.Success)
            throw new IOException(L.T("{0}失败（{1}）。", action, status));
    }

    public void Dispose()
    {
        _rx.ValueChanged -= Received;
        lock (_sync)
        {
            _pending?.Value.TrySetCanceled();
            _pending = null;
        }

        using (_device)
        using (_service)
            ReleaseSession(_session);
    }

    private static void ReleaseSession(GattSession session)
    {
        using (session)
            if (session.CanMaintainConnection) session.MaintainConnection = false;
    }
}