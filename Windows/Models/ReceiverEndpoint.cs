using System.Net;

namespace OpenDisplay.Windows.Models;

public sealed record ReceiverEndpoint(
    string Id,
    string Name,
    IPAddress Address,
    int Port,
    string? ReceiverId = null,
    ReceiverTransport Transport = ReceiverTransport.Wifi,
    bool IsReady = true,
    string? Hint = null,
    string? AdbSerial = null)
{
    public string DisplayName => Hint is not null
        ? $"{Name} — {Hint}"
        : $"{Name} ({TransportLabel})";
    public string TransportLabel => Transport switch
    {
        ReceiverTransport.Adb => "ADB",
        ReceiverTransport.Manual => "Manual",
        _ => "WiFi"
    };
    public IPEndPoint ToIPEndPoint() => new(Address, Port);
}

public enum ReceiverTransport
{
    Wifi,
    Adb,
    Manual
}
