using System;
using System.Buffers.Binary;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace RedMagicMonitor;

// Uses the public NVIDIA NVAPI I2C API on the exact Windows output selected by EDID.
internal sealed class NvDdcVolume
{
    private static readonly Lazy<Driver> Api = new(() => new Driver());
    private readonly nint _gpu;
    private readonly uint _mask;

    internal NvDdcVolume(string gdiName)
    {
        var api = Api.Value;
        Check(api.Associate(gdiName, out var display), "定位 NVIDIA 显示输出");
        Check(api.Output(display, out _mask), "获取 NVIDIA 输出掩码");
        if (_mask == 0 || (_mask & (_mask - 1)) != 0)
            throw new IOException("NVIDIA 输出无法唯一定位。");
        var gpus = new nint[64];
        Check(api.PhysicalGpu(display, gpus, out uint count), "定位实体 GPU");
        if (count != 1 || gpus[0] == 0)
            throw new IOException("NVIDIA 实体 GPU 无法唯一定位。");
        _gpu = gpus[0];
    }

    // A complete reply can belong to the previous query. Keep the feature fixed
    // until its own valid frame arrives, then allow the next feature on the bus.
    internal (uint Value, uint Maximum) ReadStandard(byte code)
    {
        if (code is not (0x10 or 0x12 or 0x60 or 0x62)) throw new ArgumentOutOfRangeException(nameof(code));
        byte[] request = [0x51, 0x82, 0x01, code, (byte)(0x6e ^ 0x51 ^ 0x82 ^ 0x01 ^ code)];
        byte[] response = new byte[11];
        foreach (int delay in new[] { 60, 80, 45, 70, 90, 55 })
        {
            Transfer(Api.Value.Send, request, $"发送 VCP 0x{code:X2} GET", trace: true);
            Thread.Sleep(delay);
            Array.Clear(response);
            Transfer(Api.Value.Receive, response, $"VCP 0x{code:X2} GET 回包", trace: true);
            if (TryParseReply(response, code, vendor: false, out var reading)) return reading;
            Thread.Sleep(32);
        }
        throw new IOException($"VCP 0x{code:X2} 未收到匹配的有效回包。");
    }

    internal int Read()
    {
        try { return (int)ReadStandard(0x62).Value; }
        catch (IOException error) { TrayLog.Write(error.Message); }

        try { return ReadVolume([0x51, 0x83, 0xc6, 0, 0x62, 0x18], 20, 100, "厂商"); }
        catch (IOException error) { TrayLog.Write(error.Message); }
        Thread.Sleep(75);
        return ReadVolume([0x51, 0x83, 0xc6, 0, 0x62, 0x18], 20, 100, "厂商");
    }

    private int ReadVolume(byte[] request, int repeatGapMs, int responseDelayMs, string kind)
    {
        string description = $"NVAPI {kind}音量 GET";
        Transfer(Api.Value.Send, request, description + " 请求", trace: true);
        Thread.Sleep(repeatGapMs);
        Transfer(Api.Value.Send, request, description + " 第二次请求", trace: true);
        Thread.Sleep(responseDelayMs);
        byte[] response = new byte[12];
        Transfer(Api.Value.Receive, response, description + " 回包", trace: true);
        if (TryParseReply(response, 0x62, vendor: request[2] == 0xc6, out var reading)) return (int)reading.Value;
        throw new IOException($"耳机音量 GET 回包无效（{Convert.ToHexString(response)}）。");
    }

    internal void Write(int percent)
    {
        byte[] frame = VolumeFrame(percent);
        Transfer(Api.Value.Send, frame, "发送耳机音量 C8");
        Thread.Sleep(50);
        Transfer(Api.Value.Send, frame, "再次发送耳机音量 C8");
    }

    internal static byte[] VolumeFrame(int percent)
    {
        if (percent is < 0 or > 100) throw new ArgumentOutOfRangeException(nameof(percent));
        byte[] frame = [0x51, 0x85, 0xc8, 0, 0x62, 0, (byte)percent, 0];
        frame[^1] = FoldXor(0x6e, frame.AsSpan(0, 7));
        return frame;
    }

    internal static int ParseVolumeReply(ReadOnlySpan<byte> reply)
    {
        if (TryParseReply(reply, 0x62, vendor: false, out var reading) ||
            TryParseReply(reply, 0x62, vendor: true, out reading)) return (int)reading.Value;
        throw new IOException($"耳机音量 GET 回包无效（{Convert.ToHexString(reply)}）。");
    }

    internal static bool TryParseReply(ReadOnlySpan<byte> reply, byte code, bool vendor,
        out (uint Value, uint Maximum) reading)
    {
        reading = default;
        int shift = vendor ? 1 : 0;
        int length = 11 + shift;
        if (reply.Length < length || reply[0] != 0x6e || reply[1] != (vendor ? 0x89 : 0x88) ||
            reply[2] != (vendor ? 0xc7 : 0x02) || (vendor && reply[3] != 0) ||
            reply[3 + shift] != 0 || reply[4 + shift] != code || reply[5 + shift] > 1 ||
            FoldXor(0x50, reply[..length]) != 0) return false;
        uint maximum = BinaryPrimitives.ReadUInt16BigEndian(reply[(6 + shift)..]);
        uint current = BinaryPrimitives.ReadUInt16BigEndian(reply[(8 + shift)..]);
        bool valid = code switch
        {
            0x60 => !vendor && InputSources.FromDdc(current).HasValue,
            0x10 or 0x12 => !vendor && maximum > 0 && current <= maximum,
            0x62 => current <= 100,
            _ => false
        };
        if (valid) reading = (current, maximum);
        return valid;
    }

    private static byte FoldXor(byte seed, ReadOnlySpan<byte> bytes)
    {
        foreach (byte value in bytes) seed ^= value;
        return seed;
    }

    private void Transfer(I2c method, byte[] bytes, string operation, bool trace = false)
    {
        var pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try
        {
            var info = new I2cInfo
            {
                Version = (uint)Marshal.SizeOf<I2cInfo>() | (3u << 16),
                DisplayMask = _mask,
                IsDdcPort = 1,
                Address = 0x37 << 1,
                Data = pin.AddrOfPinnedObject(),
                Size = (uint)bytes.Length,
                DeprecatedSpeed = 0xffff
            };
            int status = method(_gpu, ref info);
            if (trace)
                TrayLog.Write($"{operation}。状态 {status}，请求长度 {bytes.Length}，驱动长度 {info.Size}，数据 {Convert.ToHexString(bytes)}");
            Check(status, operation);
        }
        finally { pin.Free(); }
    }

    private static void Check(int status, string operation)
    {
        if (status != 0) throw new IOException($"{operation}失败（NVAPI {status}）。");
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct I2cInfo
    {
        internal uint Version, DisplayMask;
        internal byte IsDdcPort, Address;
        internal nint Register;
        internal uint RegisterSize;
        internal nint Data;
        internal uint Size, DeprecatedSpeed, SpeedKhz;
        internal byte PortId;
        internal uint IsPortIdSet;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate nint QueryInterface(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Initialize();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    private delegate int AssociateDisplay(string display, out nint handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int GetOutput(nint display, out uint mask);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int GetGpu(nint display, [Out, MarshalAs(UnmanagedType.LPArray, SizeConst = 64)] nint[] gpus, out uint count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int I2c(nint gpu, ref I2cInfo info);

    private sealed class Driver
    {
        internal readonly AssociateDisplay Associate;
        internal readonly GetOutput Output;
        internal readonly GetGpu PhysicalGpu;
        internal readonly I2c Send, Receive;

        internal Driver()
        {
            var library = NativeLibrary.Load(Path.Combine(Environment.SystemDirectory, "nvapi64.dll"));
            try
            {
                var entry = NativeLibrary.GetExport(library, "nvapi_QueryInterface");
                var query = Marshal.GetDelegateForFunctionPointer<QueryInterface>(entry);
                Check(Resolve<Initialize>(0x0150e828)(), "初始化 NVAPI");
                Associate = Resolve<AssociateDisplay>(0x35c29134);
                Output = Resolve<GetOutput>(0xd995937e);
                PhysicalGpu = Resolve<GetGpu>(0x34ef9506);
                Send = Resolve<I2c>(0xe812eb07);
                Receive = Resolve<I2c>(0x2fde12c5);

                T Resolve<T>(uint id) where T : Delegate
                {
                    var address = query(id);
                    if (address == 0) throw new IOException($"NVAPI 接口 0x{id:X8} 不可用。");
                    return Marshal.GetDelegateForFunctionPointer<T>(address);
                }
            }
            catch
            {
                NativeLibrary.Free(library);
                throw;
            }
            // The process retains the loaded driver while these delegates exist.
        }
    }
}
