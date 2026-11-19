using RedMagicMonitor;

internal static class ShortcutSwitchChecks
{
    private sealed class FakeMonitor(InputSource target)
    {
        internal readonly List<string> Calls = [];
        internal DdcInputStatus Ddc = DdcInputStatus.Confirmed;
        internal InputSource? RetryFrom;
        internal InputSource? Active = target;
        internal InputSource? AfterBleWrite = target;
        internal bool? MenuSet = true;
        internal bool MenuMatches = true;
        internal bool ReadFails;
        internal bool AlignFails;

        internal Task<ShortcutInputResult> SelectAsync(bool bluetoothConfigured = true) =>
            ShortcutInputSwitcher.SelectAsync(target, bluetoothConfigured,
                requested =>
                {
                    Calls.Add($"DDC {requested}");
                    return Task.FromResult(new DdcInputResult(Ddc,
                        Ddc == DdcInputStatus.Confirmed ? requested : null, Ddc.ToString(), RetryFrom));
                },
                requested =>
                {
                    Calls.Add($"BLE select {requested}");
                    if (MenuSet.HasValue) Active = AfterBleWrite;
                    return Task.FromResult(MenuSet);
                },
                async (requested, mayWrite) =>
                {
                    Calls.Add($"BLE query {requested}");
                    if (AlignFails) throw new IOException("BLE unavailable");
                    if (MenuMatches) return true;
                    if (!await mayWrite()) return false;
                    Calls.Add($"BLE align {requested}");
                    Active = AfterBleWrite;
                    return MenuSet == true;
                },
                () =>
                {
                    Calls.Add("read video");
                    if (ReadFails) throw new IOException("video read unavailable");
                    return Task.FromResult(Active);
                }, _ => { });
    }

    internal static async Task RunAsync()
    {
        foreach (var target in InputSources.All)
        {
            var monitor = new FakeMonitor(target);
            for (int invocation = 1; invocation <= 2; invocation++)
            {
                var result = await monitor.SelectAsync();
                Expect(monitor.Calls.SequenceEqual(new[] { $"DDC {target}", $"BLE query {target}" }) &&
                    result.ForTarget(target).Confirmed && result.DdcStatus == DdcInputStatus.Confirmed,
                    $"{target} invocation {invocation} writes DDC first");
                monitor.Calls.Clear();
            }
            var ddcOnly = await monitor.SelectAsync(bluetoothConfigured: false);
            Expect(monitor.Calls.SequenceEqual(new[] { $"DDC {target}" }) && ddcOnly.ForTarget(target).Confirmed,
                $"{target} uses DDC without Bluetooth");

            monitor.Ddc = DdcInputStatus.Unavailable;
            monitor.Calls.Clear();
            var fallback = await monitor.SelectAsync();
            Expect(monitor.Calls.SequenceEqual(new[] { $"DDC {target}", $"BLE select {target}", "read video" }) &&
                fallback.DdcStatus == DdcInputStatus.Unavailable && fallback.ForTarget(target).Confirmed &&
                fallback.Message.Contains(L.T("DDC 未发送")), $"{target} unsent DDC allows one bound BLE selection");
        }

        var lostLink = new FakeMonitor(InputSource.TypeC) { Ddc = DdcInputStatus.Unconfirmed, Active = null };
        var lost = await lostLink.SelectAsync();
        Expect(!lost.ForTarget(InputSource.TypeC).Confirmed && lost.MenuConfirmed &&
            lost.Message.Contains(L.T("已尝试 DDC 写入")) && lost.Message.Contains(L.T("视频源未确认")) &&
            lostLink.Calls.SequenceEqual(new[] { "DDC TypeC", "BLE query TypeC", "read video" }),
            "Type-C clamshell can lose DDC readback while the BLE menu confirms");
        lostLink.MenuMatches = false;
        lostLink.Calls.Clear();
        var lostMenu = await lostLink.SelectAsync();
        Expect(!lostMenu.MenuConfirmed && !lostMenu.ForTarget(InputSource.TypeC).Confirmed &&
            lostLink.Calls.SequenceEqual(new[] { "DDC TypeC", "BLE query TypeC", "read video" }),
            "lost video plus conflicting menu does not repeat the write");

        var hdmi = new FakeMonitor(InputSource.Hdmi2)
            { Ddc = DdcInputStatus.Unconfirmed, MenuMatches = false, Active = InputSource.DisplayPort };
        var conflict = await hdmi.SelectAsync();
        Expect(!conflict.ForTarget(InputSource.Hdmi2).Confirmed && conflict.ActiveInput == InputSource.DisplayPort &&
            hdmi.Calls.SequenceEqual(new[] { "DDC Hdmi2", "BLE query Hdmi2", "read video" }),
            "mismatching active input alone cannot authorize a second SET");

        hdmi.RetryFrom = InputSource.DisplayPort;
        hdmi.Calls.Clear();
        var supplemented = await hdmi.SelectAsync();
        Expect(hdmi.Calls.SequenceEqual(new[] { "DDC Hdmi2", "BLE query Hdmi2", "read video", "BLE align Hdmi2", "read video" }) &&
            supplemented.ForTarget(InputSource.Hdmi2).Confirmed && supplemented.DdcStatus == DdcInputStatus.Unconfirmed,
            "verified previous port permits one guarded BLE supplement and fresh video check");
        hdmi.Active = InputSource.DisplayPort;
        hdmi.AfterBleWrite = null;
        var unreadable = await hdmi.SelectAsync();
        Expect(unreadable.ActiveInput is null && unreadable.MenuConfirmed && !unreadable.ForTarget(InputSource.Hdmi2).Confirmed,
            "pre-supplement video proof expires after BLE SET");
        hdmi.Active = InputSource.Hdmi1;
        hdmi.Calls.Clear();
        var newer = await hdmi.SelectAsync();
        Expect(newer.ActiveInput == InputSource.Hdmi1 && !newer.MenuConfirmed && !hdmi.Calls.Contains("BLE align Hdmi2"),
            "a fresh source change invalidates prior retry permission");

        var menuOnly = new FakeMonitor(InputSource.DisplayPort)
            { Ddc = DdcInputStatus.Unavailable, ReadFails = true };
        var unknown = await menuOnly.SelectAsync();
        Expect(unknown.MenuConfirmed && !unknown.ForTarget(InputSource.DisplayPort).Confirmed &&
            unknown.Message.Contains(L.T("视频源未确认")), "menu-only fallback never confirms active video");
        menuOnly.MenuSet = null;
        menuOnly.Calls.Clear();
        var unsent = await menuOnly.SelectAsync();
        Expect(!unsent.ForTarget(InputSource.DisplayPort).Confirmed && unsent.Message.Contains(L.T("蓝牙未连接，未发送蓝牙切源指令")) &&
            menuOnly.Calls.SequenceEqual(new[] { "DDC DisplayPort", "BLE select DisplayPort" }),
            "unavailable DDC and BLE report no write instead of inventing a selection");

        var confirmed = new FakeMonitor(InputSource.Hdmi1) { AlignFails = true };
        var withoutMenu = await confirmed.SelectAsync();
        Expect(withoutMenu.ForTarget(InputSource.Hdmi1).Confirmed && !withoutMenu.MenuConfirmed,
            "optional menu failure preserves confirmed DDC video");
        confirmed.AlignFails = false;
        confirmed.MenuMatches = false;
        confirmed.Active = InputSource.TypeC;
        var moved = await confirmed.SelectAsync();
        Expect(!moved.ForTarget(InputSource.Hdmi1).Confirmed && moved.ActiveInput == InputSource.TypeC &&
            !confirmed.Calls.Contains("BLE align Hdmi1"), "newer video evidence supersedes initial DDC confirmation");
    }

    private static void Expect(bool valid, string message)
    {
        if (!valid) throw new InvalidOperationException(message);
        Console.WriteLine("PASS shortcut " + message);
    }
}
