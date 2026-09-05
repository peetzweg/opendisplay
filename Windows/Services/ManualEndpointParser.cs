using System.Net;
using OpenDisplay.Windows.Models;

namespace OpenDisplay.Windows.Services;

internal static class ManualEndpointParser
{
    public static async Task<ReceiverEndpoint> ParseAsync(
        string input, CancellationToken cancellationToken = default)
    {
        var (host, port) = ParseHostAndPort(input);
        if (!IPAddress.TryParse(host, out var address))
        {
            var addresses = await Dns.GetHostAddressesAsync(host, cancellationToken);
            address = addresses.FirstOrDefault(x =>
                    x.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                ?? addresses.FirstOrDefault()
                ?? throw new FormatException("The host did not resolve to an address.");
        }
        return new ReceiverEndpoint(
            $"manual:{host}:{port}", $"{host}:{port}", address, port,
            Transport: ReceiverTransport.Manual);
    }

    public static (string Host, int Port) ParseHostAndPort(string input)
    {
        var text = input.Trim();
        if (text.Length == 0 || text.Any(char.IsWhiteSpace))
            throw new FormatException("Enter a host, host:port, or [IPv6]:port.");

        var host = text;
        var port = 9000;
        if (text.StartsWith('['))
        {
            var end = text.IndexOf(']');
            if (end < 2) throw new FormatException("Invalid bracketed IPv6 address.");
            host = text[1..end];
            var rest = text[(end + 1)..];
            if (rest.Length > 0)
            {
                if (!rest.StartsWith(':') || !int.TryParse(rest[1..], out port))
                    throw new FormatException("Invalid port.");
            }
        }
        else if (text.Count(character => character == ':') == 1)
        {
            var colon = text.LastIndexOf(':');
            host = text[..colon];
            if (!int.TryParse(text[(colon + 1)..], out port))
                throw new FormatException("Invalid port.");
        }

        if (host.Length == 0 || port is < 1 or > 65535)
            throw new FormatException("Port must be between 1 and 65535.");
        return (host, port);
    }

    public static string Format(string host, int port) =>
        host.Contains(':') ? $"[{host}]:{port}" : $"{host}:{port}";
}
