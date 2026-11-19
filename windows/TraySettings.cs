using System;
using System.IO;
using System.Text.Json;
using Microsoft.Win32;

namespace RedMagicMonitor;

internal sealed class TraySettings
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    internal static string DefaultDirectoryPath { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RedMagicMonitor");
    internal static string DirectoryPath { get; private set; } = DefaultDirectoryPath;
    private static string SettingsPath => Path.Combine(DirectoryPath, "settings.json");

    public string LastPage { get; set; } = "Ddc";
    public string? MonitorSerial { get; set; }
    public string? BluetoothAddress { get; set; }
    public string? BluetoothDeviceId { get; set; }

    internal static void SetDataDirectory(string path) =>
        DirectoryPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    internal PanelPage Page
    {
        get => LastPage == nameof(PanelPage.Bluetooth) ? PanelPage.Bluetooth : PanelPage.Ddc;
        set => LastPage = value.ToString();
    }

    internal ulong RequiredBleAddress()
    {
        if (!MonitorDiscovery.TryAddress(BluetoothAddress, out var address))
            throw new InvalidOperationException(L.T("未绑定蓝牙显示器，请在蓝牙页选择显示器。"));
        return address;
    }

    internal static TraySettings Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
                return JsonSerializer.Deserialize<TraySettings>(File.ReadAllText(SettingsPath)) ?? new();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            TrayLog.Write(L.T("读取本机配置失败。{0}", error.Message));
        }
        return new();
    }

    internal void BindDdc(string serial)
    {
        var previous = MonitorSerial;
        MonitorSerial = serial;
        try { Save(); }
        catch { MonitorSerial = previous; throw; }
    }

    internal void BindBluetooth(string address, string deviceId)
    {
        var previous = (BluetoothAddress, BluetoothDeviceId);
        (BluetoothAddress, BluetoothDeviceId) = (address, deviceId);
        try { Save(); }
        catch { (BluetoothAddress, BluetoothDeviceId) = previous; throw; }
    }

    internal void Save()
    {
        Directory.CreateDirectory(DirectoryPath);
        var temporary = SettingsPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this, JsonOptions));
        File.Move(temporary, SettingsPath, overwrite: true);
    }
}

internal static class TrayLog
{
    private static readonly object Sync = new();
    internal static string PathName => Path.Combine(TraySettings.DirectoryPath, "monitor.log");

    internal static void Write(string text)
    {
        lock (Sync)
        {
            try
            {
                Directory.CreateDirectory(TraySettings.DirectoryPath);
                if (File.Exists(PathName) && new FileInfo(PathName).Length > 1_000_000)
                    File.Move(PathName, PathName + ".previous", overwrite: true);
                File.AppendAllText(PathName, $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff zzz}  {text}{Environment.NewLine}");
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }
}

internal static class LoginStartup
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Value = "RedMagicMonitor";
    private static string Command => $"\"{Environment.ProcessPath}\" --background";

    internal static bool Enabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(Key);
        return string.Equals(key?.GetValue(Value) as string, Command, StringComparison.OrdinalIgnoreCase);
    }

    internal static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(Key);
        if (enabled) key.SetValue(Value, Command);
        else if (string.Equals(key.GetValue(Value) as string, Command, StringComparison.OrdinalIgnoreCase))
            key.DeleteValue(Value, throwOnMissingValue: false);
    }
}
