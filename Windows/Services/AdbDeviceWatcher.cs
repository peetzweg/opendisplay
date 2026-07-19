using System.IO;
using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Models;

namespace OpenDisplay.Windows.Services;

internal sealed class AdbDeviceWatcher(AdbLocator locator) : IDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Dictionary<string, int> _ownedForwards = new(StringComparer.OrdinalIgnoreCase);
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private Task? _loop;
    private string _lastSummary = string.Empty;

    public event Action<IReadOnlyList<AdbDevice>, bool>? DevicesChanged;

    public void Start() => _loop ??= WatchAsync(_lifetime.Token);

    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        if (!await _refreshGate.WaitAsync(0, cancellationToken)) return;
        try { await RefreshCoreAsync(cancellationToken); }
        finally { _refreshGate.Release(); }
    }

    private async Task WatchAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await RefreshAsync(cancellationToken);
                await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                Log.Error("ADB watcher loop failed; retrying", ex);
                try { await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken); }
                catch (OperationCanceledException) { break; }
            }
        }
    }

    private async Task RefreshCoreAsync(CancellationToken cancellationToken)
    {
        var executable = locator.Find();
        if (executable is null)
        {
            DevicesChanged?.Invoke([], false);
            return;
        }

        try
        {
            var adb = new AdbClient(executable);
            var listed = await adb.ListDevicesAsync(cancellationToken);
            var forwards = await adb.ListForwardsAsync(cancellationToken);
            var devices = new List<AdbDevice>();
            foreach (var item in listed)
            {
                int? port = null;
                if (item.State == "device")
                {
                    if (_ownedForwards.TryGetValue(item.Serial, out var prior) &&
                        forwards.Contains(new AdbClient.Forward(item.Serial, prior, 9000)))
                    {
                        port = prior;
                    }
                    else
                    {
                        try
                        {
                            var reusable = _ownedForwards.GetValueOrDefault(item.Serial);
                            if (reusable > 0 && forwards.Any(forward => forward.LocalPort == reusable))
                                reusable = 0;
                            port = await adb.AddForwardAsync(item.Serial,
                                reusable > 0 ? reusable : null, cancellationToken);
                            _ownedForwards[item.Serial] = port.Value;
                        }
                        catch (AdbException) { }
                    }
                }
                devices.Add(new AdbDevice(item.Serial, item.Name, item.State, port));
            }
            DevicesChanged?.Invoke(devices, true);
            var summary = string.Join(", ", devices.Select(x =>
                $"{x.Serial}:{x.State}:port={x.LocalPort?.ToString() ?? "none"}"));
            if (summary != _lastSummary)
            {
                _lastSummary = summary;
                Log.Info($"ADB devices: {(summary.Length > 0 ? summary : "none")}");
            }
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) when (ex is AdbException or IOException or System.ComponentModel.Win32Exception)
        {
            Log.Error("ADB device refresh failed", ex);
            DevicesChanged?.Invoke([], true);
        }
    }

    private async Task RemoveForwardsAsync()
    {
        var executable = locator.Find();
        if (executable is null) return;
        var adb = new AdbClient(executable);
        foreach (var (serial, port) in _ownedForwards.ToArray())
            await adb.RemoveForwardAsync(serial, port, CancellationToken.None);
        _ownedForwards.Clear();
    }

    public void Dispose()
    {
        _lifetime.Cancel();
        try { _loop?.GetAwaiter().GetResult(); }
        catch (OperationCanceledException) { }
        try { RemoveForwardsAsync().GetAwaiter().GetResult(); }
        catch (Exception) { }
        _refreshGate.Dispose();
        _lifetime.Dispose();
    }
}
