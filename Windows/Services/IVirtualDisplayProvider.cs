using OpenDisplay.Windows.Models;

namespace OpenDisplay.Windows.Services;

internal interface IVirtualDisplayProvider
{
    string Name { get; }
    Task<DisplayTarget> AcquireAsync(VirtualDisplayRequest request, CancellationToken cancellationToken);
    Task ReleaseAsync(DisplayTarget target);
}
