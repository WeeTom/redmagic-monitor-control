using System;
using System.Threading.Tasks;

namespace RedMagicMonitor;

internal sealed record ShortcutInputResult(DdcInputStatus DdcStatus, InputSource? ActiveInput,
    bool MenuConfirmed, string Message)
{
    internal WriteResult<InputSource> ForTarget(InputSource target) =>
        new(ActiveInput == target, ActiveInput, Message);
}

internal static class ShortcutInputSwitcher
{
    internal static async Task<ShortcutInputResult> SelectAsync(InputSource source, bool bluetoothConfigured,
        Func<InputSource, Task<DdcInputResult>> selectVideo, Func<InputSource, Task<bool?>> selectMenu,
        Func<InputSource, Func<Task<bool>>, Task<bool>> alignMenu, Func<Task<InputSource?>> readVideo,
        Action<string> log)
    {
        var ddc = await selectVideo(source);
        log(L.T("快捷方式 DDC {0}。{1}", InputSources.Name(source), ddc.Message));
        InputSource? active = ddc.Value;
        bool checkedAfterWrite = false;
        async Task<InputSource?> ReadActive()
        {
            checkedAfterWrite = true;
            try
            {
                var observed = await readVideo();
                if (observed.HasValue) active = observed;
                return observed;
            }
            catch (Exception error)
            {
                log(L.T("核对活动输入。{0}", error.Message));
                return null;
            }
        }

        bool supplementFromPrior = false;
        async Task<bool> MayAlignMenu()
        {
            var observed = await ReadActive();
            if (observed == source) return true;
            supplementFromPrior = ddc.Status == DdcInputStatus.Unconfirmed &&
                observed.HasValue && observed == ddc.RetryFrom;
            return supplementFromPrior;
        }

        bool menuConfirmed = false;
        string menu = L.T("蓝牙未配置");
        if (bluetoothConfigured)
        {
            bool fallbackMayHaveSent = false;
            try
            {
                bool? confirmation;
                if (ddc.Status == DdcInputStatus.Unavailable)
                {
                    // Only this status guarantees the DDC SET was never attempted.
                    fallbackMayHaveSent = true;
                    confirmation = await selectMenu(source);
                    fallbackMayHaveSent = confirmation.HasValue;
                }
                else
                {
                    // A fresh read must match the target or the repeatedly verified
                    // pre-switch input from a rejected DDC SET before touching the menu.
                    confirmation = await alignMenu(source, MayAlignMenu);
                }
                menuConfirmed = confirmation == true;
                menu = confirmation switch
                {
                    true => L.T("蓝牙菜单已确认"),
                    false => L.T("蓝牙菜单未确认"),
                    null => L.T("蓝牙未连接，未发送蓝牙切源指令")
                };
            }
            catch (Exception error)
            {
                menu = L.T("蓝牙菜单未确认。{0}", error.Message);
                log(menu);
            }
            if (fallbackMayHaveSent || supplementFromPrior || (ddc.Status == DdcInputStatus.Unconfirmed && !checkedAfterWrite))
            {
                // A BLE write can move the video away from the last observed port.
                if (fallbackMayHaveSent || supplementFromPrior) active = null;
                await ReadActive();
            }
            if (fallbackMayHaveSent) menu = L.T("已尝试蓝牙切源 · {0}", menu);
            else if (supplementFromPrior) menu = L.T("已尝试蓝牙补切 · {0}", menu);
        }

        string write = ddc.Status switch
        {
            DdcInputStatus.Confirmed => L.T("DDC 写入已确认"),
            DdcInputStatus.Unconfirmed => L.T("已尝试 DDC 写入"),
            _ => L.T("DDC 未发送")
        };
        string video = active.HasValue ? L.T("DDC 活动输入 {0}", InputSources.Name(active.Value)) : L.T("视频源未确认");
        return new(ddc.Status, active, menuConfirmed, $"{write} · {video} · {menu}");
    }
}
