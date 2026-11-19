using System;
using System.IO;
using System.Runtime.InteropServices;

namespace RedMagicMonitor;

internal static class InputShortcut
{
    internal static void Save(string destination, string executable, InputSource source, bool overwrite)
    {
        string path = Path.GetFullPath(destination);
        if (!string.Equals(Path.GetExtension(path), ".lnk", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException(L.T("快捷方式文件名需要以 .lnk 结尾。"));
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable))
            throw new FileNotFoundException(L.T("找不到快捷方式的目标程序。"), executable);

        string arguments = $"--switch-input {InputSources.CommandToken(source)}";
        string directory = TraySettings.DirectoryPath;
        if (!string.Equals(directory, TraySettings.DefaultDirectoryPath, StringComparison.OrdinalIgnoreCase))
        {
            // Windows doubles trailing backslashes before a closing argument quote.
            if (directory.Contains('"')) throw new ArgumentException(L.T("配置目录路径包含无效的引号。"));
            int trailingSlashes = directory.Length - directory.TrimEnd('\\').Length;
            arguments += $" --data-dir \"{directory}{new string('\\', trailingSlashes)}\"";
        }

        string temporary = Path.Combine(Path.GetDirectoryName(path)!, $".{Guid.NewGuid():N}.lnk");
        try
        {
            WriteShellLink(temporary, executable, arguments, L.T("切换红魔显示器到 {0}", InputSources.Name(source)));
            File.Move(temporary, path, overwrite);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    private static void WriteShellLink(string path, string executable, string arguments, string description)
    {
        Type shellType = Type.GetTypeFromProgID("WScript.Shell", throwOnError: true)!;
        dynamic shell = Activator.CreateInstance(shellType)!;
        try
        {
            dynamic link = shell.CreateShortcut(path);
            try
            {
                link.TargetPath = executable;
                link.Arguments = arguments;
                link.WorkingDirectory = Path.GetDirectoryName(executable);
                link.Description = description;
                link.IconLocation = executable + ",0";
                link.Save();
            }
            finally { Marshal.FinalReleaseComObject((object)link); }
        }
        finally { Marshal.FinalReleaseComObject((object)shell); }
    }
}
