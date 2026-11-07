using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Models;

namespace OpenDisplay.Windows.Services;

/// <summary>
/// Adapter for VirtualDrivers/Virtual-Display-Driver. It reuses VDD outputs
/// where possible and provisions a new persistent VDD output when a receiver
/// connects and none is available.
/// </summary>
internal sealed class VddVirtualDisplayProvider(
    MonitorLocator monitors,
    VddPipeClient pipe,
    VddSettingsStore? settings = null) : IVirtualDisplayProvider
{
    private readonly VddPipeClient _pipe = pipe;
    private readonly VddSettingsStore _settings = settings ?? new VddSettingsStore();
    private readonly HashSet<string> _claimed = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _gate = new();
    private readonly SemaphoreSlim _provisioningGate = new(1, 1);

    public string Name => "VirtualDrivers/Virtual-Display-Driver";

    public async Task<DisplayTarget> AcquireAsync(
        VirtualDisplayRequest request, CancellationToken cancellationToken)
    {
        if (!await _pipe.IsAvailableAsync(cancellationToken))
            throw new InvalidOperationException(
                "Virtual Display Driver is not running. Install/enable VirtualDrivers/Virtual-Display-Driver before creating a new virtual display.");

        var selected = ClaimActiveOutput();
        if (selected is null)
        {
            await _provisioningGate.WaitAsync(cancellationToken);
            try
            {
                // Another simultaneous receiver may have finished provisioning
                // while this request was waiting.
                selected = ClaimActiveOutput()
                    ?? await ActivateAvailableOutputAsync(request, cancellationToken)
                    ?? await ProvisionOutputAsync(request, createAdditionalOutput: false, cancellationToken);
            }
            finally
            {
                _provisioningGate.Release();
            }
        }

        try
        {
            Log.Info($"Claiming VDD output {selected.DeviceName} at {request.Width}x{request.Height}@{request.RefreshRate}");
            if (!monitors.TrySetMode(selected.DeviceName, request.Width, request.Height,
                    request.RefreshRate, out var error))
            {
                // An existing VDD output may not advertise the newly connected
                // receiver's native mode. Add it and reload only when no other
                // OpenDisplay session owns an output.
                lock (_gate) _claimed.Remove(selected.DeviceName);
                await _provisioningGate.WaitAsync(cancellationToken);
                try
                {
                    selected = await ProvisionOutputAsync(request, createAdditionalOutput: false, cancellationToken);
                }
                finally
                {
                    _provisioningGate.Release();
                }

                if (!monitors.TrySetMode(selected.DeviceName, request.Width, request.Height,
                        request.RefreshRate, out error))
                    throw new InvalidOperationException(
                        $"VDD could not apply the receiver mode {request.Width}x{request.Height}@{request.RefreshRate} " +
                        $"after automatic provisioning: {error}");
            }

            // Display reconfiguration is asynchronous. Wait for the target to
            // report its final bounds before starting capture.
            for (var attempt = 0; attempt < 20; attempt++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var current = monitors.GetAll().FirstOrDefault(x =>
                    x.DeviceName.Equals(selected.DeviceName, StringComparison.OrdinalIgnoreCase));
                if (current?.Target is { } target &&
                    target.Width == request.Width && target.Height == request.Height)
                    return target;
                await Task.Delay(200, cancellationToken);
            }
            throw new TimeoutException("The VDD monitor did not settle on the requested mode.");
        }
        catch
        {
            lock (_gate) _claimed.Remove(selected.DeviceName);
            throw;
        }
    }

    private MonitorLocator.WindowsMonitor? ClaimActiveOutput()
    {
        lock (_gate)
        {
            var selected = monitors.GetAll()
                .Where(x => x.Target.IsVirtual && !_claimed.Contains(x.DeviceName))
                .OrderBy(x => x.DeviceName)
                .FirstOrDefault();
            if (selected is not null) _claimed.Add(selected.DeviceName);
            return selected;
        }
    }

    private async Task<MonitorLocator.WindowsMonitor?> ActivateAvailableOutputAsync(
        VirtualDisplayRequest request, CancellationToken cancellationToken)
    {
        MonitorLocator.WindowsMonitor? inactive;
        lock (_gate)
        {
            inactive = monitors.GetVddOutputs()
                .Where(x => !x.IsActive && !_claimed.Contains(x.DeviceName))
                .OrderBy(x => x.DeviceName)
                .FirstOrDefault();
            if (inactive is not null) _claimed.Add(inactive.DeviceName);
        }
        if (inactive is null) return null;

        var (left, top) = NextDisplayPosition();
        if (!monitors.TrySetMode(inactive.DeviceName, request.Width, request.Height,
                request.RefreshRate, out var error, left, top))
        {
            lock (_gate) _claimed.Remove(inactive.DeviceName);
            Log.Info($"VDD output {inactive.DeviceName} cannot use {request.Width}x{request.Height}@{request.RefreshRate} yet: {error}");
            return null;
        }

        return await WaitForActiveOutputAsync(inactive.DeviceName, cancellationToken);
    }

    private async Task<MonitorLocator.WindowsMonitor> ProvisionOutputAsync(
        VirtualDisplayRequest request, bool createAdditionalOutput, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            // VDD reloads its complete adapter for a configuration change. Do
            // not tear down another receiver's live desktop to add a display.
            if (_claimed.Count != 0)
                throw new InvalidOperationException(
                    "All VDD displays are in use. Connect after a session ends, or keep an unused VDD output available for concurrent receivers.");
        }

        var existingOutputs = monitors.GetVddOutputs().Count;
        var configuration = _settings.EnsureReceiverConfiguration(
            request, Math.Max(1, existingOutputs + (createAdditionalOutput ? 1 : 0)));
        Log.Info($"Provisioning VDD output for {request.Name}: {request.Width}x{request.Height}@{request.RefreshRate}; " +
                 $"configured outputs={configuration.DisplayCount}, modeAdded={configuration.ModeAdded}");

        if (configuration.DisplayCountChanged)
            await _pipe.SetDisplayCountAsync(configuration.DisplayCount, cancellationToken);
        else
            await _pipe.ReloadDriverAsync(cancellationToken);

        // The driver owns monitor arrival. Once Windows has enumerated the
        // new output, enable it as an extended desktop and lease it.
        for (var attempt = 0; attempt < 75; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var active = ClaimActiveOutput();
            if (active is not null) return active;

            var enabled = await ActivateAvailableOutputAsync(request, cancellationToken);
            if (enabled is not null) return enabled;
            await Task.Delay(200, cancellationToken);
        }
        throw new TimeoutException("VDD did not create a Windows display for the connected receiver.");
    }

    private async Task<MonitorLocator.WindowsMonitor> WaitForActiveOutputAsync(
        string deviceName, CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < 25; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var current = monitors.GetAll().FirstOrDefault(x =>
                x.DeviceName.Equals(deviceName, StringComparison.OrdinalIgnoreCase));
            if (current is not null) return current;
            await Task.Delay(200, cancellationToken);
        }
        lock (_gate) _claimed.Remove(deviceName);
        throw new TimeoutException("Windows did not activate the VDD display.");
    }

    private (int Left, int Top) NextDisplayPosition()
    {
        var displays = monitors.GetAll();
        return (displays.Count == 0 ? 0 : displays.Max(x => x.Target.Right) + 16,
            displays.Count == 0 ? 0 : displays.Min(x => x.Target.Top));
    }

    public Task ReleaseAsync(DisplayTarget target)
    {
        // VDD monitors are user-managed and may be shared with other tools.
        // Releasing only returns the output to this app's pool; it never
        // disables or uninstalls the user's driver.
        lock (_gate) _claimed.Remove(target.DeviceName);
        Log.Info($"Released VDD output {target.DeviceName}");
        return Task.CompletedTask;
    }
}
