using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Models;

namespace OpenDisplay.Windows.Services;

/// <summary>
/// Adapter for VirtualDrivers/Virtual-Display-Driver. VDD owns monitor creation;
/// OpenDisplay claims an active VDD output and switches it to the receiver mode.
/// </summary>
internal sealed class VddVirtualDisplayProvider(MonitorLocator monitors) : IVirtualDisplayProvider
{
    private readonly VddPipeClient _pipe = new();
    private readonly HashSet<string> _claimed = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _gate = new();

    public string Name => "VirtualDrivers/Virtual-Display-Driver";

    public async Task<DisplayTarget> AcquireAsync(
        VirtualDisplayRequest request, CancellationToken cancellationToken)
    {
        if (!await _pipe.IsAvailableAsync(cancellationToken))
            throw new InvalidOperationException(
                "Virtual Display Driver is not running. Install/enable VirtualDrivers/Virtual-Display-Driver before using Extend mode.");

        MonitorLocator.WindowsMonitor? selected;
        lock (_gate)
        {
            selected = monitors.GetAll()
                .Where(x => x.Target.IsVirtual && !_claimed.Contains(x.DeviceName))
                .OrderBy(x => x.DeviceName)
                .FirstOrDefault();
            if (selected is not null) _claimed.Add(selected.DeviceName);
        }

        if (selected is null)
            throw new InvalidOperationException(
                "No unclaimed Virtual Display Driver monitor is active. Install VDD, configure at least one monitor, and choose 'Extend these displays' in Windows Settings.");

        try
        {
            Log.Info($"Claiming VDD output {selected.DeviceName} at {request.Width}x{request.Height}@{request.RefreshRate}");
            if (selected.Target.Width != request.Width || selected.Target.Height != request.Height)
            {
                if (!monitors.TrySetMode(selected.DeviceName, request.Width, request.Height,
                        request.RefreshRate, out var error))
                {
                    throw new InvalidOperationException(
                        $"VDD does not expose {request.Width}×{request.Height}@{request.RefreshRate}. " +
                        "Add that mode to C:\\VirtualDisplayDriver\\vdd_settings.xml, restart the VDD device, and try again. " + error);
                }
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
