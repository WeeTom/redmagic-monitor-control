using System;
using System.Threading.Tasks;

namespace RedMagicMonitor;

internal sealed record ShortcutInputResult(InputSource? ActiveInput, bool MenuConfirmed, string Message)
{
    internal WriteResult<InputSource> ForTarget(InputSource target)
    {
        bool confirmed = ActiveInput.HasValue ? ActiveInput == target : MenuConfirmed;
        return new(confirmed, confirmed ? target : null, Message);
    }
}

internal static class ShortcutInputSwitcher
{
    internal static async Task<ShortcutInputResult> SelectAsync(InputSource source, bool bluetoothConfigured,
        Func<InputSource, Task<DdcInputResult>> selectVideo, Func<InputSource, Task<bool?>> selectMenu,
        Func<InputSource, Task<bool>> alignMenu, Func<Task<InputSource?>> readVideo, Action<string> log)
    {
        if (!bluetoothConfigured)
        {
            var video = await selectVideo(source);
            return new(video.Value, false, video.Message);
        }

        bool menu;
        if (source == InputSource.TypeC)
        {
            var result = await TypeCReturn.SelectAsync(() => selectVideo(source), () => alignMenu(source),
                async () => await selectMenu(source) == true, log);
            if (result.Video.Status != DdcInputStatus.Unavailable)
                return new(result.Video.Value, result.MenuConfirmed, result.Message);
            menu = result.MenuConfirmed;
        }
        else
        {
            bool? selected = await selectMenu(source);
            if (selected is null)
            {
                var video = await selectVideo(source);
                return new(video.Value, false, $"蓝牙未连接。{video.Message}");
            }
            menu = selected.Value;
        }

        InputSource? active = null;
        try { active = await readVideo(); }
        catch (Exception error) { log($"核对活动输入。{error.Message}"); }
        string videoMessage = active.HasValue ? $"DDC 活动输入 {InputSources.Name(active.Value)}" : "视频源未确认";
        return new(active, menu, videoMessage + (menu ? " · 蓝牙菜单已确认" : " · 蓝牙菜单未确认"));
    }
}
