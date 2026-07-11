using System.Text.Json;

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
        catch (IOException) { return new Preferences(); }
        catch (JsonException) { return new Preferences(); }
    }

    public void Save(Preferences preferences)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllBytes(_path, JsonSerializer.SerializeToUtf8Bytes(preferences,
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

internal sealed record Preferences
{
    public HashSet<string> ManualEndpoints { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public HashSet<string> DisabledAdbDevices { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, string> AdbReceiverIds { get; init; } = new(StringComparer.OrdinalIgnoreCase);
}
