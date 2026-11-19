using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;
using Button = System.Windows.Controls.Button;
using MenuItem = System.Windows.Controls.MenuItem;

namespace RedMagicMonitor;

public partial class TrayWindow : Window
{
    private const double ScreenInset = 14;
    private const double PreferredPanelHeight = 760;

    private readonly TraySettings _settings;
    private readonly DdcTransport _ddc;
    private readonly BleTransport _ble;
    private readonly DispatcherTimer _dragTimer;
    private readonly DispatcherTimer _idleTimer;
    private readonly Dictionary<InputSource, Button> _ddcSources = new(), _bleSources = new();
    private readonly Dictionary<DdcControl, LevelRow> _levels = new();
    private readonly Dictionary<DdcControl, int> _queued = new();
    private readonly Dictionary<BleControl, OptionRow> _options = new();
    private readonly Dictionary<BleControl, byte> _bleValues = new();
    private KeyValuePair<DdcControl, int>? _inFlight;
    private int? _volumeDrag;
    private InputSource? _ddcInput;
    private readonly InputReading _activeInput = new(), _bluetoothInput = new();
    private int _sourceGeneration;
    private int _activeReadRequest;
    private bool _changingInput;
    private PanelPage _page;
    private bool _ddcSeen, _ddcTarget, _ddcBusy, _draining;
    private bool _bleSeen, _bleConnected, _bleBusy;
    private bool _rendering, _dragging, _userPositioned, _exiting;
    private string _ddcStatus = L.T("等待读取显示器");
    private string _bleStatus = L.T("等待读取蓝牙");
    private string _volumeStatus = L.T("等待读取耳机音量");

    private sealed record LevelRow(Slider Slider, TextBlock Number, Button Less, Button More, TextBlock Note)
    {
        internal int? Confirmed { get; set; }
        internal bool Writable { get; set; }
    }

    private sealed record OptionRow(Grid Row, Button Button);
    private sealed record DonationMethod(string Name, string Detail, string Accent, string ImageUri)
    {
        public string AccessibilityName => L.T("{0} 收款二维码", Name);
    }

    private sealed class InputReading
    {
        internal InputSource? Last { get; private set; }
        internal bool Fresh { get; private set; }
        private DateTime _readAt;

        internal void Clear() { Fresh = false; Last = null; }

        internal void Observe(InputSource? source)
        {
            Fresh = source.HasValue;
            if (source is null) return;
            Last = source;
            _readAt = DateTime.Now;
        }

        internal string Describe(string label)
        {
            if (Last is not InputSource source) return L.T("{0}待确认", label);
            string value = InputSources.Name(source);
            return Fresh ? $"{label} {value}" : L.T("上次{0} {1}（{2:T}）", label, value, _readAt);
        }
    }

    internal event EventHandler? QuitRequested;

    internal TrayWindow(TraySettings settings)
    {
        InitializeComponent();
        Language = System.Windows.Markup.XmlLanguage.GetLanguage(L.Language);
        _settings = settings;
        _ddc = new(settings);
        _ble = new(settings);
        _dragTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(160) };
        _dragTimer.Tick += (_, _) => DrainLevels();
        _idleTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        _idleTimer.Tick += IdleTick;
        _idleTimer.Start();

        AddSources(DdcInputs, _ddcSources, source => SetInput(source));
        AddSources(BleInputs, _bleSources, source => SetBluetooth(BleControl.Input, (byte)source));
        AddLevel(DdcControl.Brightness, L.T("亮度"));
        AddLevel(DdcControl.Contrast, L.T("对比度"));
        AddLevel(DdcControl.Volume, L.T("耳机音量"));
        DonationCards.ItemsSource = new DonationMethod[] {
            new("Venmo", "@weetom", "#2879C6", "pack://application:,,,/Donation/venmo.png"),
            new(L.T("支付宝"), L.T("¥{0:N2}", 6.66m), "#1677FF", "pack://application:,,,/Donation/alipay.png"),
            new(L.T("微信支付"), L.T("¥{0:N2}", 6.66m), "#07AD61", "pack://application:,,,/Donation/wechat-pay.png")
        };
        foreach (var (control, spec) in BleProtocol.Specs)
        {
            if (control == BleControl.Input) continue;
            AddOption(control, spec, spec.Reply == 0xcc ? PictureOptions : LightOptions);
        }

        SystemEvents.UserPreferenceChanged += PreferenceChanged;
        ApplyTheme();
        Closing += ClosingPanel;
        SizeChanged += (_, _) => FitToWorkArea();
        PreviewKeyDown += (_, key) =>
        {
            if (key.Key == Key.Escape && IsVisible) { Hide(); key.Handled = true; }
        };
        _page = settings.Page;
        ApplyPage();
    }

    internal void TogglePanel()
    {
        if (IsVisible) Hide();
        else ShowPanel();
    }

    internal void ShowPanel()
    {
        if (_exiting) return;
        FitToWorkArea();
        try { Startup.IsChecked = LoginStartup.Enabled(); }
        catch (Exception error) { TrayLog.Write(L.T("读取登录启动设置。{0}", error.Message)); }
        Show();
        Activate();
        RequestMissingValues();
    }

    internal void FitToWorkArea()
    {
        if (_dragging || _exiting) return;
        var area = SystemParameters.WorkArea;
        if (_userPositioned)
        {
            var handle = new WindowInteropHelper(this).Handle;
            var pixels = System.Windows.Forms.Screen.FromHandle(handle).WorkingArea;
            var dpi = VisualTreeHelper.GetDpi(this);
            area = new Rect(pixels.X / dpi.DpiScaleX, pixels.Y / dpi.DpiScaleY,
                pixels.Width / dpi.DpiScaleX, pixels.Height / dpi.DpiScaleY);
        }

        MaxHeight = Math.Max(1, area.Height - 2 * ScreenInset);
        Height = Math.Min(PreferredPanelHeight, MaxHeight);
        double right = Math.Max(area.Left, area.Right - Width - ScreenInset);
        double bottom = Math.Max(area.Top, area.Bottom - ActualHeight - ScreenInset);
        Left = _userPositioned ? Math.Clamp(Left, Math.Min(area.Left + ScreenInset, right), right) : right;
        Top = _userPositioned ? Math.Clamp(Top, Math.Min(area.Top + ScreenInset, bottom), bottom) : bottom;
    }

    internal async Task PrepareExitAsync()
    {
        _exiting = true;
        _dragTimer.Stop();
        _idleTimer.Stop();
        _queued.Clear();
        SystemEvents.UserPreferenceChanged -= PreferenceChanged;
        await _ble.DisconnectAsync().WaitAsync(TimeSpan.FromSeconds(5));
    }

    private void ClosingPanel(object? sender, CancelEventArgs args)
    {
        if (_exiting) return;
        args.Cancel = true;
        Hide();
    }

    private void HeaderDrag(object sender, MouseButtonEventArgs args)
    {
        if (args.LeftButton != MouseButtonState.Pressed) return;
        _dragging = true;
        try
        {
            DragMove();
            _userPositioned = true;
        }
        finally
        {
            _dragging = false;
            FitToWorkArea();
        }
    }

    private void HideClicked(object sender, RoutedEventArgs args) => Hide();
    private void SelectDdc(object sender, RoutedEventArgs args) => SelectPage(PanelPage.Ddc);
    private void SelectBluetooth(object sender, RoutedEventArgs args) => SelectPage(PanelPage.Bluetooth);
    private void SelectDonation(object sender, RoutedEventArgs args) => SelectPage(PanelPage.Donation);

    private void SelectPage(PanelPage page)
    {
        if (_page != page)
        {
            _page = page;
            if (page != PanelPage.Donation && _settings.Page != page)
            {
                _settings.Page = page;
                try { _settings.Save(); }
                catch (Exception error) { TrayLog.Write(L.T("保存当前面板。{0}", error.Message)); }
            }
            ApplyPage();
        }
        RequestMissingValues();
    }

    private void ApplyPage()
    {
        bool ddc = _page == PanelPage.Ddc;
        bool bluetooth = _page == PanelPage.Bluetooth;
        bool donation = _page == PanelPage.Donation;
        DdcTab.Tag = ddc ? "selected" : null;
        BleTab.Tag = bluetooth ? "selected" : null;
        DonationTab.Tag = donation ? "selected" : null;
        DdcPage.Visibility = ddc ? Visibility.Visible : Visibility.Collapsed;
        BlePage.Visibility = bluetooth ? Visibility.Visible : Visibility.Collapsed;
        DonationCards.Visibility = donation ? Visibility.Visible : Visibility.Collapsed;
        InputHeading.Visibility = TransportStatus.Visibility = RefreshButton.Visibility =
            donation ? Visibility.Collapsed : Visibility.Visible;
        Disconnect.Visibility = bluetooth ? Visibility.Visible : Visibility.Hidden;
        ChooseMonitor.Visibility = donation ? Visibility.Hidden : Visibility.Visible;
        ShowBindingOptions();
        Body.ScrollToTop();
        Render();
    }

    private void RequestMissingValues()
    {
        if (_page == PanelPage.Ddc)
        {
            if (!_ddcSeen || !_ddcTarget || _ddcInput is null ||
                _levels.Values.Any(row => row.Confirmed is null || !row.Writable)) RefreshDdc();
        }
        else if (_page == PanelPage.Bluetooth)
            RefreshBluetooth(inputOnly: _bleSeen && _bleConnected && !HasMissingBluetoothValues());
    }

    private bool HasMissingBluetoothValues() => BleProtocol.Specs.Keys.Any(control =>
        (control is not (BleControl.FrontColor or BleControl.BackColor) ||
            _bleValues.GetValueOrDefault(BleControl.LightEffect) == 7) && !_bleValues.ContainsKey(control));

    private void AddSources(UniformGrid panel, Dictionary<InputSource, Button> buttons, Action<InputSource> select)
    {
        foreach (var source in InputSources.All)
        {
            var button = new Button { Content = InputSources.Name(source), Margin = new Thickness(2, 0, 2, 0) };
            button.Click += (_, _) => select(source);
            panel.Children.Add(button);
            buttons.Add(source, button);
        }
    }

    private void AddLevel(DdcControl control, string label)
    {
        var heading = new DockPanel { LastChildFill = true };
        var number = new TextBlock { TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(number, Dock.Right);
        heading.Children.Add(number);
        heading.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });

        var less = new Button { Content = "−", MinHeight = 26, Width = 28, Padding = new Thickness(0) };
        var more = new Button { Content = "+", MinHeight = 26, Width = 28, Padding = new Thickness(0) };
        AutomationProperties.SetName(less, L.T("{0}减一", label));
        AutomationProperties.SetName(more, L.T("{0}加一", label));
        var slider = new Slider
        {
            Style = (Style)FindResource("LevelSlider"),
            Margin = new Thickness(9, 0, 9, 0),
            VerticalAlignment = VerticalAlignment.Center,
            IsSnapToTickEnabled = true,
            TickFrequency = 1
        };
        AutomationProperties.SetName(slider, label);
        var grid = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 4, 0, 0) };
        DockPanel.SetDock(more, Dock.Right);
        grid.Children.Add(less);
        grid.Children.Add(more);
        grid.Children.Add(slider);
        var note = new TextBlock { FontSize = 11, Margin = new Thickness(0, 3, 0, 0), TextWrapping = TextWrapping.Wrap };
        note.SetResourceReference(TextBlock.ForegroundProperty, "MutedBrush");
        var row = new StackPanel { Margin = new Thickness(0, 8, 0, 8) };
        row.Children.Add(heading);
        row.Children.Add(grid);
        row.Children.Add(note);
        DdcLevels.Children.Add(row);

        _levels.Add(control, new(slider, number, less, more, note));
        less.Click += (_, _) => QueueLevel(control, (int)slider.Value - 1);
        more.Click += (_, _) => QueueLevel(control, (int)slider.Value + 1);
        if (control == DdcControl.Volume)
        {
            slider.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) =>
                _volumeDrag = (int)slider.Value), true);
            slider.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, drag) =>
            {
                var desired = _volumeDrag;
                _volumeDrag = null;
                if (!drag.Canceled && desired.HasValue) QueueLevel(control, desired.Value);
                Render();
            }), true);
        }
        slider.ValueChanged += (_, change) =>
        {
            if (_rendering) return;
            if (control == DdcControl.Volume && _volumeDrag.HasValue)
            {
                _volumeDrag = (int)change.NewValue;
                number.Text = _volumeDrag.Value.ToString();
                return;
            }
            QueueLevel(control, (int)change.NewValue);
        };
    }

    private void AddOption(BleControl control, BleSpec spec, Panel parent)
    {
        var button = new Button
        {
            MinWidth = 114, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(10, 0, 0, 0),
            MinHeight = 28, Padding = new Thickness(8, 3, 8, 3)
        };
        AutomationProperties.SetName(button, spec.Name);
        var menu = new ContextMenu { Placement = PlacementMode.Bottom, PlacementTarget = button };
        menu.SetResourceReference(BackgroundProperty, "CardBrush");
        menu.SetResourceReference(ForegroundProperty, "TextBrush");
        menu.SetResourceReference(BorderBrushProperty, "StrokeBrush");
        foreach (var choice in spec.Choices)
        {
            var item = new MenuItem { Header = choice.Label };
            item.SetResourceReference(MenuItem.ForegroundProperty, "TextBrush");
            item.Click += (_, _) => SetBluetooth(control, choice.Code);
            menu.Items.Add(item);
        }
        button.ContextMenu = menu;
        button.Click += (_, _) => menu.IsOpen = true;

        var row = new Grid { Margin = new Thickness(0, 3, 0, 3) };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(new TextBlock { Text = spec.Name, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(button, 1);
        row.Children.Add(button);
        parent.Children.Add(row);
        _options.Add(control, new(row, button));
    }

    private async void RefreshDdc(bool discoverAgain = false)
    {
        if (_ddcBusy || _draining || _queued.Count != 0 || _exiting) return;
        _ddcBusy = true;
        int generation = _sourceGeneration;
        int inputRequest = ++_activeReadRequest;
        _ddcStatus = L.T("正在读取显示器…");
        Render();
        try
        {
            if (!await EnsureBound(PanelPage.Ddc, refresh: discoverAgain)) return;
            var snapshot = await _ddc.ReadAsync();
            _ddcSeen = true;
            _ddcTarget = snapshot.TargetPresent;
            if (generation == _sourceGeneration && inputRequest == _activeReadRequest && !_changingInput)
            {
                _ddcInput = snapshot.Input ?? _ddcInput;
                _activeInput.Observe(snapshot.Input);
            }
            _ddcStatus = snapshot.Message;
            _volumeStatus = snapshot.VolumeMessage;
            UpdateLevel(DdcControl.Brightness, snapshot.Brightness, snapshot.Brightness.HasValue);
            UpdateLevel(DdcControl.Contrast, snapshot.Contrast, snapshot.Contrast.HasValue);
            UpdateLevel(DdcControl.Volume, snapshot.Volume, snapshot.VolumeWritable);
        }
        catch (Exception error) { RecordDdcError(error); }
        finally { _ddcBusy = false; Render(); }
    }

    private void UpdateLevel(DdcControl control, int? value, bool writable)
    {
        var row = _levels[control];
        row.Confirmed = value ?? row.Confirmed;
        row.Writable = writable;
    }

    private async void SetInput(InputSource source)
    {
        if (_ddcBusy || _draining || _queued.Count != 0 || !_ddcTarget || _exiting || _changingInput) return;
        BeginInputChange();
        _ddcBusy = true;
        _ddcStatus = L.T("正在切换到 {0}…", InputSources.Name(source));
        Render();
        try
        {
            var result = await _ddc.SetInputAsync(source);
            _ddcStatus = result.Message;
            if (result.Status == DdcInputStatus.Confirmed)
            {
                _ddcInput = result.Value;
                _activeInput.Observe(result.Value);
                _ddcStatus = L.T("视频已确认，正在核对菜单…");
                Render();
                int generation = _sourceGeneration;
                bool aligned = false;
                if (!_bleBusy && !_exiting && !string.IsNullOrWhiteSpace(_settings.BluetoothAddress))
                {
                    try
                    {
                        aligned = await _ble.AlignInputAsync(source, async () =>
                            await CheckActiveInput(generation) == source);
                    }
                    catch (Exception error) { TrayLog.Write(L.T("核对菜单输入。{0}", error.Message)); }
                    _bleConnected = _ble.HasConnection;
                }
                if (aligned)
                {
                    _bluetoothInput.Observe(source);
                    _bleValues[BleControl.Input] = (byte)source;
                }
                _ddcStatus = aligned ? L.T("视频已确认，蓝牙菜单值已确认") : L.T("视频已确认，菜单未确认");
            }
            TrayLog.Write(L.T("DDC 输入源 {0}。{1}", InputSources.Name(source), _ddcStatus));
        }
        catch (Exception error) { RecordDdcError(error); }
        finally
        {
            _ddcBusy = false;
            _changingInput = false;
            Render();
            if (_page == PanelPage.Bluetooth && IsVisible) RequestMissingValues();
        }
    }

    private void BeginInputChange()
    {
        _changingInput = true;
        _sourceGeneration++;
        _activeInput.Observe(null);
        _bluetoothInput.Observe(null);
    }

    private void QueueLevel(DdcControl control, int value)
    {
        if (_ddcBusy || _exiting || !_levels[control].Writable) return;
        int desired = Math.Clamp(value, 0, 100);
        if (DisplayValue(control) == desired) return;
        _queued[control] = desired;
        Render();
        if (!_draining) _dragTimer.Start();
    }

    private int? DisplayValue(DdcControl control)
    {
        if (control == DdcControl.Volume && _volumeDrag.HasValue) return _volumeDrag;
        if (_queued.TryGetValue(control, out int value)) return value;
        if (_inFlight is { } pending && pending.Key == control) return pending.Value;
        return _levels[control].Confirmed;
    }

    private async void DrainLevels()
    {
        _dragTimer.Stop();
        if (_draining || _ddcBusy || _exiting || _queued.Count == 0) return;
        _draining = true;
        var failures = new Dictionary<DdcControl, string>();
        bool readAfterFailure = false;
        Render();
        try
        {
            while (_queued.Count != 0 && !_exiting)
            {
                var pending = _queued.First();
                _queued.Remove(pending.Key);
                var row = _levels[pending.Key];
                if (!row.Writable) continue;
                if (row.Confirmed == pending.Value)
                {
                    failures.Remove(pending.Key);
                    continue;
                }
                _inFlight = pending;
                _ddcStatus = L.T("正在确认{0}…", LevelLabel(pending.Key));
                Render();
                try
                {
                    var result = await _ddc.SetLevelAsync(pending.Key, pending.Value);
                    if (result.Confirmed)
                    {
                        row.Confirmed = result.Value;
                        failures.Remove(pending.Key);
                    }
                    else
                    {
                        failures[pending.Key] = L.T("{0}回读未确认", LevelLabel(pending.Key));
                        readAfterFailure = true;
                    }
                    _ddcStatus = result.Message;
                    TrayLog.Write(L.T("DDC {0}。{1}", LevelLabel(pending.Key), result.Message));
                }
                catch (Exception error)
                {
                    failures[pending.Key] = L.T("{0}调节未确认", LevelLabel(pending.Key));
                    readAfterFailure = true;
                    RecordDdcError(error);
                    if (pending.Key == DdcControl.Volume)
                    {
                        row.Writable = false;
                        _volumeStatus = L.T("耳机音量回读失败");
                    }
                }
                finally { _inFlight = null; Render(); }
            }
            if (failures.Count != 0) _ddcStatus = string.Join(" · ", failures.Values);
        }
        finally
        {
            _draining = false;
            Render();
            if (readAfterFailure && IsVisible && _page == PanelPage.Ddc && !_volumeDrag.HasValue)
                RefreshDdc();
        }
    }

    private static string LevelLabel(DdcControl control) => control switch
    {
        DdcControl.Brightness => L.T("亮度"), DdcControl.Contrast => L.T("对比度"), _ => L.T("耳机音量")
    };

    private void RecordDdcError(Exception error)
    {
        _ddcStatus = error.Message;
        TrayLog.Write(error.Message);
    }

    private void RestoreDefaults(object sender, RoutedEventArgs args)
    {
        if (!ResetDdc.IsEnabled) return;
        QueueLevel(DdcControl.Brightness, 50);
        QueueLevel(DdcControl.Contrast, 50);
    }

    private async void RefreshBluetooth(bool inputOnly = false, bool discoverAgain = false)
    {
        if (_bleBusy || _exiting || _changingInput) return;
        int generation = _sourceGeneration;
        _activeInput.Observe(null);
        _bluetoothInput.Observe(null);
        _bleBusy = true;
        _bleStatus = L.T("正在读取蓝牙…");
        Render();
        try
        {
            if (!await EnsureBound(PanelPage.Bluetooth, refresh: discoverAgain)) return;
            await CheckActiveInput(generation);
            var snapshot = inputOnly ? await _ble.ReadInputAsync() : await _ble.ReadAsync();
            _bleSeen = true;
            _bleConnected = snapshot.Connected;
            _bleStatus = snapshot.Message;
            foreach (var (control, value) in snapshot.Values)
            {
                if (control == BleControl.Input)
                {
                    if (generation != _sourceGeneration) continue;
                    _bluetoothInput.Observe(InputSources.FromBluetooth(value));
                }
                _bleValues[control] = value;
            }
        }
        catch (Exception error) { RecordBleError(error); }
        finally
        {
            _bleBusy = false;
            Render();
            if (generation != _sourceGeneration && !_changingInput && !_exiting && IsVisible &&
                _page == PanelPage.Bluetooth) RequestMissingValues();
        }
    }

    private async Task<InputSource?> CheckActiveInput(int generation)
    {
        if (_exiting || generation != _sourceGeneration) return null;
        int request = ++_activeReadRequest;
        InputSource? source = null;
        try { source = await _ddc.ReadInputAsync(); }
        catch (Exception error) { TrayLog.Write(L.T("核对活动输入。{0}", error.Message)); }
        if (_exiting || generation != _sourceGeneration || request != _activeReadRequest) return null;
        _activeInput.Observe(source);
        if (source.HasValue) _ddcInput = source;
        Render();
        return source;
    }

    private async void SetBluetooth(BleControl control, byte value)
    {
        bool sourceChange = control == BleControl.Input;
        bool returnToTypeC = sourceChange && value == (byte)InputSource.TypeC;
        if (!IsBound(PanelPage.Bluetooth) || _bleBusy || _exiting || _changingInput || (!sourceChange && !_bleValues.ContainsKey(control))) return;
        if (sourceChange) BeginInputChange();
        _bleBusy = true;
        var spec = BleProtocol.Specs[control];
        _bleStatus = returnToTypeC ? L.T("正在通过 DDC 切换到 Type-C…") : L.T("正在确认{0}…", spec.Name);
        byte oldEffect = _bleValues.GetValueOrDefault(BleControl.LightEffect);
        Render();

        bool fetchLights = false;
        try
        {
            var result = returnToTypeC
                ? await SelectTypeCFromBluetooth(_sourceGeneration)
                : await _ble.SetAsync(control, value);
            _bleConnected = _ble.HasConnection;
            if (result is { Confirmed: true, Value: byte verified })
            {
                _bleValues[control] = verified;
                if (sourceChange) _bluetoothInput.Observe(InputSources.FromBluetooth(verified));
                if (control == BleControl.LightEffect && verified != oldEffect)
                {
                    _bleValues.Remove(BleControl.FrontColor);
                    _bleValues.Remove(BleControl.BackColor);
                }
                fetchLights = control is BleControl.LightEffect or BleControl.LightPower;
            }
            _bleStatus = result.Message;
            TrayLog.Write(L.T("蓝牙 {0}。{1}", spec.Name, result.Message));
        }
        catch (Exception error) { RecordBleError(error); }
        finally
        {
            if (sourceChange)
            {
                if (!returnToTypeC && !_exiting) await CheckActiveInput(_sourceGeneration);
                _changingInput = false;
            }
            _bleBusy = false;
            Render();
        }
        if (fetchLights && !_exiting && _page == PanelPage.Bluetooth) RefreshBluetooth();
    }

    private async Task<WriteResult<byte>> SelectTypeCFromBluetooth(int generation)
    {
        const InputSource source = InputSource.TypeC;
        bool Current() => !_exiting && _sourceGeneration == generation;
        var result = await TypeCReturn.SelectAsync(
            async () =>
            {
                var video = await _ddc.SetInputAsync(source);
                if (Current() && video.Status == DdcInputStatus.Confirmed)
                {
                    _ddcInput = video.Value;
                    _activeInput.Observe(video.Value);
                    _bleStatus = L.T("DDC 已确认 Type-C，正在核对菜单…");
                    Render();
                }
                return video;
            },
            () => Current() ? _ble.AlignInputAsync(source, async () => await CheckActiveInput(generation) == source)
                : Task.FromResult(false),
            async () => Current() && (await _ble.SetAsync(BleControl.Input, (byte)source)).Confirmed,
            TrayLog.Write);
        if ((result.Video.Status == DdcInputStatus.Unavailable || result.Video.RetryFrom == InputSource.DisplayPort) && Current())
            await CheckActiveInput(generation);
        string message = result.Message;
        if (_activeInput.Fresh && _activeInput.Last is InputSource active)
            message = L.T("DDC 活动输入 {0} · ", InputSources.Name(active)) +
                (result.MenuConfirmed ? L.T("菜单已确认") : L.T("菜单未确认"));
        return new(result.MenuConfirmed, result.MenuConfirmed ? (byte)source : null, message);
    }

    private void RecordBleError(Exception error)
    {
        _bleConnected = _ble.HasConnection;
        _bleStatus = error.Message;
        TrayLog.Write(error.Message);
    }

    private async void DisconnectClicked(object sender, RoutedEventArgs args)
    {
        if (_bleBusy || _exiting || _changingInput) return;
        _bleBusy = true;
        Render();
        try
        {
            await _ble.DisconnectAsync();
            _bleConnected = false;
            _bluetoothInput.Observe(null);
            _bleStatus = L.T("蓝牙已断开");
            TrayLog.Write(L.T("手动断开蓝牙。"));
        }
        catch (Exception error) { RecordBleError(error); }
        finally { _bleBusy = false; Render(); }
    }

    private async void IdleTick(object? sender, EventArgs args)
    {
        if (_bleBusy || !_bleConnected || _exiting) return;
        try
        {
            if (await _ble.DisconnectIfIdleAsync())
            {
                _bleConnected = false;
                _bluetoothInput.Observe(null);
                _bleStatus = L.T("蓝牙闲置五分钟，已断开");
                Render();
            }
        }
        catch (Exception error) { RecordBleError(error); Render(); }
    }

    private void Render()
    {
        if (_exiting) return;
        _rendering = true;
        try
        {
            ChooseMonitor.IsEnabled = BindingOptions.IsEnabled = CanSelectMonitor;
            string? bound = _page == PanelPage.Bluetooth ? _settings.BluetoothAddress : _settings.MonitorSerial;
            ChooseMonitor.ToolTip = string.IsNullOrWhiteSpace(bound) ? L.T("选择显示器") : L.T("选择显示器") + " · " + bound;
            RenderInputs(_ddcSources, _ddcInput, _ddcTarget && !_ddcBusy && !_draining && _queued.Count == 0 && !_changingInput);
            RenderInputs(_bleSources, _activeInput.Fresh ? _activeInput.Last : null, IsBound(PanelPage.Bluetooth) && !_bleBusy && !_changingInput);
            BleInputDetail.Text = _activeInput.Describe(L.T("DDC 活动输入")) + "  ·  " + _bluetoothInput.Describe(L.T("蓝牙报告"));
            ResetDdc.IsEnabled = !_ddcBusy && !_draining && _queued.Count == 0 &&
                _levels[DdcControl.Brightness].Writable && _levels[DdcControl.Contrast].Writable;
            Disconnect.IsEnabled = _bleConnected && !_bleBusy && !_changingInput;
            StatusText.Text = _page == PanelPage.Ddc ? _ddcStatus : _bleStatus;

            foreach (var (control, row) in _levels)
            {
                int? value = DisplayValue(control);
                if (value.HasValue && row.Slider.Value != value.Value) row.Slider.Value = value.Value;
                row.Number.Text = value?.ToString() ?? "—";
                row.Slider.IsEnabled = !_ddcBusy && row.Writable;
                row.Less.IsEnabled = row.Slider.IsEnabled && value > 0;
                row.More.IsEnabled = row.Slider.IsEnabled && value < 100;
                row.Note.Text = control == DdcControl.Volume ? _volumeStatus :
                    !row.Writable && row.Confirmed.HasValue ? L.T("保留上次回读") : "";
                row.Note.Visibility = row.Note.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            }

            bool split = _bleValues.GetValueOrDefault(BleControl.LightEffect) == 7;
            foreach (var (control, row) in _options)
            {
                bool hasValue = _bleValues.TryGetValue(control, out byte code);
                string? label = hasValue ? BleProtocol.Specs[control].Choices.FirstOrDefault(choice => choice.Code == code)?.Label : null;
                row.Button.Content = label is null ? "—" : $"{label}  ▾";
                row.Button.IsEnabled = !_bleBusy && !_changingInput && hasValue;
                if (control is BleControl.FrontColor or BleControl.BackColor)
                    row.Row.Visibility = split ? Visibility.Visible : Visibility.Collapsed;
            }
        }
        finally { _rendering = false; }
    }

    private static void RenderInputs(Dictionary<InputSource, Button> buttons, InputSource? source, bool enabled)
    {
        foreach (var (input, button) in buttons)
        {
            button.Tag = input == source ? "selected" : null;
            button.IsEnabled = enabled;
        }
    }

    private void RefreshClicked(object sender, RoutedEventArgs args)
    {
        if (_page == PanelPage.Ddc) RefreshDdc(discoverAgain: true);
        else if (_page == PanelPage.Bluetooth) RefreshBluetooth(discoverAgain: true);
    }

    private void ChangeStartup(object sender, RoutedEventArgs args)
    {
        try
        {
            LoginStartup.Set(Startup.IsChecked == true);
            Startup.IsChecked = LoginStartup.Enabled();
        }
        catch (Exception error)
        {
            TrayLog.Write(L.T("修改登录启动设置。{0}", error.Message));
            try { Startup.IsChecked = LoginStartup.Enabled(); } catch { Startup.IsChecked = null; }
            StatusText.Text = L.T("无法修改登录启动设置");
        }
    }

    private void OpenGitHub(object sender, RoutedEventArgs args)
    {
        try
        {
            Process.Start(new ProcessStartInfo("https://github.com/WeeTom/redmagic-monitor-control") { UseShellExecute = true });
        }
        catch (Win32Exception error)
        {
            TrayLog.Write(error.Message);
            MessageBox.Show(this, L.T("无法使用默认浏览器打开项目仓库。"), "GitHub", MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }

    private void OpenLog(object sender, RoutedEventArgs args)
    {
        try
        {
            TrayLog.Write(L.T("打开本机日志。"));
            Process.Start(new ProcessStartInfo(TrayLog.PathName) { UseShellExecute = true });
        }
        catch (Exception error)
        {
            TrayLog.Write(error.Message);
            StatusText.Text = L.T("无法打开日志");
        }
    }

    private void QuitClicked(object sender, RoutedEventArgs args) => QuitRequested?.Invoke(this, EventArgs.Empty);

    private void PreferenceChanged(object sender, UserPreferenceChangedEventArgs args)
    {
        Dispatcher.BeginInvoke(new Action(ApplyTheme));
    }

    private void ApplyTheme()
    {
        bool light = false;
        try
        {
            light = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 0) is 1;
        }
        catch (Exception error) { TrayLog.Write(L.T("读取 Windows 配色。{0}", error.Message)); }

        UsePalette(light);
    }

    private void UsePalette(bool light)
    {
        SetBrush("PanelBrush", light ? "#FAF7F9" : "#161518");
        SetBrush("CardBrush", light ? "#F1EBF1" : "#211F24");
        SetBrush("HoverBrush", light ? "#E8DDE7" : "#302C35");
        SetBrush("StrokeBrush", light ? "#D7CAD5" : "#393540");
        SetBrush("TextBrush", light ? "#221A23" : "#F7F3F5");
        SetBrush("MutedBrush", light ? "#665568" : "#B6ACBA");
        SetBrush("AccentBrush", light ? "#AA2847" : "#FC647C");
        SetBrush("AccentSurfaceBrush", light ? "#F8D9E2" : "#532631");
        SetBrush("TrackBrush", light ? "#D5C4D2" : "#534956");
    }

    private void SetBrush(string name, string hex)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        brush.Freeze();
        Resources[name] = brush;
    }
}
