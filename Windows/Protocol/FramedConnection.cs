using System.Buffers.Binary;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using OpenDisplay.Windows.Infrastructure;

namespace OpenDisplay.Windows.Protocol;

/// <summary>
/// OpenDisplay wire format: a four-byte big-endian payload length followed by
/// either UTF-8 JSON or one H.264 Annex-B access unit.
/// </summary>
internal sealed class FramedConnection : IAsyncDisposable
{
    private const int MaxControlBytes = 1 << 20;
    private const int MaxFrameBytes = 32 << 20;
    private readonly TcpClient _client;
    private readonly NetworkStream _stream;
    private readonly SemaphoreSlim _writer = new(1, 1);

    private FramedConnection(TcpClient client)
    {
        _client = client;
        _stream = client.GetStream();
    }

    public static async Task<FramedConnection> ConnectAsync(
        string host, int port, CancellationToken cancellationToken)
    {
        IPAddress[] addresses = IPAddress.TryParse(host, out var literal)
            ? [literal]
            : await Dns.GetHostAddressesAsync(host, cancellationToken);
        addresses = addresses
            .Where(address => address.AddressFamily is
                AddressFamily.InterNetwork or AddressFamily.InterNetworkV6)
            .OrderBy(address => address.AddressFamily == AddressFamily.InterNetwork ? 0 : 1)
            .ToArray();
        if (addresses.Length == 0)
            throw new SocketException((int)SocketError.HostNotFound);

        Exception? lastError = null;
        foreach (var address in addresses)
        {
            TcpClient? client = null;
            try
            {
                // Do not use parameterless TcpClient here. It lets the runtime
                // choose a default address family, which can fail with
                // WSAEINVAL on systems where that family is disabled.
                client = new TcpClient(address.AddressFamily) { NoDelay = true };
                Log.Info($"TCP connecting to {address}:{port} using {address.AddressFamily}");
                await client.ConnectAsync(address, port, cancellationToken);
                Log.Info($"TCP connected to {address}:{port}");
                return new FramedConnection(client);
            }
            catch (OperationCanceledException)
            {
                client?.Dispose();
                throw;
            }
            catch (Exception ex) when (ex is SocketException or InvalidOperationException)
            {
                lastError = ex;
                client?.Dispose();
                Log.Warn($"TCP connection to {address}:{port} failed: {ex.Message}");
            }
        }

        throw new IOException($"Could not connect to {host}:{port} using any resolved address.", lastError);
    }

    public async Task<byte[]?> ReadAsync(CancellationToken cancellationToken)
    {
        var header = new byte[4];
        if (!await ReadExactlyOrEofAsync(header, cancellationToken)) return null;
        var length = BinaryPrimitives.ReadUInt32BigEndian(header);
        if (length is 0 or > MaxFrameBytes)
            throw new InvalidDataException($"Invalid OpenDisplay frame length: {length}.");

        var payload = GC.AllocateUninitializedArray<byte>((int)length);
        if (!await ReadExactlyOrEofAsync(payload, cancellationToken))
            throw new EndOfStreamException("Receiver disconnected in the middle of a frame.");
        return payload;
    }

    public Task SendJsonAsync<T>(T message, CancellationToken cancellationToken) =>
        SendAsync(JsonSerializer.SerializeToUtf8Bytes(message), cancellationToken);

    public Task SendJsonAsync(string json, CancellationToken cancellationToken) =>
        SendAsync(Encoding.UTF8.GetBytes(json), cancellationToken);

    public async Task SendAsync(ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
    {
        if (payload.Length is 0 or > MaxFrameBytes)
            throw new ArgumentOutOfRangeException(nameof(payload));
        if (payload.Span[0] == (byte)'{' && payload.Length > MaxControlBytes)
            throw new InvalidDataException("Control message exceeds the 1 MiB limit.");

        var header = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)payload.Length);
        await _writer.WaitAsync(cancellationToken);
        try
        {
            await _stream.WriteAsync(header, cancellationToken);
            await _stream.WriteAsync(payload, cancellationToken);
        }
        finally { _writer.Release(); }
    }

    private async Task<bool> ReadExactlyOrEofAsync(
        Memory<byte> destination, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < destination.Length)
        {
            var count = await _stream.ReadAsync(destination[offset..], cancellationToken);
            if (count == 0)
            {
                if (offset == 0) return false;
                throw new EndOfStreamException("Receiver disconnected in the middle of a frame.");
            }
            offset += count;
        }
        return true;
    }

    public async ValueTask DisposeAsync()
    {
        _client.Close();
        await _stream.DisposeAsync();
        _writer.Dispose();
    }
}
