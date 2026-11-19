using System.Runtime.InteropServices;
using RedMagicMonitor;

internal static class ShortcutCommandChecks
{
    internal static void Run()
    {
        var folder = Directory.CreateTempSubdirectory("RedMagicShortcutChecks-");
        string file = Path.Combine(folder.FullName, "切换输入.lnk");
        string executable = Environment.ProcessPath!;
        dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true)!)!;
        try
        {
            foreach (var source in InputSources.All)
            {
                InputShortcut.Save(file, executable, source, overwrite: File.Exists(file));
                dynamic saved = shell.CreateShortcut(file);
                try
                {
                    string arguments = saved.Arguments;
                    Check(string.Equals((string)saved.TargetPath, executable, StringComparison.OrdinalIgnoreCase)
                        && ShortcutChannel.TryParse(arguments.Split(' '), out var parsed, out var directory)
                        && parsed == source && directory == null, $"exported {source} shell link round trip");
                }
                finally { Marshal.FinalReleaseComObject((object)saved); }
            }
            string[] scoped = ["--data-dir", folder.FullName, "--switch-input", "dp"];
            Check(ShortcutChannel.TryParse(scoped, out var target, out var profile)
                && target == InputSource.DisplayPort && profile == folder.FullName, "custom device profile");
            foreach (string[] invalid in new string[][] {
                ["--switch-input"], ["--switch-input", "unknown"], ["--switch-input", "1"],
                ["--switch-input", "dp", "--switch-input", "type-c"], ["--switch-input", "dp", "--probe-ddc"]
            })
                Check(!ShortcutChannel.TryParse(invalid, out _, out _), "reject " + string.Join(" ", invalid));
        }
        finally
        {
            Marshal.FinalReleaseComObject((object)shell);
            File.Delete(file);
            folder.Delete();
        }
    }

    private static void Check(bool passed, string label)
    {
        if (!passed) throw new InvalidOperationException(label);
        Console.WriteLine($"PASS shortcut {label}");
    }
}
