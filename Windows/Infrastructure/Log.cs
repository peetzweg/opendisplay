using System.IO;
using System.Text;

namespace OpenDisplay.Windows.Infrastructure;

internal static class Log
{
    private const long MaxBytes = 5 * 1024 * 1024;
    private static readonly object Gate = new();
    private static StreamWriter? _writer;

    public static string FilePath { get; private set; } = string.Empty;

    public static void Initialize()
    {
        lock (Gate)
        {
            if (_writer is not null) return;
            var besideApp = Path.Combine(AppContext.BaseDirectory, "OpenDisplay.log");
            var localAppData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OpenDisplay", "OpenDisplay.log");

            foreach (var path in new[] { besideApp, localAppData })
            {
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                    RotateIfNeeded(path);
                    var stream = new FileStream(path, FileMode.Append, FileAccess.Write,
                        FileShare.ReadWrite | FileShare.Delete);
                    _writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true };
                    FilePath = path;
                    Write("INFO", "Log started");
                    return;
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            }
        }
    }

    public static void Info(string message) => Write("INFO", message);
    public static void Warn(string message) => Write("WARN", message);
    public static void Error(string message, Exception? exception = null) =>
        Write("ERROR", exception is null ? message : $"{message}{Environment.NewLine}{exception}");

    private static void Write(string level, string message)
    {
        lock (Gate)
        {
            if (_writer is null && FilePath.Length == 0) Initialize();
            var normalized = message.Replace("\r\n", "\n").Replace('\r', '\n')
                .Replace("\n", Environment.NewLine + "    ");
            _writer?.WriteLine($"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff zzz} [{level}] [T{Environment.CurrentManagedThreadId}] {normalized}");
        }
    }

    private static void RotateIfNeeded(string path)
    {
        if (!File.Exists(path) || new FileInfo(path).Length < MaxBytes) return;
        var previous = path + ".1";
        if (File.Exists(previous)) File.Delete(previous);
        File.Move(path, previous);
    }

    public static void Close()
    {
        lock (Gate)
        {
            Write("INFO", "Log stopped");
            _writer?.Dispose();
            _writer = null;
        }
    }
}
