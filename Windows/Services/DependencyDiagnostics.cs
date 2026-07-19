using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using OpenDisplay.Windows.Infrastructure;

namespace OpenDisplay.Windows.Services;

internal sealed class DependencyDiagnostics(
    ReceiverDiscovery discovery,
    FfmpegLocator ffmpeg,
    AdbLocator adb,
    VddPipeClient vddPipe,
    MonitorLocator monitors)
{
    public async Task<string> RunAsync(CancellationToken cancellationToken = default)
    {
        var report = new StringBuilder();
        report.AppendLine($"Log: {Log.FilePath}");
        report.AppendLine($"Runtime: {RuntimeInformation.FrameworkDescription}");
        report.AppendLine($"Windows: {Environment.OSVersion.VersionString} ({RuntimeInformation.OSArchitecture})");
        report.AppendLine($"App: {AppContext.BaseDirectory}");
        report.AppendLine($"[INFO] {discovery.DiagnosticSummary}");

        var ffmpegPath = ffmpeg.Find();
        if (ffmpegPath is null)
        {
            report.AppendLine("[MISSING] FFmpeg: ffmpeg.exe was not found beside the app, in OPENDISPLAY_FFMPEG, or on PATH.");
        }
        else
        {
            report.AppendLine($"[OK] FFmpeg: {ffmpegPath}");
            await AppendFfmpegCheckAsync(report, ffmpegPath, "gdigrab", ["-hide_banner", "-devices"], cancellationToken);
            await AppendFfmpegCheckAsync(report, ffmpegPath, "h264_mf", ["-hide_banner", "-encoders"], cancellationToken);
            await AppendFfmpegCheckAsync(report, ffmpegPath, "hw_encoding", ["-hide_banner", "-h", "encoder=h264_mf"], cancellationToken);
            await AppendFfmpegCheckAsync(report, ffmpegPath, "h264_metadata", ["-hide_banner", "-bsfs"], cancellationToken);
        }

        try
        {
            var all = monitors.GetAll();
            var virtualDisplays = all.Where(monitor => monitor.Target.IsVirtual).ToArray();
            report.AppendLine($"[OK] Active Windows displays: {all.Count}");
            report.AppendLine(virtualDisplays.Length > 0
                ? $"[OK] Active VDD outputs: {virtualDisplays.Length} ({string.Join(", ", virtualDisplays.Select(x => x.DeviceName))})"
                : "[INFO] No active VDD output. You can still select an existing Windows display to share.");
        }
        catch (Exception ex)
        {
            report.AppendLine($"[ERROR] Display enumeration: {ex.Message}");
        }

        try
        {
            var available = await vddPipe.IsAvailableAsync(cancellationToken);
            report.AppendLine(available
                ? "[OK] VDD control pipe: MTTVirtualDisplayPipe"
                : "[INFO] VDD control pipe is unavailable. You can still select an existing Windows display to share.");
        }
        catch (Exception ex)
        {
            report.AppendLine($"[ERROR] VDD probe: {ex.Message}");
        }

        var adbPath = adb.Find();
        report.AppendLine(adbPath is null
            ? "[OPTIONAL] ADB not found; Android USB is unavailable, WiFi/manual can still work."
            : $"[OK] ADB: {adbPath}");

        var text = report.ToString().TrimEnd();
        Log.Info($"Dependency diagnostics:{Environment.NewLine}{text}");
        return text;
    }

    private static async Task AppendFfmpegCheckAsync(
        StringBuilder report,
        string executable,
        string feature,
        string[] arguments,
        CancellationToken cancellationToken)
    {
        try
        {
            var output = await RunProcessAsync(executable, arguments, cancellationToken);
            report.AppendLine(output.Contains(feature, StringComparison.OrdinalIgnoreCase)
                ? $"[OK] FFmpeg feature: {feature}"
                : $"[MISSING] FFmpeg feature: {feature}");
        }
        catch (Exception ex)
        {
            report.AppendLine($"[ERROR] FFmpeg {feature} probe: {ex.Message}");
        }
    }

    private static async Task<string> RunProcessAsync(
        string executable, string[] arguments, CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException($"Could not start {Path.GetFileName(executable)}.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(8));
        try
        {
            var stdout = process.StandardOutput.ReadToEndAsync(timeout.Token);
            var stderr = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            return (await stdout) + Environment.NewLine + (await stderr);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            throw new TimeoutException($"{Path.GetFileName(executable)} did not respond within 8 seconds.");
        }
    }
}
