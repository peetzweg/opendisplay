using OpenDisplay.Windows.Models;

namespace OpenDisplay.Windows.ViewModels;

/// <summary>
/// A display that can be captured, or the explicit request to provision a
/// receiver-sized VDD display when a session starts.
/// </summary>
internal sealed record DisplaySelection(
    string Id,
    string Name,
    string Description,
    DisplayTarget? Target)
{
    public const string NewVirtualDisplayId = "new-virtual-display";

    public static DisplaySelection CreateNewVirtualDisplay() => new(
        NewVirtualDisplayId,
        "Create a new virtual display",
        "Creates a display sized for the connected receiver. Requires Virtual Display Driver.",
        null);
}
