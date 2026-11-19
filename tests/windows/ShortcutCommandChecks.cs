using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using RedMagicMonitor;

internal static class ShortcutCommandChecks
{
    internal static void Run()
    {
        var folder = Directory.CreateTempSubdirectory("RedMagicShortcutChecks-");
        try
        {
            string path = folder.CreateSubdirectory("安装 и тест").FullName;
            string file = Path.Combine(path, "切换输入.lnk");
            string executable = Path.Combine(path, "红魔 Monitor.exe");
            File.Copy(Environment.ProcessPath!, executable);
            foreach (var source in InputSources.All)
            {
                InputShortcut.Save(file, executable, source, overwrite: File.Exists(file));
                var (targetPath, arguments) = Load(file);
                Check(string.Equals(targetPath, executable, StringComparison.OrdinalIgnoreCase)
                    && ShortcutChannel.TryParse(arguments.Split(' '), out var parsed, out var directory)
                    && parsed == source && directory == null, $"exported {source} shell link round trip");
            }
            string previous = TraySettings.DirectoryPath;
            try
            {
                TraySettings.SetDataDirectory(path);
                InputShortcut.Save(file, executable, InputSource.DisplayPort, overwrite: true);
                var (_, arguments) = Load(file);
                Check(arguments == $"--switch-input dp --data-dir \"{path}\"", "Unicode profile arguments in exported shell link");
            }
            finally { TraySettings.SetDataDirectory(previous); }

            string[] scoped = ["--data-dir", folder.FullName, "--switch-input", "dp"];
            Check(ShortcutChannel.TryParse(scoped, out var target, out var profile)
                && target == InputSource.DisplayPort && profile == folder.FullName, "custom device profile");
            foreach (string[] invalid in new string[][] {
                ["--switch-input"], ["--switch-input", "unknown"], ["--switch-input", "1"],
                ["--switch-input", "dp", "--switch-input", "type-c"], ["--switch-input", "dp", "--probe-ddc"]
            })
                Check(!ShortcutChannel.TryParse(invalid, out _, out _), "reject " + string.Join(" ", invalid));
        }
        finally { folder.Delete(true); }
    }

    private static (string Target, string Arguments) Load(string file)
    {
        var link = (IShellLinkW)new ShellLinkObject();
        try
        {
            ((IPersistFile)link).Load(file, 0);
            var target = new StringBuilder(32768);
            var args = new StringBuilder(32768);
            link.GetPath(target, target.Capacity, IntPtr.Zero, 4); // SLGP_RAWPATH
            link.GetArguments(args, args.Capacity);
            return (target.ToString(), args.ToString());
        }
        finally { Marshal.FinalReleaseComObject(link); }
    }

    private static void Check(bool passed, string label)
    {
        if (!passed) throw new InvalidOperationException(label);
        Console.WriteLine($"PASS shortcut {label}");
    }
}
