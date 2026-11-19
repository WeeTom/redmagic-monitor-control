using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Windows;
using System.Windows.Interop;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace RedMagicMonitor;

public partial class App : Application
{
    private Mutex? _instance;
    private bool _ownsInstance;
    private uint _openMessage;
    private Forms.NotifyIcon? _tray;
    private Drawing.Icon? _icon;
    private (bool DarkInk, int Size) _iconAppearance;
    private TrayWindow? _panel;
    private HwndSource? _hwnd;
    private bool _quitting;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            var args = e.Args;
            int home = Array.IndexOf(args, "--data-dir");
            if (home >= 0)
            {
                if (home + 1 == args.Length) throw new ArgumentException("--data-dir requires a path.");
                TraySettings.SetDataDirectory(args[home + 1]);
            }
            var settings = TraySettings.Load();

            if (args.Contains("--probe-ddc") || args.Contains("--probe-bluetooth"))
            {
                Directory.CreateDirectory(TraySettings.DirectoryPath);
                var options = new JsonSerializerOptions { WriteIndented = true };
                if (args.Contains("--probe-ddc"))
                {
                    var result = await new DdcTransport(settings).ReadAsync();
                    File.WriteAllText(Path.Combine(TraySettings.DirectoryPath, "ddc-read.json"), JsonSerializer.Serialize(result, options));
                }
                else
                {
                    var ble = new BleTransport(settings);
                    try
                    {
                        var result = await ble.ReadAsync();
                        File.WriteAllText(Path.Combine(TraySettings.DirectoryPath, "bluetooth-read.json"), JsonSerializer.Serialize(result, options));
                    }
                    finally { await ble.DisconnectAsync(); }
                }
                Shutdown();
                return;
            }

            _openMessage = RegisterWindowMessage("RedMagicMonitor.OpenPanel.050");
            _instance = new Mutex(true, @"Local\RedMagicMonitor.Tray.050", out _ownsInstance);
            if (!_ownsInstance)
            {
                if (!args.Contains("--background")) PostMessage(0xffff, _openMessage, 0, 0);
                Shutdown();
                return;
            }

            _panel = new TrayWindow(settings);
            MainWindow = _panel;
            var handle = new WindowInteropHelper(_panel).EnsureHandle();
            _hwnd = HwndSource.FromHwnd(handle);
            _hwnd?.AddHook(WindowMessage);

            _tray = new Forms.NotifyIcon { Text = "红魔显示器" };
            UpdateTrayIcon();
            _tray.Visible = true;
            _tray.MouseClick += (_, click) =>
            {
                if (click.Button == Forms.MouseButtons.Left)
                    Dispatcher.BeginInvoke(new Action(() => _panel.TogglePanel()));
            };
            _panel.QuitRequested += Quit;
            TrayLog.Write("红魔显示器 0.5.0 托盘已启动。");
            if (args.Contains("--show")) _panel.ShowPanel();
        }
        catch (Exception error)
        {
            TrayLog.Write(error.ToString());
            Shutdown(1);
        }
    }

    private nint WindowMessage(nint hwnd, int message, nint wparam, nint lparam, ref bool handled)
    {
        // Match the macOS template icon to the current Windows taskbar theme.
        const int wmSettingChange = 0x001a, wmDisplayChange = 0x007e, wmDpiChanged = 0x02e0, wmThemeChanged = 0x031a;
        if (message is wmSettingChange or wmDisplayChange or wmDpiChanged or wmThemeChanged)
            Dispatcher.BeginInvoke(new Action(UpdateTrayIcon));

        if (_openMessage != 0 && (uint)message == _openMessage)
        {
            Dispatcher.BeginInvoke(new Action(() => _panel?.ShowPanel()));
            handled = true;
        }
        return 0;
    }

    private void UpdateTrayIcon()
    {
        if (_tray is null || _quitting) return;
        bool darkInk = SystemParameters.HighContrast
            ? Drawing.SystemColors.Window.GetBrightness() > 0.5f
            : Microsoft.Win32.Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "SystemUsesLightTheme", 0) is 1;
        var taskbar = FindWindow("Shell_TrayWnd", null);
        uint dpi = taskbar == 0 ? 96u : GetDpiForWindow(taskbar);
        int size = Math.Max(16, GetSystemMetricsForDpi(49, dpi == 0 ? 96u : dpi));
        if (_icon is not null && _iconAppearance == (darkInk, size)) return;

        string resource = darkInk ? "TrayBlack.ico" : "TrayWhite.ico";
        using var stream = typeof(App).Assembly.GetManifestResourceStream(resource)
            ?? throw new FileNotFoundException(resource);
        using var source = new Drawing.Icon(stream, size, size);
        var icon = (Drawing.Icon)source.Clone();
        var previous = _icon;
        _tray.Icon = icon;
        _icon = icon;
        _iconAppearance = (darkInk, size);
        previous?.Dispose();
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint FindWindow(string className, string? title);
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetricsForDpi(int index, uint dpi);

    private async void Quit(object? sender, EventArgs e)
    {
        if (_quitting) return;
        _quitting = true;
        if (_tray is not null) _tray.Visible = false;
        if (_panel is not null)
        {
            _panel.Hide();
            try { await _panel.PrepareExitAsync(); }
            catch (Exception error) { TrayLog.Write($"退出时释放蓝牙。{error.Message}"); }
        }
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _hwnd?.RemoveHook(WindowMessage);
        _tray?.Dispose();
        _icon?.Dispose();
        if (_ownsInstance) _instance?.ReleaseMutex();
        _instance?.Dispose();
        base.OnExit(e);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll")]
    private static extern bool PostMessage(nint hwnd, uint message, nint wparam, nint lparam);
}
