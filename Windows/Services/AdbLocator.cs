namespace OpenDisplay.Windows.Services;

internal sealed class AdbLocator
{
    public string? Find()
    {
        var candidates = new List<string>
        {
            Path.Combine(AppContext.BaseDirectory, "adb.exe")
        };
        foreach (var key in new[] { "ANDROID_SDK_ROOT", "ANDROID_HOME" })
        {
            var root = Environment.GetEnvironmentVariable(key);
            if (!string.IsNullOrWhiteSpace(root))
                candidates.Add(Path.Combine(root, "platform-tools", "adb.exe"));
        }

        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (localAppData.Length > 0)
            candidates.Add(Path.Combine(localAppData, "Android", "Sdk", "platform-tools", "adb.exe"));

        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
                     .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            candidates.Add(Path.Combine(directory.Trim('"'), "adb.exe"));

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var candidate in candidates)
        {
            try
            {
                var path = Path.GetFullPath(candidate);
                if (seen.Add(path) && File.Exists(path)) return path;
            }
            catch (Exception ex) when (ex is ArgumentException or NotSupportedException) { }
        }
        return null;
    }
}
