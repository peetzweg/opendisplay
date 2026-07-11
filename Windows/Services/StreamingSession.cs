using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Models;
using OpenDisplay.Windows.Protocol;

namespace OpenDisplay.Windows.Services;

internal sealed class StreamingSession : IAsyncDisposable
{
    private readonly ReceiverEndpoint _endpoint;
    private readonly CaptureMode _mode;
    private readonly StreamQuality _quality;
    private readonly IVirtualDisplayProvider _virtualDisplays;
    private readonly MonitorLocator _monitors;
    private readonly string _ffmpeg;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly TaskCompletionSource<ReceiverHello> _hello =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private FramedConnection? _connection;
    private FfmpegCaptureEncoder? _capture;
    private WindowsInputInjector? _input;
    private DisplayTarget? _target;
    private long _frames;
    private long _bytesThisWindow;
    private long _lastStatsTimestamp = Stopwatch.GetTimestamp();

    public string Id { get; } = Guid.NewGuid().ToString("N");
    public string TargetId => _endpoint.Id;
    public ReceiverTransport Transport => _endpoint.Transport;
    public string? AdbSerial => _endpoint.AdbSerial;
    public string? InitialReceiverId => _endpoint.ReceiverId;
    public string Name => _endpoint.Name;
    public event Action<string>? StatusChanged;
    public event Action<long, double>? StatsChanged;
    public event Action<ReceiverHello>? HelloReceived;
    public event Action<Exception>? Failed;
    public event Action? Disconnected;

    public StreamingSession(
        ReceiverEndpoint endpoint,
        CaptureMode mode,
        StreamQuality quality,
        IVirtualDisplayProvider virtualDisplays,
        MonitorLocator monitors,
        string ffmpeg)
    {
        _endpoint = endpoint;
        _mode = mode;
        _quality = quality;
        _virtualDisplays = virtualDisplays;
        _monitors = monitors;
        _ffmpeg = ffmpeg;
    }

    public async Task RunAsync()
    {
        try
        {
            Log.Info($"Session {Id} starting: target={_endpoint.Id}, transport={_endpoint.Transport}, " +
                     $"mode={_mode}, quality={_quality}, endpoint={_endpoint.Address}:{_endpoint.Port}");
            StatusChanged?.Invoke($"Connecting to {_endpoint.Address}:{_endpoint.Port}…");
            _connection = await FramedConnection.ConnectAsync(
                _endpoint.Address.ToString(), _endpoint.Port, _lifetime.Token);
            var receiveTask = ReceiveLoopAsync(_lifetime.Token);
            StatusChanged?.Invoke("Connected; waiting for receiver geometry…");
            var hello = await _hello.Task.WaitAsync(TimeSpan.FromSeconds(10), _lifetime.Token);

            _target = _mode == CaptureMode.Extend
                ? await _virtualDisplays.AcquireAsync(new VirtualDisplayRequest(
                    $"OpenDisplay — {hello.Device ?? _endpoint.Name}",
                    Even(hello.PixelsWide), Even(hello.PixelsHigh), 60,
                    StableSerial(hello.Id ?? _endpoint.Id)), _lifetime.Token)
                : _monitors.GetPrimary();
            _input = new WindowsInputInjector(_target);
            StatusChanged?.Invoke($"{(_mode == CaptureMode.Extend ? "Extending" : "Mirroring")} " +
                                  $"{_target.Width}×{_target.Height} via {_target.DeviceName}");

            while (!_lifetime.IsCancellationRequested)
            {
                await using var capture = new FfmpegCaptureEncoder(_ffmpeg);
                _capture = capture;
                try
                {
                    await foreach (var annexB in capture.CaptureAsync(_target, _quality, _lifetime.Token))
                        await SendVideoAsync(annexB, _lifetime.Token);
                }
                catch (InvalidOperationException) when (!_lifetime.IsCancellationRequested && capture.RestartRequested)
                {
                    // A receiver keyframe request restarts FFmpeg, producing a
                    // fresh SPS/PPS/IDR access unit without maintaining a deep
                    // encoder-specific control surface in the UI process.
                    await Task.Delay(100, _lifetime.Token);
                }
            }
            await receiveTask;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Log.Error($"Session {Id} failed", ex);
            StatusChanged?.Invoke($"Stopped: {ex.Message}");
            try { Failed?.Invoke(ex); }
            catch (Exception callbackError) { Log.Error($"Session {Id} failure callback failed", callbackError); }
        }
        finally
        {
            try { await CleanupAsync(); }
            catch (Exception ex) { Log.Error($"Session {Id} cleanup failed", ex); }
            Log.Info($"Session {Id} ended");
            try { Disconnected?.Invoke(); }
            catch (Exception ex) { Log.Error($"Session {Id} disconnect callback failed", ex); }
        }
    }

    public void Stop() => _lifetime.Cancel();

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested && _connection is not null)
        {
            var payload = await _connection.ReadAsync(cancellationToken);
            if (payload is null) throw new EndOfStreamException("Receiver closed the connection.");
            if (payload.Length == 0 || payload[0] != (byte)'{') continue;
            using var document = JsonDocument.Parse(payload);
            var root = document.RootElement;
            if (!root.TryGetProperty("type", out var typeProperty)) continue;
            switch (typeProperty.GetString())
            {
                case "hello":
                    var hello = root.Deserialize<ReceiverHello>();
                    if (hello is not null)
                    {
                        Log.Info($"Session {Id} hello: {hello.Device ?? "device"} " +
                                 $"{hello.PixelsWide}x{hello.PixelsHigh} scale={hello.Scale} id={hello.Id ?? "unknown"}");
                        _hello.TrySetResult(hello);
                        HelloReceived?.Invoke(hello);
                    }
                    break;
                case "touch":
                    _input?.Touch(
                        root.GetProperty("phase").GetString() ?? string.Empty,
                        root.GetProperty("x").GetDouble(),
                        root.GetProperty("y").GetDouble());
                    break;
                case "scroll":
                    _input?.Scroll(root.GetProperty("dx").GetDouble(), root.GetProperty("dy").GetDouble());
                    break;
                case "kf":
                    _capture?.RequestKeyFrame();
                    break;
                case "ping":
                    if (root.TryGetProperty("t", out var timestamp))
                        await _connection.SendJsonAsync(new
                        {
                            type = "pong",
                            t = timestamp.GetDouble(),
                            mt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
                        }, cancellationToken);
                    break;
            }
        }
    }

    private async Task SendVideoAsync(byte[] annexB, CancellationToken cancellationToken)
    {
        if (_connection is null) return;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var telemetry = Encoding.UTF8.GetBytes($"{{\"cap\":{now},\"snd\":{now}}}");
        var payload = GC.AllocateUninitializedArray<byte>(telemetry.Length + annexB.Length);
        telemetry.CopyTo(payload, 0);
        annexB.CopyTo(payload, telemetry.Length);
        await _connection.SendAsync(payload, cancellationToken);
        _frames++;
        _bytesThisWindow += payload.Length + 4;

        var nowTicks = Stopwatch.GetTimestamp();
        var elapsed = Stopwatch.GetElapsedTime(_lastStatsTimestamp, nowTicks).TotalSeconds;
        if (elapsed >= 1)
        {
            StatsChanged?.Invoke(_frames, _bytesThisWindow * 8 / elapsed / 1_000_000);
            _bytesThisWindow = 0;
            _lastStatsTimestamp = nowTicks;
        }
    }

    private async Task CleanupAsync()
    {
        _input?.ReleaseButtons();
        if (_capture is not null) await _capture.DisposeAsync();
        if (_target is { IsVirtual: true } target) await _virtualDisplays.ReleaseAsync(target);
        if (_connection is not null) await _connection.DisposeAsync();
        _capture = null;
        _connection = null;
    }

    private static int Even(int value) => Math.Max(2, value & ~1);

    private static uint StableSerial(string value)
    {
        unchecked
        {
            uint hash = 2166136261;
            foreach (var character in value) hash = (hash ^ character) * 16777619;
            return hash;
        }
    }

    public async ValueTask DisposeAsync()
    {
        Stop();
        await CleanupAsync();
        _lifetime.Dispose();
    }
}
