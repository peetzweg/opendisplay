package app.opendisplay.android.protocol

import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException

/**
 * PROTOCOL.md section 3: every message in both directions is
 * `[4-byte big-endian payload length][payload]`.
 */
object Framing {
    /**
     * Sender-to-receiver frames have no hard maximum in the spec. A 5K
     * keyframe is a few MB; anything this large is a corrupt length, not a
     * picture, and allocating it would take the app down.
     */
    const val MAX_INBOUND_PAYLOAD = 64 shl 20

    /** Receiver-to-sender payloads MUST be 1 to 2^20 - 1 bytes. */
    const val MAX_OUTBOUND_PAYLOAD = (1 shl 20) - 1

    /** Blocks until one whole frame arrives; returns null on a clean EOF. */
    @Throws(IOException::class)
    fun readFrame(input: DataInputStream): ByteArray? {
        val length = try {
            input.readInt()
        } catch (_: EOFException) {
            return null
        }
        if (length < 0 || length > MAX_INBOUND_PAYLOAD) {
            throw IOException("bad frame length $length")
        }
        val payload = try {
            ByteArray(length)
        } catch (_: OutOfMemoryError) {
            // Old low-memory devices: drop the session, not the app.
            throw IOException("no memory for a $length B frame")
        }
        input.readFully(payload)
        return payload
    }

    fun encode(payload: ByteArray): ByteArray {
        require(payload.isNotEmpty() && payload.size <= MAX_OUTBOUND_PAYLOAD) {
            "outbound payload must be 1..${MAX_OUTBOUND_PAYLOAD} bytes, was ${payload.size}"
        }
        val out = ByteArray(4 + payload.size)
        val n = payload.size
        out[0] = (n ushr 24).toByte()
        out[1] = (n ushr 16).toByte()
        out[2] = (n ushr 8).toByte()
        out[3] = n.toByte()
        System.arraycopy(payload, 0, out, 4, n)
        return out
    }
}

/**
 * PROTOCOL.md section 4, the deprecated pv <= 3 heuristic, kept in one place
 * so the typed header planned for pv 4 is a one-function swap.
 */
object Demux {
    private const val MAX_CONTROL = 32768

    fun isControl(payload: ByteArray): Boolean {
        if (payload.isEmpty() || payload.size >= MAX_CONTROL) return false
        if (payload[0] != '{'.code.toByte()) return false
        for (b in payload) if (b.toInt() == 0) return false
        return true
    }
}
