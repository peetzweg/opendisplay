namespace OpenDisplay.Windows.Models;

public enum StreamQuality
{
    Best,
    Balanced,
    Fast
}

internal static class StreamQualityExtensions
{
    public static double Scale(this StreamQuality quality) => quality switch
    {
        StreamQuality.Best => 1.0,
        StreamQuality.Balanced => 0.75,
        _ => 0.5
    };

    public static int Bitrate(this StreamQuality quality) => quality switch
    {
        StreamQuality.Best => 18_000_000,
        StreamQuality.Balanced => 10_000_000,
        _ => 6_000_000
    };
}
