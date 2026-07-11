using System.Net;

namespace OpenDisplay.Windows.Models;

public sealed record ReceiverEndpoint(
    string Id,
    string Name,
    IPAddress Address,
    int Port,
    string? ReceiverId = null)
{
    public string DisplayName => $"{Name} ({Address})";
    public IPEndPoint ToIPEndPoint() => new(Address, Port);
}
