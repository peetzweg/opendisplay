package app.opendisplay.android.net

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket

/**
 * One sender connection, whatever carries it: a TCP socket (WiFi, or the
 * loopback end of an adb forward) or the USB accessory. The session reads
 * and writes the same PROTOCOL.md bytes over either.
 */
internal interface Link : Closeable {
    val input: InputStream
    val output: OutputStream
    /** What the UI and stats report: "USB" (on the cable) or "WiFi". */
    val transport: String
    /** For the log. */
    val remote: String
}

internal class SocketLink(private val socket: Socket) : Link {
    override val input: InputStream get() = socket.getInputStream()
    override val output: OutputStream get() = socket.getOutputStream()
    override val transport = if (socket.inetAddress.isLoopbackAddress) "USB" else "WiFi"
    override val remote: String get() = socket.remoteSocketAddress.toString()
    override fun close() = socket.close()
}
