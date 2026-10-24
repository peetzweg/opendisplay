package app.opendisplay.android.net

import app.opendisplay.android.Log
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketAddress
import java.net.SocketException

/**
 * The optional UDP cursor side channel (PROTOCOL.md 6.3) on TCP port + 1.
 * Only `cursor` messages travel here, one JSON object per datagram. Datagrams
 * are accepted only from the most recently seen flow; the first accepted one
 * of each flow is confirmed with `cursorAck` over TCP.
 */
class CursorChannel(
    private val port: Int,
    /** Returns true when the message was applied. `newFlow` marks a flow's first datagram. */
    private val onDatagram: (obj: JSONObject, newFlow: Boolean) -> Boolean,
    private val onFirstAccepted: () -> Unit,
) {
    @Volatile private var socket: DatagramSocket? = null
    private var currentFlow: SocketAddress? = null
    private val retiredFlows = LinkedHashSet<SocketAddress>()
    private var acked = false

    /** The bound port, or null while nothing listens (then hello omits it). */
    val boundPort: Int? get() = socket?.takeIf { !it.isClosed }?.localPort

    fun start() {
        val s = try {
            DatagramSocket(null).apply {
                reuseAddress = true
                bind(InetSocketAddress(this@CursorChannel.port))
            }
        } catch (e: SocketException) {
            Log.w(TAG, "UDP cursor channel unavailable on $port: $e")
            return
        }
        socket = s
        Thread({ receiveLoop(s) }, "od-cursor-udp").apply { isDaemon = true }.start()
    }

    fun stop() {
        socket?.close()
        socket = null
    }

    /** A new TCP session began: the previous sender's flow must not carry over. */
    @Synchronized
    fun retireFlow() {
        currentFlow?.let { retire(it) }
        currentFlow = null
        acked = false
    }

    private fun retire(flow: SocketAddress) {
        retiredFlows.add(flow)
        if (retiredFlows.size > 16) retiredFlows.remove(retiredFlows.first())
    }

    private fun receiveLoop(s: DatagramSocket) {
        val buf = ByteArray(2048)
        val packet = DatagramPacket(buf, buf.size)
        while (!s.isClosed) {
            try {
                packet.length = buf.size
                s.receive(packet)
            } catch (_: Exception) {
                break
            }
            val obj = try {
                JSONObject(String(packet.data, packet.offset, packet.length, Charsets.UTF_8))
            } catch (_: Exception) {
                continue
            }
            val flow = packet.socketAddress
            // Decide the flow and apply under one lock: retireFlow() for a new
            // session then cannot slip in between and let a stale datagram
            // set the new session's sequence floor.
            val sendAck = synchronized(this) {
                if (flow in retiredFlows) {
                    false
                } else {
                    val isNew = flow != currentFlow
                    if (isNew) {
                        currentFlow?.let { retire(it) }
                        currentFlow = flow
                        acked = false
                    }
                    if (onDatagram(obj, isNew) && !acked) {
                        acked = true
                        true
                    } else false
                }
            }
            if (sendAck) {
                Log.i(TAG, "cursor UDP flow from $flow confirmed")
                onFirstAccepted()
            }
        }
    }

    private companion object {
        const val TAG = "OpenDisplay"
    }
}
