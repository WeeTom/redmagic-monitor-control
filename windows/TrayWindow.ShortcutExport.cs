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
            var menu = new ContextMenu { Placement = PlacementMode.Bottom, PlacementTarget = button };
            menu.SetResourceReference(BackgroundProperty, "CardBrush");
            menu.SetResourceReference(ForegroundProperty, "TextBrush");
            menu.SetResourceReference(BorderBrushProperty, "StrokeBrush");
            foreach (var source in InputSources.All)
            {
                var item = new MenuItem { Header = InputSources.Name(source) };
                item.SetResourceReference(ForegroundProperty, "TextBrush");
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
                Title = $"导出切换到 {label} 的快捷方式",
                FileName = $"红魔显示器 - {label}.lnk",
                Filter = "Windows 快捷方式 (*.lnk)|*.lnk",
                DefaultExt = ".lnk",
                DereferenceLinks = false,
                OverwritePrompt = false
            };
            if (dialog.ShowDialog(this) != true) return;
            bool overwrite = File.Exists(dialog.FileName);
            if (overwrite && MessageBox.Show(this, $"替换现有快捷方式？\n{dialog.FileName}", "导出快捷方式",
                MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;

            string executable = Environment.ProcessPath ?? throw new InvalidOperationException("无法定位托盘程序。");
            InputShortcut.Save(dialog.FileName, executable, source, overwrite);
            string message = $"已导出快捷方式 {Path.GetFileName(dialog.FileName)}";
            if (_page == TransportPage.Ddc) _ddcStatus = message;
            else _bleStatus = message;
            Render();
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "导出快捷方式失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
