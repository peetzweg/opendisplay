using System.Buffers.Binary;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Models;

namespace OpenDisplay.Windows.Services;

/// <summary>
/// Dependency-free multicast-DNS browser for _opensidecar._tcp.local.
/// It deliberately implements only the DNS records required by OpenDisplay.
/// </summary>
internal sealed class ReceiverDiscovery : IDisposable
{
    private const string Service = "_opensidecar._tcp.local";
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Dictionary<string, string> _ptrs = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, (string Host, int Port)> _services = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, IPAddress> _addresses = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _receiverIds = new(StringComparer.OrdinalIgnoreCase);
    private readonly SemaphoreSlim _sendGate = new(1, 1);
    private UdpClient? _client;
    private IReadOnlyList<IPAddress> _interfaceAddresses = [];
    private string _lastPublishedSummary = string.Empty;
    private long _packetsReceived;
    private long _packetsWithRecords;

    public event Action<IReadOnlyList<ReceiverEndpoint>>? DevicesChanged;
    public event Action<string>? Error;

    public string DiagnosticSummary =>
        $"mDNS UDP :5353; interfaces=" +
        $"{(_interfaceAddresses.Count > 0 ? string.Join(",", _interfaceAddresses) : "default")}; " +
        $"packets={Interlocked.Read(ref _packetsReceived)}; recordPackets={Interlocked.Read(ref _packetsWithRecords)}";

    public void Start()
    {
        if (_client is not null) return;
        try
        {
            var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            socket.ExclusiveAddressUse = false;
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            socket.Bind(new IPEndPoint(IPAddress.Any, 5353));
            _interfaceAddresses = GetActiveIPv4Addresses();
            var group = IPAddress.Parse("224.0.0.251");
            var joined = 0;
            foreach (var address in _interfaceAddresses)
            {
                try
                {
                    socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.AddMembership,
                        new MulticastOption(group, address));
                    joined++;
                }
                catch (SocketException ex)
                {
                    Log.Warn($"Could not join mDNS multicast on {address}: {ex.Message}");
                }
            }
            if (joined == 0)
            {
                socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.AddMembership,
                    new MulticastOption(group, IPAddress.Any));
                _interfaceAddresses = [];
            }
            _client = new UdpClient { Client = socket };
            Log.Info($"mDNS listener ready: {DiagnosticSummary}");
            _ = ReceiveLoopAsync(_lifetime.Token);
            _ = QueryLoopAsync(_lifetime.Token);
        }
        catch (Exception ex)
        {
            Log.Error("Device discovery unavailable", ex);
            Error?.Invoke($"Device discovery unavailable: {ex.Message}");
        }
    }

    public async Task RefreshAsync()
    {
        if (_client is null) Start();
        if (_client is not null)
            await SendQueryAsync(_lifetime.Token);
    }

    private async Task QueryLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await SendQueryAsync(cancellationToken);
                await Task.Delay(TimeSpan.FromSeconds(10), cancellationToken);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                Log.Error("Device discovery query failed", ex);
                Error?.Invoke($"Device discovery failed: {ex.Message}");
                await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken);
            }
        }
    }

    private async Task SendQueryAsync(CancellationToken cancellationToken)
    {
        var name = EncodeName(Service);
        var query = new byte[12 + name.Length + 4];
        BinaryPrimitives.WriteUInt16BigEndian(query.AsSpan(4), 1); // QDCOUNT
        name.CopyTo(query.AsSpan(12));
        BinaryPrimitives.WriteUInt16BigEndian(query.AsSpan(12 + name.Length), 12); // PTR
        BinaryPrimitives.WriteUInt16BigEndian(query.AsSpan(14 + name.Length), 1);  // IN
        var destination = new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353);
        await _sendGate.WaitAsync(cancellationToken);
        try
        {
            if (_interfaceAddresses.Count == 0)
            {
                await _client!.SendAsync(query, destination, cancellationToken);
                return;
            }
            foreach (var address in _interfaceAddresses)
            {
                try
                {
                    _client!.Client.SetSocketOption(SocketOptionLevel.IP,
                        SocketOptionName.MulticastInterface, address.GetAddressBytes());
                    await _client.SendAsync(query, destination, cancellationToken);
                }
                catch (SocketException ex)
                {
                    Log.Warn($"Could not send mDNS query on {address}: {ex.Message}");
                }
            }
        }
        finally { _sendGate.Release(); }
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var result = await _client!.ReceiveAsync(cancellationToken);
                Interlocked.Increment(ref _packetsReceived);
                ParsePacket(result.Buffer);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                Log.Error("mDNS receive failed", ex);
                Error?.Invoke($"mDNS receive failed: {ex.Message}");
            }
        }
    }

    private void ParsePacket(byte[] packet)
    {
        if (packet.Length < 12) return;
        var questions = ReadU16(packet, 4);
        var recordCount = ReadU16(packet, 6) + ReadU16(packet, 8) + ReadU16(packet, 10);
        if (recordCount > 0) Interlocked.Increment(ref _packetsWithRecords);
        var offset = 12;
        for (var i = 0; i < questions; i++)
        {
            ReadName(packet, ref offset);
            offset += 4;
            if (offset > packet.Length) return;
        }

        for (var i = 0; i < recordCount && offset < packet.Length; i++)
        {
            var owner = ReadName(packet, ref offset);
            if (offset + 10 > packet.Length) return;
            var type = ReadU16(packet, offset);
            var length = ReadU16(packet, offset + 8);
            offset += 10;
            var end = offset + length;
            if (end > packet.Length) return;

            var dataOffset = offset;
            switch (type)
            {
                case 12: // PTR
                    var instance = ReadName(packet, ref dataOffset);
                    if (owner.Equals(Service, StringComparison.OrdinalIgnoreCase)) _ptrs[instance] = owner;
                    break;
                case 33 when length >= 6: // SRV
                    var port = ReadU16(packet, offset + 4);
                    dataOffset = offset + 6;
                    _services[owner] = (ReadName(packet, ref dataOffset), port);
                    break;
                case 1 when length == 4: // A
                    _addresses[owner] = new IPAddress(packet.AsSpan(offset, 4));
                    break;
                case 28 when length == 16: // AAAA
                    _addresses[owner] = new IPAddress(packet.AsSpan(offset, 16));
                    break;
                case 16: // TXT
                    while (dataOffset < end)
                    {
                        var textLength = packet[dataOffset++];
                        if (dataOffset + textLength > end) break;
                        var text = Encoding.UTF8.GetString(packet, dataOffset, textLength);
                        dataOffset += textLength;
                        if (text.StartsWith("id=", StringComparison.Ordinal)) _receiverIds[owner] = text[3..];
                    }
                    break;
            }
            offset = end;
        }
        Publish();
    }

    private void Publish()
    {
        var endpoints = _ptrs.Keys
            .Select(instance => (Instance: instance, Service: _services.GetValueOrDefault(instance)))
            .Where(x => !string.IsNullOrEmpty(x.Service.Host) && _addresses.ContainsKey(x.Service.Host))
            .Select(x => new ReceiverEndpoint(
                _receiverIds.GetValueOrDefault(x.Instance) ?? x.Instance,
                FriendlyName(x.Instance),
                _addresses[x.Service.Host],
                x.Service.Port,
                _receiverIds.GetValueOrDefault(x.Instance)))
            .DistinctBy(x => x.Id)
            .OrderBy(x => x.Name)
            .ToArray();
        var summary = string.Join(", ", endpoints.Select(x => x.DisplayName));
        if (summary != _lastPublishedSummary)
        {
            _lastPublishedSummary = summary;
            Log.Info($"mDNS receivers: {(summary.Length > 0 ? summary : "none")}");
        }
        DevicesChanged?.Invoke(endpoints);
    }

    private static string FriendlyName(string instance)
    {
        var suffix = "." + Service;
        return instance.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)
            ? instance[..^suffix.Length]
            : instance;
    }

    private static ushort ReadU16(byte[] data, int offset) =>
        offset + 2 <= data.Length ? BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(offset, 2)) : (ushort)0;

    private static byte[] EncodeName(string value)
    {
        using var output = new MemoryStream();
        foreach (var label in value.TrimEnd('.').Split('.'))
        {
            var bytes = Encoding.UTF8.GetBytes(label);
            output.WriteByte((byte)bytes.Length);
            output.Write(bytes);
        }
        output.WriteByte(0);
        return output.ToArray();
    }

    private static string ReadName(byte[] packet, ref int offset)
    {
        var labels = new List<string>();
        var cursor = offset;
        var jumped = false;
        var jumps = 0;
        while (cursor < packet.Length && jumps++ < 32)
        {
            var length = packet[cursor++];
            if (length == 0)
            {
                if (!jumped) offset = cursor;
                break;
            }
            if ((length & 0xC0) == 0xC0)
            {
                if (cursor >= packet.Length) break;
                var pointer = ((length & 0x3F) << 8) | packet[cursor++];
                if (!jumped) offset = cursor;
                cursor = pointer;
                jumped = true;
                continue;
            }
            if (cursor + length > packet.Length) break;
            labels.Add(Encoding.UTF8.GetString(packet, cursor, length));
            cursor += length;
            if (!jumped) offset = cursor;
        }
        return string.Join('.', labels);
    }

    private static IReadOnlyList<IPAddress> GetActiveIPv4Addresses()
    {
        var addresses = new List<IPAddress>();
        foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (network.OperationalStatus != OperationalStatus.Up ||
                network.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                continue;
            try
            {
                addresses.AddRange(network.GetIPProperties().UnicastAddresses
                    .Select(item => item.Address)
                    .Where(address => address.AddressFamily == AddressFamily.InterNetwork &&
                                      !IPAddress.IsLoopback(address)));
            }
            catch (NetworkInformationException ex)
            {
                Log.Warn($"Could not inspect network interface {network.Name}: {ex.Message}");
            }
        }
        return addresses.Distinct().ToArray();
    }

    public void Dispose()
    {
        _lifetime.Cancel();
        _client?.Dispose();
        _sendGate.Dispose();
        _lifetime.Dispose();
    }
}
