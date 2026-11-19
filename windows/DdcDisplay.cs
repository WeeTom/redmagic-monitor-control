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

    internal static DdcDisplay Open(string? configuredSerial)
    {
        var displays = new List<nint>();
        if (!EnumDisplayMonitors(0, 0, (monitor, _, _, _) => { displays.Add(monitor); return true; }, 0))
            throw new IOException($"枚举显示器失败 {LastError()}");

        var matches = new List<(nint Monitor, string Name)>();
        foreach (var handle in displays)
        {
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (!GetMonitorInfo(handle, ref info)) continue;
            for (uint index = 0; ; index++)
            {
                var device = new DisplayDevice { Size = Marshal.SizeOf<DisplayDevice>() };
                if (!EnumDisplayDevices(info.Name, index, ref device, 1)) break;
                if ((device.Flags & 1) != 0 && IsTarget(device.DeviceId, configuredSerial))
                    matches.Add((handle, info.Name));
            }
        }
        if (matches.Count != 1)
            throw new IOException($"需要唯一活动的 GM001J（EDID 匹配），找到 {matches.Count} 台。");

        var target = matches[0];
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(target.Monitor, out uint count))
            throw new IOException($"读取物理显示器失败 {LastError()}");
        if (count != 1)
            throw new IOException($"GM001J 映射到 {count} 个物理句柄。");
        var physical = new PhysicalMonitor[1];
        if (!GetPhysicalMonitorsFromHMONITOR(target.Monitor, count, physical))
            throw new IOException($"打开 GM001J 失败 {LastError()}");
        return new DdcDisplay(physical[0].Handle, target.Name);
    }

    private static bool IsTarget(string? deviceId, string? configuredSerial)
    {
        string[] parts = (deviceId ?? "").Split('#');
        if (parts.Length < 3 || !parts[1].Equals(Product, StringComparison.OrdinalIgnoreCase)) return false;
        using var key = Registry.LocalMachine.OpenSubKey(
            $@"SYSTEM\CurrentControlSet\Enum\DISPLAY\{Product}\{parts[2]}\Device Parameters");
        var serial = EdidSerial(key?.GetValue("EDID") as byte[]);
        return serial is not null && (string.IsNullOrWhiteSpace(configuredSerial) ||
            string.Equals(serial, configuredSerial.Trim(), StringComparison.OrdinalIgnoreCase));
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
            string serial = Encoding.ASCII.GetString(edid, offset + 5, 13).TrimEnd('\0', '\n', '\r', ' ');
            if (serial.Length != 0) return serial;
        }
        return null;
    }

    internal (uint Value, uint Maximum) Read(byte code)
    {
        if (!GetVCPFeatureAndVCPFeatureReply(_handle, code, out _, out var current, out var maximum))
            throw new IOException($"读取 VCP 0x{code:X2} 失败 {LastError()}");
        if (current > ushort.MaxValue || maximum > ushort.MaxValue || (code == 0x60 && current == 0))
            throw new IOException($"VCP 0x{code:X2} 返回无效值。");
        return (current, maximum);
    }

    internal void Write(byte code, uint value)
    {
        if (!SetVCPFeature(_handle, code, value))
            throw new IOException($"写入 VCP 0x{code:X2} 未获接口确认 {LastError()}");
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
