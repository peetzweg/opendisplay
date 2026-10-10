using System.IO;
using System.IO.Pipes;
using System.Text;

namespace OpenDisplay.Windows.Services;

/// <summary>
/// Minimal client for VDD's MTTVirtualDisplayPipe. The upstream server accepts
/// one UTF-16 command per connection and then disconnects.
/// </summary>
internal sealed class VddPipeClient
{
    private const string PipeName = "MTTVirtualDisplayPipe";

    public async Task<bool> IsAvailableAsync(CancellationToken cancellationToken)
    {
        try
        {
            await SendAsync("PING", cancellationToken);
            return true;
        }
        catch (IOException) { return false; }
        catch (TimeoutException) { return false; }
    }

    /// <summary>
    /// VDD processes one UTF-16 command per connection. SETDISPLAYCOUNT also
    /// reloads the adapter, while RELOAD_DRIVER applies changes made directly
    /// to vdd_settings.xml.
    /// </summary>
    public Task SetDisplayCountAsync(int count, CancellationToken cancellationToken) =>
        SendAsync($"SETDISPLAYCOUNT {count}", cancellationToken);

    public Task ReloadDriverAsync(CancellationToken cancellationToken) =>
        SendAsync("RELOAD_DRIVER", cancellationToken);

    private static async Task SendAsync(string command, CancellationToken cancellationToken)
    {
        await using var pipe = new NamedPipeClientStream(".", PipeName,
            PipeDirection.InOut, PipeOptions.Asynchronous);
        await pipe.ConnectAsync(350, cancellationToken);
        var payload = Encoding.Unicode.GetBytes($"{command}\0");
        await pipe.WriteAsync(payload, cancellationToken);
        await pipe.FlushAsync(cancellationToken);
    }
}
