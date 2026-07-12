using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Models;

namespace OpenDisplay.Windows.Services;

/// <summary>
/// Prototype capture/encode backend. FFmpeg gdigrab captures exactly one
/// monitor rectangle and Media Foundation's h264_mf encoder provides hardware
/// H.264 where supported. The output bitstream is Annex B with AUD boundaries.
/// </summary>
internal sealed class FfmpegCaptureEncoder(string executable) : IAsyncDisposable
{
    private Process? _process;
    private readonly ConcurrentQueue<string> _recentErrors = new();
    public bool RestartRequested { get; private set; }

    public async IAsyncEnumerable<byte[]> CaptureAsync(
        DisplayTarget target,
        StreamQuality quality,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var width = Even((int)(target.Width * quality.Scale()));
        var height = Even((int)(target.Height * quality.Scale()));
        var arguments = string.Join(' ',
            "-hide_banner -loglevel warning",
            "-f gdigrab -draw_mouse 1 -framerate 60",
            $"-offset_x {target.Left} -offset_y {target.Top}",
            $"-video_size {target.Width}x{target.Height} -i desktop",
            $"-vf scale={width}:{height}:flags=fast_bilinear",
            // h264_mf otherwise defaults to software encoding. Keep NV12,
            // which is accepted by Media Foundation hardware encoders, and
            // explicitly require the hardware path rather than silently
            // falling back to the CPU encoder.
            $"-c:v h264_mf -hw_encoding 1 -rate_control cbr -scenario display_remoting -b:v {quality.Bitrate()} -maxrate {quality.Bitrate()}",
            "-bf 0 -g 3600 -pix_fmt nv12",
            "-bsf:v h264_metadata=aud=insert -f h264 pipe:1");

        var startInfo = new ProcessStartInfo(executable, arguments)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        Log.Info($"Starting FFmpeg: {executable} {arguments}");
        _process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("FFmpeg could not be started.");
        var stderrTask = DrainErrorsAsync(_process.StandardError, cancellationToken);

        using var registration = cancellationToken.Register(StopProcess);
        var parser = new AnnexBAccessUnitParser();
        var readBuffer = new byte[64 * 1024];
        while (!cancellationToken.IsCancellationRequested)
        {
            var read = await _process.StandardOutput.BaseStream.ReadAsync(readBuffer, cancellationToken);
            if (read == 0) break;
            foreach (var frame in parser.Push(readBuffer.AsSpan(0, read))) yield return frame;
        }
        if (parser.Flush() is { Length: > 0 } tail) yield return tail;

        if (!cancellationToken.IsCancellationRequested)
        {
            await _process.WaitForExitAsync(cancellationToken);
            await stderrTask;
            var detail = string.Join(Environment.NewLine, _recentErrors.TakeLast(8));
            throw new InvalidOperationException(
                $"FFmpeg stopped with exit code {_process.ExitCode}." +
                (detail.Length > 0 ? $"{Environment.NewLine}{detail}" : string.Empty));
        }
    }

    public void RequestKeyFrame()
    {
        RestartRequested = true;
        Log.Info("Receiver requested a keyframe; restarting FFmpeg");
        StopProcess();
    }

    private static int Even(int value) => Math.Max(2, value & ~1);

    private async Task DrainErrorsAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested &&
                   await reader.ReadLineAsync(cancellationToken) is { } line)
            {
                _recentErrors.Enqueue(line);
                while (_recentErrors.Count > 30) _recentErrors.TryDequeue(out _);
                Log.Warn($"FFmpeg: {line}");
            }
        }
        catch (OperationCanceledException) { }
    }

    private void StopProcess()
    {
        try
        {
            if (_process is { HasExited: false })
            {
                Log.Info("Stopping FFmpeg process");
                _process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException) { }
    }

    public ValueTask DisposeAsync()
    {
        StopProcess();
        _process?.Dispose();
        return ValueTask.CompletedTask;
    }

    private sealed class AnnexBAccessUnitParser
    {
        private readonly List<byte> _buffer = [];

        public IReadOnlyList<byte[]> Push(ReadOnlySpan<byte> bytes)
        {
            foreach (var value in bytes) _buffer.Add(value);
            var output = new List<byte[]>();
            while (FindAudOffsets() is { Count: >= 2 } auds)
            {
                var boundary = auds[1];
                output.Add(_buffer.GetRange(0, boundary).ToArray());
                _buffer.RemoveRange(0, boundary);
            }
            return output;
        }

        public byte[]? Flush()
        {
            if (_buffer.Count == 0) return null;
            var value = _buffer.ToArray();
            _buffer.Clear();
            return value;
        }

        private List<int> FindAudOffsets()
        {
            var result = new List<int>(2);
            for (var i = 0; i + 4 < _buffer.Count; i++)
            {
                var startLength = _buffer[i] == 0 && _buffer[i + 1] == 0 && _buffer[i + 2] == 1 ? 3
                    : i + 4 < _buffer.Count && _buffer[i] == 0 && _buffer[i + 1] == 0 &&
                      _buffer[i + 2] == 0 && _buffer[i + 3] == 1 ? 4 : 0;
                if (startLength > 0 && (_buffer[i + startLength] & 0x1f) == 9) result.Add(i);
                if (result.Count == 2) break;
            }
            return result;
        }
    }
}
