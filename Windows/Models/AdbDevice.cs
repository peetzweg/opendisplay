using System.Net;

namespace OpenDisplay.Windows.Models;

internal sealed record AdbDevice(
    string Serial,
    string Name,
    string State,
    int? LocalPort)
{
    public bool Ready => State == "device" && LocalPort is > 0;

    public string ConnectionHint => State switch
    {
        "device" when LocalPort is null => "ADB · unable to forward port 9000",
        "unauthorized" => "ADB · authorize USB debugging on the device",
        "offline" => "ADB · device offline",
        _ => "ADB"
    };

    public ReceiverEndpoint ToEndpoint() => new(
        $"adb:{Serial}", Name, IPAddress.Loopback, LocalPort ?? 0,
        Transport: ReceiverTransport.Adb,
        IsReady: Ready,
        Hint: Ready ? null : ConnectionHint,
        AdbSerial: Serial);
}
