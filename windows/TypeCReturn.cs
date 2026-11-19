using System;
using System.IO;
using System.Threading.Tasks;

namespace RedMagicMonitor;

internal enum DdcInputStatus { Unavailable, Unconfirmed, Confirmed }

internal sealed record DdcInputResult(DdcInputStatus Status, InputSource? Value, string Message);

internal sealed record TypeCReturn(DdcInputResult Video, bool MenuConfirmed)
{
    internal string Message => (Video.Status switch
    {
        DdcInputStatus.Confirmed => "DDC 已确认 Type-C",
        DdcInputStatus.Unconfirmed => "已尝试 DDC，视频源未确认",
        _ => "仅蓝牙，视频源未确认"
    }) + (MenuConfirmed ? " · 菜单已确认" : " · 菜单未确认");

    internal static async Task<TypeCReturn> SelectAsync(Func<Task<DdcInputResult>> selectVideo,
        Func<Task<bool>> alignMenu, Func<Task<bool>> selectMenu, Action<string> log)
    {
        DdcInputResult video;
        try { video = await selectVideo(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            video = new(DdcInputStatus.Unavailable, null, error.Message);
        }
        log($"DDC Type-C。{video.Message}");

        // Switching away from DP can remove the physical monitor from Windows before
        // readback. In that case check the menu without blindly issuing a second SET.
        try
        {
            bool confirmed = video.Status == DdcInputStatus.Unavailable
                ? await selectMenu() : await alignMenu();
            return new(video, confirmed);
        }
        catch (Exception error)
        {
            log($"蓝牙 Type-C。{error.Message}");
            return new(video, false);
        }
    }
}
