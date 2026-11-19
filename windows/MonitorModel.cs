using System;

namespace RedMagicMonitor;

internal enum PanelPage { Ddc, Bluetooth, Donation }

internal enum InputSource : byte { TypeC = 1, DisplayPort = 2, Hdmi1 = 3, Hdmi2 = 4 }

internal static class InputSources
{
    internal static readonly InputSource[] All =
        [InputSource.TypeC, InputSource.DisplayPort, InputSource.Hdmi1, InputSource.Hdmi2];

    internal static string CommandToken(InputSource source) => source switch
    {
        InputSource.TypeC => "type-c",
        InputSource.DisplayPort => "dp",
        InputSource.Hdmi1 => "hdmi-1",
        InputSource.Hdmi2 => "hdmi-2",
        _ => throw new ArgumentOutOfRangeException(nameof(source))
    };

    internal static InputSource? FromCommandToken(string token)
    {
        foreach (var source in All)
            if (string.Equals(token, CommandToken(source), StringComparison.OrdinalIgnoreCase)) return source;
        return null;
    }

    internal static string Name(InputSource source) => source switch
    {
        InputSource.TypeC => "Type-C",
        InputSource.DisplayPort => "DP",
        InputSource.Hdmi1 => "HDMI 1",
        InputSource.Hdmi2 => "HDMI 2",
        _ => throw new ArgumentOutOfRangeException(nameof(source))
    };

    internal static byte DdcCode(InputSource source) => source switch
    {
        InputSource.TypeC => 7,
        InputSource.DisplayPort => 8,
        InputSource.Hdmi1 => 5,
        InputSource.Hdmi2 => 6,
        _ => throw new ArgumentOutOfRangeException(nameof(source))
    };

    internal static InputSource? FromDdc(uint? value) => value switch
    {
        7 => InputSource.TypeC,
        8 => InputSource.DisplayPort,
        5 => InputSource.Hdmi1,
        6 => InputSource.Hdmi2,
        _ => null
    };

    internal static InputSource? FromBluetooth(byte? value) =>
        value is >= 1 and <= 4 ? (InputSource)value.Value : null;
}

internal enum DdcControl : byte { Brightness = 0x10, Contrast = 0x12, Volume = 0x62 }

internal sealed record DdcSnapshot(bool TargetPresent, InputSource? Input, int? Brightness, int? Contrast,
    int? Volume, bool VolumeWritable, string Message, string VolumeMessage);

internal sealed record WriteResult<T>(bool Confirmed, T? Value, string Message) where T : struct;
