using System.IO;
using System.Text.Json;
using OpenDisplay.Windows.Infrastructure;

namespace OpenDisplay.Windows.Services;

internal sealed class PreferencesStore
{
    private readonly string _path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OpenDisplay", "settings.json");

    public Preferences Load()
    {
        try
        {
            return File.Exists(_path)
                ? JsonSerializer.Deserialize<Preferences>(File.ReadAllBytes(_path)) ?? new Preferences()
                : new Preferences();
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            Log.Error("Could not load preferences", ex);
            return new Preferences();
        }
    }

    public void Save(Preferences preferences)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllBytes(_path, JsonSerializer.SerializeToUtf8Bytes(preferences,
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Error("Could not save preferences", ex);
        }
    }
}

internal sealed record Preferences
{
    public HashSet<string> ManualEndpoints { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public HashSet<string> DisabledAdbDevices { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, string> AdbReceiverIds { get; init; } = new(StringComparer.OrdinalIgnoreCase);
}
