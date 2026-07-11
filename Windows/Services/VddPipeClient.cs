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
            await using var pipe = new NamedPipeClientStream(".", PipeName,
                PipeDirection.InOut, PipeOptions.Asynchronous);
            await pipe.ConnectAsync(350, cancellationToken);
            var command = Encoding.Unicode.GetBytes("PING\0");
            await pipe.WriteAsync(command, cancellationToken);
            await pipe.FlushAsync(cancellationToken);
            return true;
        }
        catch (IOException) { return false; }
        catch (TimeoutException) { return false; }
    }
}
