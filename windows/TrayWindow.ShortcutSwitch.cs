using System;
using System.Diagnostics;
using System.Threading.Tasks;

namespace RedMagicMonitor;

public partial class TrayWindow
{
    internal async Task<WriteResult<InputSource>> SwitchShortcutAsync(InputSource source)
    {
        Dispatcher.VerifyAccess();
        long start = Stopwatch.GetTimestamp();
        while (!_exiting && (_changingInput || _ddcBusy || _bleBusy || _draining || _queued.Count != 0 || _volumeDrag.HasValue))
        {
            if (Stopwatch.GetElapsedTime(start) >= TimeSpan.FromSeconds(12))
                return new(false, null, L.T("显示器正在处理其他操作，请稍后重试。"));
            await Task.Delay(100);
        }
        if (_exiting) return new(false, null, L.T("托盘正在退出。"));

        BeginInputChange();
        int generation = _sourceGeneration;
        bool Current() => !_exiting && _sourceGeneration == generation;
        async Task<InputSource?> ReadCurrentInput()
        {
            if (!Current()) return null;
            var observed = await _ddc.ReadInputAsync();
            return Current() ? observed : null;
        }
        _ddcBusy = _bleBusy = true;
        _ddcStatus = _bleStatus = L.T("快捷方式正在切换到 {0}…", InputSources.Name(source));
        Render();
        try
        {
            var result = await ShortcutInputSwitcher.SelectAsync(source,
                !string.IsNullOrWhiteSpace(_settings.BluetoothAddress), _ddc.SetInputAsync,
                target => Current() ? _ble.TrySelectInputAsync(target) : Task.FromResult<bool?>(null),
                (target, stillActive) => Current() ? _ble.AlignInputAsync(target, stillActive) : Task.FromResult(false),
                ReadCurrentInput, TrayLog.Write);
            _ddcInput = result.ActiveInput;
            _activeInput.Observe(result.ActiveInput);
            if (result.MenuConfirmed)
            {
                _bleValues[BleControl.Input] = (byte)source;
                _bluetoothInput.Observe(source);
            }
            _ddcStatus = _bleStatus = result.Message;
            return result.ForTarget(source);
        }
        catch (Exception error)
        {
            _ddcInput = null;
            _ddcStatus = _bleStatus = error.Message;
            return new(false, null, error.Message);
        }
        finally
        {
            _bleConnected = _ble.HasConnection;
            _ddcBusy = _bleBusy = _changingInput = false;
            Render();
        }
    }
}
