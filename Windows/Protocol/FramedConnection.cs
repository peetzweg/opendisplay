using System.Buffers.Binary;
using System.Diagnostics;
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
    private readonly Stream _reader;
    private readonly Stream _writerStream;
    private readonly Process? _adbProcess;
    private readonly Task<string>? _adbStderr;
    private readonly SemaphoreSlim _writer = new(1, 1);

    private FramedConnection(Socket socket)
    {
        var stream = new NetworkStream(socket, ownsSocket: true);
        _reader = stream;
        _writerStream = stream;
    }

    private FramedConnection(Process adbProcess, Task<string> adbStderr)
    {
        _adbProcess = adbProcess;
        _adbStderr = adbStderr;
        _reader = adbProcess.StandardOutput.BaseStream;
        _writerStream = adbProcess.StandardInput.BaseStream;
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
            Socket? socket = null;
            try
            {
                socket = CreateStreamSocket(address.AddressFamily);
                Log.Info($"TCP connecting to {address}:{port} using {address.AddressFamily}");
                await socket.ConnectAsync(new IPEndPoint(address, port), cancellationToken);
                try { socket.NoDelay = true; }
                catch (SocketException ex)
                {
                    // TCP_NODELAY improves input latency but is not required
                    // for a valid stream on unusual Winsock providers.
                    Log.Warn($"Could not enable TCP_NODELAY for {address}:{port}: {ex.Message}");
                }
                Log.Info($"TCP connected to {address}:{port}");
                return new FramedConnection(socket);
            }
            catch (OperationCanceledException)
            {
                socket?.Dispose();
                throw;
            }
            catch (Exception ex) when (ex is SocketException or InvalidOperationException)
            {
                lastError = ex;
                socket?.Dispose();
                Log.Warn($"TCP connection to {address}:{port} failed: {ex.Message}");
            }
        }

        throw new IOException($"Could not connect to {host}:{port} using any resolved address.", lastError);
    }

    public static async Task<FramedConnection> ConnectAdbAsync(
        string adbExecutable, string serial, CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo(adbExecutable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in new[]
                 {
                     "-s", serial, "shell", "-T",
                     "toybox", "nc", "-w", "10", "127.0.0.1", "9000"
                 })
            startInfo.ArgumentList.Add(argument);

        var process = Process.Start(startInfo)
            ?? throw new IOException("Could not start adb.exe for the USB stream.");
        var stderr = process.StandardError.ReadToEndAsync();
        Log.Info($"ADB direct stream starting for {serial} using binary toybox nc");

        try
        {
            var exited = process.WaitForExitAsync(cancellationToken);
            if (await Task.WhenAny(exited, Task.Delay(300, cancellationToken)) == exited)
            {
                await exited;
                var error = (await stderr).Trim();
                process.Dispose();
                throw new IOException(error.Length > 0
                    ? $"ADB could not open the receiver stream: {error}"
                    : "ADB could not open the receiver stream. Keep the Android receiver app open.");
            }
            cancellationToken.ThrowIfCancellationRequested();
            return new FramedConnection(process, stderr);
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            process.Dispose();
            throw;
        }
    }

    private static Socket CreateStreamSocket(AddressFamily addressFamily)
    {
        try
        {
            return new Socket(addressFamily, SocketType.Stream, ProtocolType.Tcp);
        }
        catch (SocketException ex) when (ex.SocketErrorCode == SocketError.InvalidArgument)
        {
            // Some Windows Winsock catalogs reject an explicitly selected TCP
            // provider with WSAEINVAL even for IPv4 loopback. Protocol 0 asks
            // Winsock to select the stream provider and avoids TcpClient's
            // failing InitializeClientSocket path.
            Log.Warn($"Winsock rejected the explicit TCP provider for {addressFamily}; " +
                     "retrying with automatic stream-provider selection");
            return new Socket(addressFamily, SocketType.Stream, ProtocolType.Unspecified);
        }
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
            await _writerStream.WriteAsync(header, cancellationToken);
            await _writerStream.WriteAsync(payload, cancellationToken);
        }
        finally { _writer.Release(); }
    }

    private async Task<bool> ReadExactlyOrEofAsync(
        Memory<byte> destination, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < destination.Length)
        {
            var count = await _reader.ReadAsync(destination[offset..], cancellationToken);
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
        await _writerStream.DisposeAsync();
        if (!ReferenceEquals(_reader, _writerStream)) await _reader.DisposeAsync();
        if (_adbProcess is not null)
        {
            try { if (!_adbProcess.HasExited) _adbProcess.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            if (_adbStderr is not null)
            {
                try
                {
                    var error = (await _adbStderr).Trim();
                    if (error.Length > 0) Log.Warn($"ADB direct stream: {error}");
                }
                catch (InvalidOperationException) { }
            }
            _adbProcess.Dispose();
        }
        _writer.Dispose();
    }
}
