using RedMagicMonitor;

internal static class MonitorDiscoveryChecks
{
    internal static void Run()
    {
        const ulong address = 0x123456789abc;
        const ulong other = 0x123456789abd;
        var bytes = Convert.FromHexString("123456789ABC");
        Check(MonitorDiscovery.ModelName("redmagic gm001j123456789abc", out var claim) && claim == address,
            "exact case-insensitive monitor name and six-byte suffix");
        Check(MonitorDiscovery.ModelName("REDMAGIC GM001J", out var bare) && bare == null,
            "bare model name is a discovery hint");
        foreach (string name in new[] { "REDMAGIC phone", "REDMAGIC GM001J adapter", "REDMAGIC GM001J123456789ABC clone" })
            Check(!MonitorDiscovery.ModelName(name, out _), "reject unrelated model names");
        Check(MonitorDiscovery.TryAddress("12:34:56:78:9A:BC", out var parsed) && parsed == address &&
            MonitorDiscovery.FormatAddress(parsed) == "12:34:56:78:9A:BC", "legacy address settings");
        Check(MonitorDiscovery.ValidIdentity(bytes, address, address, other), "named identity can use a private on-air address");
        Check(MonitorDiscovery.ValidIdentity(bytes, null, null, address) &&
            !MonitorDiscovery.ValidIdentity(bytes, null, null, other), "unnamed FFD2 must agree with transport");
        Check(!MonitorDiscovery.ValidIdentity(bytes, address, other, address) &&
            !MonitorDiscovery.ValidIdentity(bytes.Reverse().ToArray(), address, null, address), "reject conflicting identity evidence");
        Check(!MonitorDiscovery.ValidIdentity([0, 0, 0, 0, 0, 0], null, null, 0) &&
            !MonitorDiscovery.ValidIdentity([255, 255, 255, 255, 255, 255], null, null, 0xffffffffffff) &&
            !MonitorDiscovery.ValidIdentity([1, 2], null, null, 0x0102), "reject invalid FFD2 payloads");

        var cached = new BleCandidate(address, "known", MonitorDiscovery.Model, null, false, null);
        var live = new BleCandidate(address, null, MonitorDiscovery.Model + "123456789ABC", address, true, false);
        var combined = BleCandidate.Merge([cached, live]).Single();
        Check(combined.DeviceId == "known" && combined.ClaimedIdentity == address && combined.AdvertisedService,
            "cached and live observations of a single endpoint merge");
        Check(BleCandidate.Merge([cached, live, live with { Address = other }]).Count == 2,
            "distinct nearby endpoints require selection even when names match");

        string previousDir = TraySettings.DirectoryPath;
        using var profile = new TemporaryProfile();
        try
        {
            TraySettings.SetDataDirectory(profile.Path);
            var settings = new TraySettings { LastPage = "Bluetooth", MonitorSerial = "existing", BluetoothAddress = "12:34:56:78:9A:BC" };
            settings.Save();
            var old = TraySettings.Load();
            Check(old.RequiredBleAddress() == address && old.Page == PanelPage.Bluetooth && old.BluetoothDeviceId == null,
                "existing manual binding still loads");
            old.BindBluetooth("12:34:56:78:9A:BD", "endpoint");
            var updated = TraySettings.Load();
            Check(updated.RequiredBleAddress() == other && updated.BluetoothDeviceId == "endpoint" &&
                updated.MonitorSerial == "existing", "verified BLE binding preserves DDC selection");
            updated.BindDdc("selected");
            Check(TraySettings.Load().MonitorSerial == "selected" && TraySettings.Load().BluetoothDeviceId == "endpoint",
                "DDC selection persists independently");
            string nonDirectory = System.IO.Path.Combine(profile.Path, "not-a-directory");
            File.WriteAllText(nonDirectory, "");
            TraySettings.SetDataDirectory(nonDirectory);
            try { updated.BindBluetooth("invalid", "invalid"); throw new Exception("Write failed to fail"); }
            catch (IOException) { }
            Check(updated.RequiredBleAddress() == other && updated.BluetoothDeviceId == "endpoint",
                "failed settings write preserves previous binding");
        }
        finally { TraySettings.SetDataDirectory(previousDir); }
    }

    private sealed class TemporaryProfile : IDisposable
    {
        internal string Path { get; } = Directory.CreateTempSubdirectory("redmagic-bind-").FullName;
        public void Dispose() => Directory.Delete(Path, recursive: true);
    }

    private static void Check(bool ok, string name)
    {
        if (!ok) throw new InvalidDataException("Discovery: " + name);
        Console.WriteLine("PASS discovery " + name);
    }
}
