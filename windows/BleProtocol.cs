using System;
using System.Collections.Generic;
using System.Buffers.Binary;
using System.Linq;

namespace RedMagicMonitor;

internal enum BleControl { Input, Picture, Hdr, LightPower, LightColor, LightBrightness, LightEffect, FrontColor, BackColor }

internal sealed record ByteChoice(byte Code, string Label);

internal sealed record BleSpec(byte Query, byte Reply, byte Set, byte Group, string Name, IReadOnlyList<ByteChoice> Choices)
{
    internal byte[] QueryFrame() => [Query, Group, 0];
    internal byte[] WriteFrame(byte value)
    {
        if (!Choices.Any(choice => choice.Code == value))
            throw new ArgumentOutOfRangeException(nameof(value));
        return [Set, Group, value];
    }

    internal bool Matches(ReadOnlySpan<byte> value) =>
        value.Length == 3 && value[0] == Reply && value[1] == Group;
}

internal static class BleProtocol
{
    internal static readonly IReadOnlyDictionary<BleControl, BleSpec> Specs = new Dictionary<BleControl, BleSpec>
    {
        [BleControl.Input] = new(0xdd, 0xcd, 0xed, 1, L.T("输入源"),
            InputSources.All.Select(source => new ByteChoice((byte)source, InputSources.Name(source))).ToArray()),
        [BleControl.Picture] = new(0xdc, 0xcc, 0xec, 1, L.T("图像模式"),
            Choices(0, L.T("标准"), L.T("电影"), "FPS", "MOBA", L.T("护眼"), "sRGB", "Adobe RGB", "DCI-P3")),
        [BleControl.Hdr] = new(0xdc, 0xcc, 0xec, 6, "HDR", Choices(1, L.T("开"), L.T("关"))),
        [BleControl.LightPower] = Light(1, L.T("灯光"), Choices(1, L.T("关"), L.T("开"))),
        [BleControl.LightColor] = Light(2, L.T("颜色"), Choices(1, L.T("红"), L.T("黄"), L.T("绿"), L.T("青"), L.T("蓝"), L.T("紫"), L.T("多彩"))),
        [BleControl.LightBrightness] = Light(3, L.T("灯光亮度"), Choices(1, L.T("明亮"), L.T("适中"), L.T("柔和"))),
        [BleControl.LightEffect] = Light(4, L.T("灯效"), Choices(1, L.T("常亮"), L.T("呼吸"), L.T("闪烁"), L.T("单色流动"), L.T("星光"), L.T("多彩"), L.T("多彩流动"))),
        [BleControl.FrontColor] = Light(5, L.T("前灯色"), Choices(1, L.T("红"), L.T("黄"), L.T("绿"), L.T("青"), L.T("蓝"), L.T("紫"))),
        [BleControl.BackColor] = Light(6, L.T("背灯色"), Choices(1, L.T("红"), L.T("黄"), L.T("绿"), L.T("青"), L.T("蓝"), L.T("紫")))
    };

    private static BleSpec Light(byte group, string name, ByteChoice[] options) => new(0xde, 0xce, 0xee, group, name, options);
    private static ByteChoice[] Choices(byte first, params string[] labels) =>
        labels.Select((label, offset) => new ByteChoice((byte)(first + offset), label)).ToArray();

    internal static Guid ControlUuid { get; } = new("0000e0ff-3c17-d293-8e48-14fe2e4da212");
    internal static Guid IdentityUuid { get; } = new("0000d0ff-3c17-d293-8e48-14fe2e4da212");
    internal static Guid Uuid(ushort shortId) => new($"0000{shortId:x4}-0000-1000-8000-00805f9b34fb");

    internal static bool IsIdentity(ReadOnlySpan<byte> bytes, ulong address) =>
        bytes.Length == 6 && ((ulong)BinaryPrimitives.ReadUInt16BigEndian(bytes) << 32 |
            BinaryPrimitives.ReadUInt32BigEndian(bytes[2..])) == address;
}

internal sealed class BleFrameDecoder
{
    private readonly byte[] _partial = new byte[3];
    private int _used;

    internal void Reset() => _used = 0;

    internal IReadOnlyList<byte[]> Feed(ReadOnlySpan<byte> chunk)
    {
        if (chunk.Length is < 1 or > 60)
        {
            Reset();
            return [];
        }

        var frames = new List<byte[]>();
        foreach (byte value in chunk)
        {
            _partial[_used++] = value;
            byte head = _partial[0];
            bool valid = head is 0 or 1 or 0xcd or 0xcc or 0xce;
            if (valid && _used >= 2) valid = ValidGroup(head, _partial[1]);
            if (valid && _used == 3) valid = ValidValue(head, _partial[1], value);
            if (!valid)
            {
                Reset();
                return [];
            }
            if (_used == 3)
            {
                if (head > 1) frames.Add((byte[])_partial.Clone());
                Reset();
            }
        }
        return frames;
    }

    private static bool ValidGroup(byte head, byte group) => head switch
    {
        0 or 1 => group == head,
        0xcd => group is 1 or 2,
        0xcc => group is 1 or 6,
        0xce => group is >= 1 and <= 6,
        _ => false
    };

    private static bool ValidValue(byte head, byte group, byte value)
    {
        if (head <= 1) return value == head;
        if (head == 0xcd && group == 2) return value <= 100;
        return BleProtocol.Specs.Values.Any(spec =>
            spec.Reply == head && spec.Group == group && spec.Choices.Any(choice => choice.Code == value));
    }
}