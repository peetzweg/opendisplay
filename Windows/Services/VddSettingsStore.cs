using System.IO;
using System.Xml.Linq;
using OpenDisplay.Windows.Models;

namespace OpenDisplay.Windows.Services;

/// <summary>
/// Makes the small, OpenDisplay-owned additions needed for a receiver usable
/// by VDD. Existing user settings and modes are deliberately retained.
/// </summary>
internal sealed class VddSettingsStore
{
    internal const string DefaultPath = @"C:\VirtualDisplayDriver\vdd_settings.xml";

    private readonly string _path;

    public VddSettingsStore(string? path = null) => _path = path ?? DefaultPath;

    public VddConfiguration EnsureReceiverConfiguration(VirtualDisplayRequest request, int minimumDisplayCount)
    {
        if (minimumDisplayCount < 1) throw new ArgumentOutOfRangeException(nameof(minimumDisplayCount));
        if (!File.Exists(_path))
            throw new FileNotFoundException("VDD settings file was not found.", _path);

        var document = XDocument.Load(_path, LoadOptions.PreserveWhitespace);
        var root = document.Root;
        if (root?.Name != "vdd_settings")
            throw new InvalidDataException($"{_path} is not a VDD settings file.");

        var monitors = root.Element("monitors");
        if (monitors is null)
        {
            monitors = new XElement("monitors");
            root.AddFirst(monitors);
        }

        var count = monitors.Element("count");
        var configuredCount = int.TryParse(count?.Value, out var parsedCount) && parsedCount > 0
            ? parsedCount
            : 0;
        var displayCount = Math.Max(configuredCount, minimumDisplayCount);
        var countChanged = displayCount != configuredCount;
        if (count is null)
        {
            monitors.Add(new XElement("count", displayCount));
            countChanged = true;
        }
        else if (countChanged)
        {
            count.Value = displayCount.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        var resolutions = root.Element("resolutions");
        if (resolutions is null)
        {
            resolutions = new XElement("resolutions");
            root.Add(resolutions);
        }

        var modeExists = resolutions.Elements("resolution").Any(mode =>
            ValueEquals(mode, "width", request.Width) &&
            ValueEquals(mode, "height", request.Height) &&
            ValueEquals(mode, "refresh_rate", request.RefreshRate));
        if (!modeExists)
        {
            resolutions.Add(new XElement("resolution",
                new XElement("width", request.Width),
                new XElement("height", request.Height),
                new XElement("refresh_rate", request.RefreshRate)));
        }

        var modeAdded = !modeExists;
        if (countChanged || modeAdded) SaveAtomically(document);
        return new VddConfiguration(displayCount, countChanged, modeAdded);
    }

    private static bool ValueEquals(XElement parent, string name, int expected) =>
        int.TryParse(parent.Element(name)?.Value, out var value) && value == expected;

    private void SaveAtomically(XDocument document)
    {
        var directory = Path.GetDirectoryName(_path)
            ?? throw new InvalidOperationException("VDD settings file has no directory.");
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(_path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            document.Save(temporaryPath);
            File.Move(temporaryPath, _path, true);
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }
}

internal readonly record struct VddConfiguration(
    int DisplayCount,
    bool DisplayCountChanged,
    bool ModeAdded);
