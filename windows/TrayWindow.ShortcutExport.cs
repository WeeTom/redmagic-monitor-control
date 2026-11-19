using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using Microsoft.Win32;

namespace RedMagicMonitor;

public partial class TrayWindow
{
    private void ChooseShortcutInput(object sender, RoutedEventArgs args)
    {
        var button = (Button)sender;
        if (button.ContextMenu is null)
        {
            var menu = new ContextMenu
            {
                Style = (Style)FindResource("ExportMenu"),
                Placement = PlacementMode.Bottom,
                PlacementTarget = button
            };
            foreach (var source in InputSources.All)
            {
                var item = new MenuItem { Header = InputSources.Name(source) };
                item.Click += (_, _) => ExportShortcut(source);
                menu.Items.Add(item);
            }
            button.ContextMenu = menu;
        }
        button.ContextMenu.IsOpen = true;
    }

    private void ExportShortcut(InputSource source)
    {
        try
        {
            string label = InputSources.Name(source);
            var dialog = new SaveFileDialog
            {
                Title = L.T("导出切换到 {0} 的快捷方式", label),
                FileName = L.T("红魔显示器 - {0}.lnk", label),
                Filter = L.T("Windows 快捷方式 (*.lnk)|*.lnk"),
                DefaultExt = ".lnk",
                DereferenceLinks = false,
                OverwritePrompt = false
            };
            if (dialog.ShowDialog(this) != true) return;
            bool overwrite = File.Exists(dialog.FileName);
            if (overwrite && MessageBox.Show(this, L.T("替换现有快捷方式？\n{0}", dialog.FileName), L.T("导出快捷方式"),
                MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;

            string executable = Environment.ProcessPath ?? throw new InvalidOperationException(L.T("无法定位托盘程序。"));
            InputShortcut.Save(dialog.FileName, executable, source, overwrite);
            string message = L.T("已导出快捷方式 {0}", Path.GetFileName(dialog.FileName));
            if (_page == PanelPage.Ddc) _ddcStatus = message;
            else _bleStatus = message;
            Render();
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, L.T("导出快捷方式失败"), MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
