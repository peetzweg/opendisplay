using System.IO;

namespace OpenDisplay.Windows.Services;

internal sealed class FfmpegLocator
{
    public string? Find()
    {
        var configured = Environment.GetEnvironmentVariable("OPENDISPLAY_FFMPEG");
        if (IsExecutable(configured)) return configured;

        var besideApp = Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe");
        if (File.Exists(besideApp)) return besideApp;

        var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        return path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(folder => Path.Combine(folder.Trim('"'), "ffmpeg.exe"))
            .FirstOrDefault(File.Exists);
    }

    private static bool IsExecutable(string? path) =>
        !string.IsNullOrWhiteSpace(path) && File.Exists(path);
}
