using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;

namespace RedMagicMonitor;

internal sealed partial class WinBleLink
{
    internal sealed record VerifiedIdentity(string Address, string DeviceId);

    internal static async Task<List<BleCandidate>> DiscoverAsync()
    {
        // Connected monitors may no longer advertise. Live advertisements also
        // find unpaired monitors without adding them to the Windows paired list.
        var cached = ConnectedCandidates();
        var live = ScanCandidates();
        await Task.WhenAll(cached, live);
        return BleCandidate.Merge(cached.Result.Concat(live.Result));
    }

    private static async Task<List<BleCandidate>> ConnectedCandidates()
    {
        const string addressProperty = "System.Devices.Aep.DeviceAddress";
        var results = new List<BleCandidate>();
        try
        {
            var devices = await Wait(DeviceInformation.FindAllAsync(
                BluetoothLEDevice.GetDeviceSelectorFromConnectionStatus(BluetoothConnectionStatus.Connected),
                new[] { addressProperty }, DeviceInformationKind.AssociationEndpoint), L.T("发现蓝牙服务"));
            foreach (var device in devices)
            {
                if (MonitorDiscovery.ModelName(device.Name, out var identity) &&
                    device.Properties.TryGetValue(addressProperty, out var value) &&
                    MonitorDiscovery.TryAddress(value as string, out var address))
                    results.Add(new(address, device.Id, device.Name, identity, false, null));
            }
        }
        catch (Exception error) when (error is IOException or COMException or UnauthorizedAccessException)
        { TrayLog.Write(error.Message); }
        return results;
    }

    private static async Task<List<BleCandidate>> ScanCandidates()
    {
        var samples = new Dictionary<ulong, BleCandidate>();
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        void ReceivedAdvertisement(BluetoothLEAdvertisementWatcher _, BluetoothLEAdvertisementReceivedEventArgs e)
        {
            var ad = e.Advertisement;
            bool service = ad.ServiceUuids.Contains(BleProtocol.IdentityUuid) || ad.ServiceUuids.Contains(BleProtocol.ControlUuid);
            bool model = MonitorDiscovery.ModelName(ad.LocalName, out var identity);
            if ((!service && !model) || e.BluetoothAddress == 0) return;
            lock (samples)
            {
                samples.TryGetValue(e.BluetoothAddress, out var previous);
                samples[e.BluetoothAddress] = new(e.BluetoothAddress, null,
                    model ? ad.LocalName : previous?.Name ?? "", identity ?? previous?.ClaimedIdentity,
                    service || previous?.AdvertisedService == true, e.BluetoothAddressType == BluetoothAddressType.Random);
            }
        }
        void StoppedWatcher(BluetoothLEAdvertisementWatcher _, BluetoothLEAdvertisementWatcherStoppedEventArgs args)
        {
            TrayLog.Write(L.T("蓝牙扫描停止（{0}）。", args.Error));
            stopped.TrySetResult();
        }
        watcher.Received += ReceivedAdvertisement;
        watcher.Stopped += StoppedWatcher;
        try
        {
            watcher.Start();
            await Task.WhenAny(stopped.Task, Task.Delay(TimeSpan.FromSeconds(4)));
        }
        catch (Exception error) when (error is IOException or COMException or UnauthorizedAccessException)
        { TrayLog.Write(error.Message); }
        finally
        {
            watcher.Received -= ReceivedAdvertisement;
            watcher.Stopped -= StoppedWatcher;
            if (watcher.Status == BluetoothLEAdvertisementWatcherStatus.Started) watcher.Stop();
        }
        lock (samples) return samples.Values.ToList();
    }

    internal static async Task<VerifiedIdentity> VerifyCandidateAsync(BleCandidate candidate)
    {
        BluetoothLEDevice? device = null;
        if (candidate.DeviceId is { } id)
        {
            try { device = await Wait(BluetoothLEDevice.FromIdAsync(id), L.T("打开显示器蓝牙")); }
            catch (Exception error) when (candidate.RandomAddress.HasValue && (error is IOException or COMException))
            { TrayLog.Write(error.Message); }
        }
        if (device == null)
        {
            var open = candidate.RandomAddress is bool random
                ? BluetoothLEDevice.FromBluetoothAddressAsync(candidate.Address, random ? BluetoothAddressType.Random : BluetoothAddressType.Public)
                : BluetoothLEDevice.FromBluetoothAddressAsync(candidate.Address);
            device = await Wait(open, L.T("打开显示器蓝牙"));
        }
        if (device == null) throw new IOException(L.T("未找到广播对应的显示器蓝牙设备。"));
        using (device)
        {
            var (identityService, control) = await DiscoverServices(device);
            using (identityService)
            using (control)
            {
                var identity = await ReadIdentity(identityService);
                bool cachedModel = MonitorDiscovery.ModelName(device.Name, out var cached);
                bool knownModel = cachedModel || MonitorDiscovery.ModelName(candidate.Name, out _);
                if ((!knownModel && !candidate.AdvertisedService) || !MonitorDiscovery.ValidIdentity(identity,
                    candidate.ClaimedIdentity, cached, device.BluetoothAddress))
                    throw new IOException(L.T("无法核实所选显示器的身份。"));
                await ControlCharacteristics(control);
                return new(string.Join(":", identity.Select(b => b.ToString("X2"))), device.DeviceId);
            }
        }
    }
}
