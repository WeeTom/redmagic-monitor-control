using RedMagicMonitor;

static byte[] Hex(string value) => Convert.FromHexString(value.Replace(" ", ""));
static void Expect(bool matches, string test)
{
    if (!matches) throw new Exception(test);
    Console.WriteLine("PASS " + test);
}
static void Reject(string bytes)
{
    try { NvDdcVolume.ParseVolumeReply(Hex(bytes)); }
    catch (IOException) { Console.WriteLine("PASS rejected " + bytes); return; }
    throw new Exception("Accepted invalid volume response " + bytes);
}

Expect(InputSources.All.Select(InputSources.DdcCode).SequenceEqual(Hex("07 08 05 06")), "DDC source mapping");
Expect(InputSources.All.Select(source => (byte)source).SequenceEqual(Hex("01 02 03 04")), "BLE source mapping");
var input = BleProtocol.Specs[BleControl.Input];
Expect(input.QueryFrame().SequenceEqual(Hex("DD 01 00")), "input query");
Expect(input.WriteFrame(2).SequenceEqual(Hex("ED 01 02")), "DP command");
Expect(BleProtocol.Specs[BleControl.LightPower].WriteFrame(1).SequenceEqual(Hex("EE 01 01")), "lights off");
Expect(BleProtocol.Specs[BleControl.LightEffect].WriteFrame(7).SequenceEqual(Hex("EE 04 07")), "reapply split-color effect");
Expect(BleProtocol.Specs[BleControl.Hdr].QueryFrame().SequenceEqual(Hex("DC 06 00")), "HDR query");

var decoder = new BleFrameDecoder();
Expect(decoder.Feed(Hex("01 01 01 CD 01")).Count == 0, "ACK is ignored and a partial frame is buffered");
var replies = decoder.Feed(Hex("02 CC 06 02 CE 04 07"));
Expect(replies.SelectMany(frame => frame).SequenceEqual(Hex("CD 01 02 CC 06 02 CE 04 07")), "split and concatenated replies");
Expect(decoder.Feed(Hex("CD 01 00")).Count == 0, "invalid input reply rejected");
Expect(decoder.Feed(Hex("00 00 00 CD 01 04")).Single().SequenceEqual(Hex("CD 01 04")), "decoder resets and discards zero ACK");
Expect(decoder.Feed(new byte[61]).Count == 0, "oversized BLE notification is rejected");
Expect(BleProtocol.IsIdentity(Hex("01 23 45 67 89 AB"), 0x0123456789AB), "exact FFD2 identity");
Expect(!BleProtocol.IsIdentity(Hex("AB 89 67 45 23 01"), 0x0123456789AB), "reversed FFD2 identity rejected");

Expect(NvDdcVolume.ParseVolumeReply(Hex("6E 88 02 00 62 01 FF FF 00 0A DD")) == 10, "physical reference standard GET 10");
Expect(NvDdcVolume.ParseVolumeReply(Hex("6E 88 02 00 62 01 FF FF 00 0A DD B5")) == 10, "physical reference standard GET 10 with pad");
Expect(NvDdcVolume.ParseVolumeReply(Hex("6E 88 02 00 62 01 FF FF 00 00 D7 B5")) == 0, "physical reference standard GET 0 with pad");
Expect(NvDdcVolume.ParseVolumeReply(Hex("6E 89 C7 00 00 62 01 FF FF 00 00 13")) == 0, "physical reference vendor GET 0");
Expect(NvDdcVolume.VolumeFrame(0).SequenceEqual(Hex("51 85 C8 00 62 00 00 10")), "C8 volume 0");
Expect(NvDdcVolume.VolumeFrame(100).SequenceEqual(Hex("51 85 C8 00 62 00 64 74")), "C8 volume 100");
Reject("6E 00 00 FF FF 01 FF FF FF FF FF");
Reject("6E 88 02 00 62 01 FF FF 00 0A 00");
Reject("6E 89 C7 00 00 62 01 FF FF 00 00");
