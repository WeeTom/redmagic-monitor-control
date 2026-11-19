using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace RedMagicMonitor;

internal sealed class DdcDisplay : IDisposable
{
    internal const string Product = "RMG0A8D";
    internal string GdiName { get; }
    private nint _handle;

    private DdcDisplay(nint handle, string name) => (_handle, GdiName) = (handle, name);

    internal sealed record Candidate(string Serial, string GdiName, bool CanBind)
    {
        internal nint Monitor { get; init; }
    }

    internal static List<Candidate> Candidates(string? configuredSerial = null)
    {
        var displays = new List<nint>();
        if (!EnumDisplayMonitors(0, 0, (monitor, _, _, _) => { displays.Add(monitor); return true; }, 0))
            throw new IOException(L.T("枚举显示器失败 {0}", LastError()));

        var candidates = new List<Candidate>();
        foreach (var handle in displays)
        {
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (!GetMonitorInfo(handle, ref info)) continue;
            var serials = new List<string>();
            int activeDevices = 0;
            for (uint index = 0; ; index++)
            {
                var device = new DisplayDevice { Size = Marshal.SizeOf<DisplayDevice>() };
                if (!EnumDisplayDevices(info.Name, index, ref device, 1)) break;
                if ((device.Flags & 1) == 0) continue;
                activeDevices++;
                if (TryReadTarget(device.DeviceId, out var serial)) serials.Add(serial);
            }
            if (serials.Count == 0) continue;
            // A cloned GDI output is not independently selectable by its physical handle.
            bool uniqueOutput = activeDevices == 1 &&
                GetNumberOfPhysicalMonitorsFromHMONITOR(handle, out uint count) && count == 1;
            foreach (var serial in serials)
                candidates.Add(new(serial, info.Name, serial.Length != 0 && uniqueOutput) { Monitor = handle });
        }
        var duplicates = candidates.GroupBy(candidate => candidate.Serial, StringComparer.OrdinalIgnoreCase)
            .Where(group => group.Count() > 1).Select(group => group.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        string? filter = configuredSerial?.Trim();
        return candidates.Where(candidate => string.IsNullOrEmpty(filter) ||
                string.Equals(candidate.Serial, filter, StringComparison.OrdinalIgnoreCase))
            .Select(candidate => duplicates.Contains(candidate.Serial) ? candidate with { CanBind = false } : candidate)
            .OrderBy(candidate => candidate.Serial, StringComparer.OrdinalIgnoreCase)
            .ThenBy(candidate => candidate.GdiName, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    internal static DdcDisplay Open(string? configuredSerial)
    {
        // Always resolve a fresh identity so a stale selection cannot target a different monitor.
        var matches = Candidates(configuredSerial);
        if (matches.Count != 1)
            throw new IOException(L.T("需要唯一活动的 GM001J（EDID 匹配），找到 {0} 台。", matches.Count));

        var target = matches[0];
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(target.Monitor, out uint count))
            throw new IOException(L.T("读取物理显示器失败 {0}", LastError()));
        if (count != 1)
            throw new IOException(L.T("GM001J 映射到 {0} 个物理句柄。", count));
        if (!target.CanBind)
            throw new IOException(L.T("需要唯一活动的 GM001J（EDID 匹配），找到 {0} 台。", 0));
        var physical = new PhysicalMonitor[1];
        if (!GetPhysicalMonitorsFromHMONITOR(target.Monitor, count, physical))
            throw new IOException(L.T("打开 GM001J 失败 {0}", LastError()));
        return new DdcDisplay(physical[0].Handle, target.GdiName);
    }

    private static bool TryReadTarget(string? deviceId, out string serial)
    {
        serial = "";
        string[] parts = (deviceId ?? "").Split('#');
        if (parts.Length < 3 || !parts[1].Equals(Product, StringComparison.OrdinalIgnoreCase)) return false;
        using var key = Registry.LocalMachine.OpenSubKey(
            $@"SYSTEM\CurrentControlSet\Enum\DISPLAY\{Product}\{parts[2]}\Device Parameters");
        serial = EdidSerial(key?.GetValue("EDID") as byte[]) ?? "";
        return true;
    }

    internal static string? EdidSerial(byte[]? edid)
    {
        if (edid is null || edid.Length < 128 ||
            !edid.AsSpan(0, 8).SequenceEqual(new byte[] { 0, 255, 255, 255, 255, 255, 255, 0 }) ||
            edid.Take(128).Sum(value => (int)value) % 256 != 0)
            return null;
        for (int offset = 54; offset <= 108; offset += 18)
        {
            if (edid[offset] != 0 || edid[offset + 1] != 0 || edid[offset + 2] != 0 || edid[offset + 3] != 0xff)
                continue;
            var field = edid.AsSpan(offset + 5, 13);
            int end = field.IndexOfAny((byte)0, (byte)'\n', (byte)'\r');
            if (end >= 0) field = field[..end];
            while (field.Length > 0 && field[^1] == ' ') field = field[..^1];
            if (field.IsEmpty || field[0] == ' ' || field.ContainsAnyExceptInRange((byte)0x20, (byte)0x7e))
                continue;
            return Encoding.ASCII.GetString(field);
        }
        return null;
    }

    internal (uint Value, uint Maximum) Read(byte code)
    {
        if (!GetVCPFeatureAndVCPFeatureReply(_handle, code, out _, out var current, out var maximum))
            throw new IOException(L.T("读取 VCP 0x{0:X2} 失败 {1}", code, LastError()));
        if (current > ushort.MaxValue || maximum > ushort.MaxValue || (code == 0x60 && current == 0))
            throw new IOException(L.T("VCP 0x{0:X2} 返回无效值。", code));
        return (current, maximum);
    }

    internal void Write(byte code, uint value)
    {
        if (!SetVCPFeature(_handle, code, value))
            throw new IOException(L.T("写入 VCP 0x{0:X2} 未获接口确认 {1}", code, LastError()));
    }

    public void Dispose()
    {
        if (_handle == 0) return;
        DestroyPhysicalMonitor(_handle);
        _handle = 0;
    }

    private static string LastError() => $"0x{unchecked((uint)Marshal.GetLastWin32Error()):X8}";

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { internal int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfo
    {
        internal int Size;
        internal Rect Monitor, Work;
        internal uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] internal string Name;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DisplayDevice
    {
        internal int Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] internal string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string Description;
        internal uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string DeviceId;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PhysicalMonitor
    {
        internal nint Handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string Description;
    }

    private delegate bool MonitorEnum(nint monitor, nint dc, nint rect, nint state);

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumDisplayMonitors(nint dc, nint rect, MonitorEnum callback, nint state);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplayDevices(string device, uint index, ref DisplayDevice info, uint flags);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(nint monitor, out uint count);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(nint monitor, uint count, [Out] PhysicalMonitor[] physical);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("dxva2.dll")]
    private static extern bool DestroyPhysicalMonitor(nint monitor);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetVCPFeatureAndVCPFeatureReply(nint monitor, byte code, out uint kind,
        out uint current, out uint maximum);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetVCPFeature(nint monitor, byte code, uint value);
}
