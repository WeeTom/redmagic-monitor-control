using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace RedMagicMonitor;

internal sealed class ShortcutChannel
{
    private readonly string _pipeName;
    internal string MutexName { get; }
    internal string OpenMessageName { get; }

    internal ShortcutChannel()
    {
        var directory = TraySettings.DirectoryPath;
        var scope = string.Equals(directory, TraySettings.DefaultDirectoryPath, StringComparison.OrdinalIgnoreCase)
            ? "" : "." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(directory.ToUpperInvariant())));
        MutexName = @"Local\RedMagicMonitor.Tray.050" + scope;
        OpenMessageName = "RedMagicMonitor.OpenPanel.050" + scope;
        using var identity = WindowsIdentity.GetCurrent();
        using var process = Process.GetCurrentProcess();
        _pipeName = $"RedMagicMonitor.Switch.{identity.User!.Value}.{process.SessionId}{scope}";
    }

    internal static bool TryParse(string[] args, out InputSource source, out string? directory)
    {
        InputSource? target = null;
        directory = null;
        source = default;
        for (int i = 0; i < args.Length; i += 2)
        {
            if (i + 1 >= args.Length) return false;
            string value = args[i + 1];
            switch (args[i])
            {
                case "--switch-input" when target == null:
                    target = InputSources.FromCommandToken(value);
                    if (target == null) return false;
                    break;
                case "--data-dir" when directory == null && !string.IsNullOrWhiteSpace(value) && !value.StartsWith("--"):
                    directory = value;
                    break;
                default:
                    return false;
            }
        }
        if (!target.HasValue) return false;
        source = target.Value;
        return true;
    }

    internal async Task<bool> RequestAsync(InputSource source)
    {
        if (Mutex.TryOpenExisting(MutexName, out var running)) running.Dispose();
        else
        {
            var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
            start.ArgumentList.Add("--background");
            start.ArgumentList.Add("--data-dir");
            start.ArgumentList.Add(TraySettings.DirectoryPath);
            using var backgroundTray = Process.Start(start);
        }

        using var client = new NamedPipeClientStream(".", _pipeName, PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await client.ConnectAsync(15000);
        await client.WriteAsync(new byte[] { (byte)source });
        var reply = new byte[1];
        await client.ReadExactlyAsync(reply);
        return reply[0] == 0;
    }

    internal async Task ListenAsync(Func<InputSource, Task<bool>> select, CancellationToken stop)
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                var pipe = new NamedPipeServerStream(_pipeName, PipeDirection.InOut,
                    NamedPipeServerStream.MaxAllowedServerInstances, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                try { await pipe.WaitForConnectionAsync(stop).ConfigureAwait(false); }
                catch { pipe.Dispose(); throw; }
                _ = RespondAsync(pipe, select, stop);
            }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
        catch (Exception error) { TrayLog.Write(L.T("快捷方式监听失败。{0}", error.Message)); }
    }

    private static async Task RespondAsync(NamedPipeServerStream pipe, Func<InputSource, Task<bool>> select,
        CancellationToken stop)
    {
        using (pipe)
        {
            try
            {
                var request = new byte[1];
                using var receive = CancellationTokenSource.CreateLinkedTokenSource(stop);
                receive.CancelAfter(TimeSpan.FromSeconds(5));
                await pipe.ReadExactlyAsync(request, receive.Token).ConfigureAwait(false);
                var source = (InputSource)request[0];
                bool ok = Enum.IsDefined(source) && !stop.IsCancellationRequested && await select(source).ConfigureAwait(false);
                await pipe.WriteAsync(new byte[] { ok ? (byte)0 : (byte)1 }).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { TrayLog.Write(L.T("快捷方式请求失败。{0}", error.Message)); }
        }
    }
}
