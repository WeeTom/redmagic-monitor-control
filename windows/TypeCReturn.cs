using System;
using System.IO;
using System.Threading.Tasks;

namespace RedMagicMonitor;

internal enum DdcInputStatus { Unavailable, Unconfirmed, Confirmed }

internal sealed record DdcInputResult(DdcInputStatus Status, InputSource? Value, string Message,
    InputSource? RetryFrom = null)
{
    // Called only after the native SET was attempted. A driver error is not proof
    // that the monitor rejected it. Record a possible retry only if the original
    // port is still visible on every independent readback.
    internal static DdcInputResult VerifyAttempt(InputSource target, InputSource? original, string? writeError,
        Func<InputSource?> read)
    {
        InputSource? unchanged = original;
        for (int attempt = 0; attempt < 3; attempt++)
        {
            var observed = read();
            if (observed == target)
                return new(DdcInputStatus.Confirmed, target, L.T("已确认 {0}", InputSources.Name(target)));
            if (observed != original) unchanged = null;
        }
        return new(DdcInputStatus.Unconfirmed, null, writeError ?? L.T("已发送切源请求，回读尚未确认"),
            writeError == null ? null : unchanged);
    }
}

internal sealed record TypeCReturn(DdcInputResult Video, bool MenuConfirmed)
{
    internal string Message => (Video.Status switch
    {
        DdcInputStatus.Confirmed => L.T("DDC 已确认 Type-C"),
        DdcInputStatus.Unconfirmed => L.T("已尝试 DDC，视频源未确认"),
        _ => L.T("仅蓝牙，视频源未确认")
    }) + " · " + (MenuConfirmed ? L.T("菜单已确认") : L.T("菜单未确认"));

    internal static async Task<TypeCReturn> SelectAsync(Func<Task<DdcInputResult>> selectVideo,
        Func<Task<bool>> alignMenu, Func<Task<bool>> selectMenu, Action<string> log)
    {
        DdcInputResult video;
        try { video = await selectVideo(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            video = new(DdcInputStatus.Unavailable, null, error.Message);
        }
        log(L.T("DDC Type-C。{0}", video.Message));

        // Switching away from DP can remove the physical monitor from Windows before
        // readback. In that case check the menu without blindly issuing a second SET.
        try
        {
            bool confirmed = video.Status == DdcInputStatus.Unavailable || video.RetryFrom == InputSource.DisplayPort
                ? await selectMenu() : await alignMenu();
            return new(video, confirmed);
        }
        catch (Exception error)
        {
            log(L.T("蓝牙 Type-C。{0}", error.Message));
            return new(video, false);
        }
    }
}
