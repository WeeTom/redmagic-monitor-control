using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace RedMagicMonitor;

public partial class TrayWindow
{
    private sealed record BindingOption(string Label, string? Serial = null, BleCandidate? Bluetooth = null);
    private sealed class DiscoveryState
    {
        internal List<BindingOption> Options = [];
        internal DateTime Scanned;
    }

    private readonly DiscoveryState _ddcDiscovery = new(), _bleDiscovery = new();

    private DiscoveryState Discovery(PanelPage page) => page == PanelPage.Ddc ? _ddcDiscovery : _bleDiscovery;

    private bool IsBound(PanelPage page) => !string.IsNullOrWhiteSpace(
        page == PanelPage.Ddc ? _settings.MonitorSerial : _settings.BluetoothAddress);

    private static string DiscoveryPrompt(List<BindingOption> options)
    {
        if (options.Count == 0) return L.T("未找到显示器。请检查连接后刷新。");
        return options.Any(o => o.Serial != null || o.Bluetooth != null) ? L.T("请选择要控制的显示器。")
            : L.T("无法核实所选显示器的身份。");
    }

    private void DiscoveryStatus(PanelPage page, string message)
    {
        if (page == PanelPage.Ddc) _ddcStatus = message;
        else _bleStatus = message;
        Render();
    }

    // All binding commits run on the dispatcher. DDC enumeration, BLE scanning
    // and GATT identity checks do not block it or send monitor SET commands.
    private async Task<bool> EnsureBound(PanelPage page, bool refresh = false, bool choose = false)
    {
        if (IsBound(page) && !choose) return true;
        var state = Discovery(page);
        if (!refresh && DateTime.UtcNow - state.Scanned < TimeSpan.FromSeconds(20))
        {
            DiscoveryStatus(page, DiscoveryPrompt(state.Options));
            return false;
        }

        DiscoveryStatus(page, L.T("正在查找显示器…"));
        state.Options.Clear();
        ShowBindingOptions();
        List<BindingOption> options;
        if (page == PanelPage.Ddc)
        {
            var candidates = await Task.Run(() => DdcDisplay.Candidates());
            options = candidates.Select(c => new BindingOption(string.IsNullOrWhiteSpace(c.Serial) ? c.GdiName :
                $"{c.Serial} · {c.GdiName}", c.CanBind ? c.Serial : null)).ToList();
        }
        else
        {
            var candidates = await WinBleLink.DiscoverAsync();
            options = candidates.Select(c => new BindingOption(c.Label, Bluetooth: c)).ToList();
        }
        if (_exiting) return false;
        state.Scanned = DateTime.UtcNow;
        state.Options = options;
        ShowBindingOptions();
        if (!choose && options.Count == 1 && (options[0].Serial != null || options[0].Bluetooth != null))
        {
            await BindOption(page, options[0]);
            return !_exiting && IsBound(page);
        }
        DiscoveryStatus(page, DiscoveryPrompt(options));
        return false;
    }

    private void ShowBindingOptions()
    {
        BindingOptions.Children.Clear();
        if (_page == PanelPage.Donation) return;
        var page = _page;
        foreach (var option in Discovery(page).Options)
        {
            var button = new Button {
                Content = option.Label, IsEnabled = option.Serial != null || option.Bluetooth != null,
                Margin = new Thickness(0, 0, 0, 4)
            };
            button.Click += (_, _) => SelectBinding(page, option);
            BindingOptions.Children.Add(button);
        }
    }

    private bool CanSelectMonitor => !_exiting && !_changingInput && !_ddcBusy && !_bleBusy && !_draining &&
        _queued.Count == 0 && !_volumeDrag.HasValue;

    private void SetBindingBusy(PanelPage page, bool busy)
    {
        if (page == PanelPage.Ddc) _ddcBusy = busy;
        else _bleBusy = busy;
        Render();
    }

    private async void ChooseMonitorClicked(object sender, RoutedEventArgs args)
    {
        var page = _page;
        if (page == PanelPage.Donation || !CanSelectMonitor) return;
        SetBindingBusy(page, true);
        try { await EnsureBound(page, refresh: true, choose: true); }
        catch (Exception error) { DiscoveryStatus(page, error.Message); }
        finally { SetBindingBusy(page, false); }
    }

    private async void SelectBinding(PanelPage page, BindingOption option)
    {
        if (page != _page || !CanSelectMonitor) return;
        SetBindingBusy(page, true);
        bool bound = false;
        try
        {
            await BindOption(page, option);
            bound = true;
        }
        catch (Exception error) { DiscoveryStatus(page, error.Message); }
        finally { SetBindingBusy(page, false); }
        if (!_exiting && bound && _page == page) RequestMissingValues();
    }

    private async Task BindOption(PanelPage page, BindingOption option)
    {
        if (page == PanelPage.Ddc && option.Serial is string serial)
        {
            // A choice can remain visible after a cable is removed or a monitor is replaced.
            var current = await Task.Run(() => DdcDisplay.Candidates(serial));
            if (current.Count != 1 || !current[0].CanBind)
                throw new IOException(L.T("无法核实所选显示器的身份。"));
            if (_exiting) return;
            _settings.BindDdc(serial);
            _ddcSeen = _ddcTarget = false;
            _ddcInput = null;
            _activeInput.Clear();
            foreach (var row in _levels.Values) { row.Writable = false; row.Confirmed = null; }
        }
        else if (option.Bluetooth is { } candidate)
        {
            DiscoveryStatus(page, L.T("正在核实显示器身份…"));
            var identity = await WinBleLink.VerifyCandidateAsync(candidate);
            if (_exiting) return;
            await _ble.DisconnectAsync();
            if (_exiting) return;
            _settings.BindBluetooth(identity.Address, identity.DeviceId);
            _bleSeen = _bleConnected = false;
            _bleValues.Clear();
            _bluetoothInput.Clear();
        }
        Discovery(page).Options.Clear();
        ShowBindingOptions();
    }
}
