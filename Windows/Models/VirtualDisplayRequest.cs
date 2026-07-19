namespace OpenDisplay.Windows.Models;

public sealed record VirtualDisplayRequest(
    string Name,
    int Width,
    int Height,
    int RefreshRate,
    uint SerialNumber);
