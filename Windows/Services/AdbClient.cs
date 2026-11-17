using System.Diagnostics;
using OpenDisplay.Windows.Infrastructure;

namespace OpenDisplay.Windows.Services;

internal sealed class AdbClient(string executable)
{
    internal sealed record ListedDevice(string Serial, string State, string Name);
    internal sealed record Forward(string Serial, int LocalPort, int RemotePort);

    public async Task<IReadOnlyList<ListedDevice>> ListDevicesAsync(CancellationToken cancellationToken) =>
        ParseDevices(await RunAsync(["devices", "-l"], cancellationToken));

    public async Task<IReadOnlyList<Forward>> ListForwardsAsync(CancellationToken cancellationToken) =>
        ParseForwards(await RunAsync(["forward", "--list"], cancellationToken));

    public async Task<int> AddForwardAsync(
        string serial, int? preferredPort, CancellationToken cancellationToken)
    {
        if (preferredPort is > 0)
        {
            try
            {
                await RunAsync(["-s", serial, "forward", $"tcp:{preferredPort}", "tcp:9000"],
                    cancellationToken);
                return preferredPort.Value;
            }
            catch (AdbException) { }
        }

        var output = (await RunAsync(
            ["-s", serial, "forward", "tcp:0", "tcp:9000"], cancellationToken)).Trim();
        if (!int.TryParse(output, out var port) || port is < 1 or > 65535)
            throw new AdbException($"adb returned an invalid forwarded port: {output}");
        return port;
    }

    public async Task RemoveForwardAsync(
        string serial, int localPort, CancellationToken cancellationToken)
    {
        try
        {
            await RunAsync(["-s", serial, "forward", "--remove", $"tcp:{localPort}"],
                cancellationToken);
        }
        catch (AdbException) { }
    }

    internal static IReadOnlyList<ListedDevice> ParseDevices(string output)
    {
        var result = new List<ListedDevice>();
        foreach (var line in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var fields = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2 || fields[0] is "List" or "*") continue;
            var attributes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var field in fields.Skip(2))
            {
                var parts = field.Split(':', 2);
                if (parts.Length == 2) attributes[parts[0]] = parts[1];
            }
            var name = attributes.GetValueOrDefault("model")
                ?? attributes.GetValueOrDefault("device") ?? fields[0];
            result.Add(new ListedDevice(fields[0], fields[1], name.Replace('_', ' ')));
        }
        return result;
    }

    internal static IReadOnlyList<Forward> ParseForwards(string output)
    {
        var result = new List<Forward>();
        foreach (var line in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var fields = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length == 3 && TcpPort(fields[1]) is { } local && TcpPort(fields[2]) is { } remote)
                result.Add(new Forward(fields[0], local, remote));
        }
        return result;
    }

    private async Task<string> RunAsync(string[] arguments, CancellationToken cancellationToken)
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
            ?? throw new AdbException("Unable to start adb.exe.");
        try
        {
            var stdout = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var stderr = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var output = await stdout;
            var error = await stderr;
            if (process.ExitCode != 0)
            {
                Log.Warn($"adb {string.Join(' ', arguments)} failed ({process.ExitCode}): {error.Trim()}");
                throw new AdbException(error.Trim().Length > 0 ? error.Trim() : "adb command failed.");
            }
            return output;
        }
        catch (OperationCanceledException)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            throw;
        }
    }

    private static int? TcpPort(string endpoint) =>
        endpoint.StartsWith("tcp:", StringComparison.Ordinal) &&
        int.TryParse(endpoint[4..], out var port) && port is > 0 and <= 65535 ? port : null;
}

internal sealed class AdbException(string message) : Exception(message);
