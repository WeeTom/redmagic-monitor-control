using RedMagicMonitor;

internal static class ShortcutSwitchChecks
{
    private sealed class FakeMonitor(InputSource target)
    {
        internal readonly List<string> Calls = [];
        internal DdcInputStatus VideoStatus = DdcInputStatus.Confirmed;
        internal InputSource? Active = target;
        internal bool? Menu = true;
        internal bool FailRead;

        internal Task<ShortcutInputResult> SelectAsync(bool bluetoothConfigured = true) =>
            ShortcutInputSwitcher.SelectAsync(target, bluetoothConfigured,
                requested =>
                {
                    Calls.Add($"DDC {requested}");
                    return Task.FromResult(new DdcInputResult(VideoStatus,
                        VideoStatus == DdcInputStatus.Confirmed ? requested : null, VideoStatus.ToString()));
                },
                requested => { Calls.Add($"BLE {requested}"); return Task.FromResult(Menu); },
                requested => { Calls.Add($"align {requested}"); return Task.FromResult(Menu == true); },
                () =>
                {
                    Calls.Add("read video");
                    if (FailRead) throw new IOException("unavailable after switching");
                    return Task.FromResult(Active);
                }, _ => { });
    }

    internal static async Task RunAsync()
    {
        foreach (var target in InputSources.All)
        {
            var monitor = new FakeMonitor(target);
            var expected = target == InputSource.TypeC
                ? new[] { $"DDC {target}", $"align {target}" } : new[] { $"BLE {target}", "read video" };
            for (int invocation = 1; invocation <= 2; invocation++)
            {
                var result = await monitor.SelectAsync();
                Expect(monitor.Calls.SequenceEqual(expected) && result.ForTarget(target).Confirmed,
                    $"{target} invocation {invocation} issues a fresh selection");
                monitor.Calls.Clear();
            }
            var ddcOnly = await monitor.SelectAsync(bluetoothConfigured: false);
            Expect(monitor.Calls.SequenceEqual(new[] { $"DDC {target}" }) && ddcOnly.ForTarget(target).Confirmed,
                $"{target} uses DDC when Bluetooth is unconfigured");
        }

        var lostLink = new FakeMonitor(InputSource.TypeC) { VideoStatus = DdcInputStatus.Unconfirmed };
        var lost = await lostLink.SelectAsync();
        Expect(lost.ActiveInput is null && lost.MenuConfirmed && lost.Message.Contains("视频源未确认") &&
            lostLink.Calls.SequenceEqual(new[] { "DDC TypeC", "align TypeC" }),
            "Type-C lost-link result retains the separate menu confirmation");

        var fallback = new FakeMonitor(InputSource.TypeC) { VideoStatus = DdcInputStatus.Unavailable, Active = null };
        var menuOnly = await fallback.SelectAsync();
        Expect(fallback.Calls.SequenceEqual(new[] { "DDC TypeC", "BLE TypeC", "read video" }) &&
            menuOnly.ForTarget(InputSource.TypeC).Confirmed && menuOnly.Message.Contains("视频源未确认"),
            "Type-C unavailable video falls back to one explicit BLE selection");

        var hdmi = new FakeMonitor(InputSource.Hdmi2) { Active = InputSource.DisplayPort };
        var conflicting = await hdmi.SelectAsync();
        Expect(!conflicting.ForTarget(InputSource.Hdmi2).Confirmed && conflicting.MenuConfirmed &&
            conflicting.Message.Contains("DP"), "confirmed menu does not override a mismatching video readback");
        hdmi.FailRead = true;
        var noRead = await hdmi.SelectAsync();
        Expect(noRead.ForTarget(InputSource.Hdmi2).Confirmed && noRead.Message.Contains("视频源未确认"),
            "unavailable external video readback preserves confirmed BLE selection");
        hdmi.Menu = false;
        hdmi.Calls.Clear();
        var neither = await hdmi.SelectAsync();
        Expect(!neither.ForTarget(InputSource.Hdmi2).Confirmed &&
            hdmi.Calls.SequenceEqual(new[] { "BLE Hdmi2", "read video" }),
            "unconfirmed BLE write is not replayed through DDC");
        hdmi.Menu = null;
        hdmi.Calls.Clear();
        var ddcFallback = await hdmi.SelectAsync();
        Expect(ddcFallback.ForTarget(InputSource.Hdmi2).Confirmed &&
            hdmi.Calls.SequenceEqual(new[] { "BLE Hdmi2", "DDC Hdmi2" }),
            "failed BLE connection before submission falls back to bound DDC");
    }

    private static void Expect(bool valid, string message)
    {
        if (!valid) throw new InvalidOperationException(message);
        Console.WriteLine("PASS shortcut " + message);
    }
}
