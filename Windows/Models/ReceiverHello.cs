using System.Text.Json.Serialization;

namespace OpenDisplay.Windows.Models;

public sealed record ReceiverHello
{
    [JsonPropertyName("pixelsWide")]
    public int PixelsWide { get; init; }

    [JsonPropertyName("pixelsHigh")]
    public int PixelsHigh { get; init; }

    [JsonPropertyName("scale")]
    public double Scale { get; init; }

    [JsonPropertyName("device")]
    public string? Device { get; init; }

    [JsonPropertyName("id")]
    public string? Id { get; init; }
}
