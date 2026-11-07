namespace OpenDisplay.Windows.Models;

public sealed record DisplayTarget(
    string Id,
    string DeviceName,
    int Left,
    int Top,
    int Width,
    int Height,
    bool IsVirtual)
{
    public int Right => Left + Width;
    public int Bottom => Top + Height;
}
