package app.opendisplay.android.protocol

import org.json.JSONArray
import org.json.JSONObject

/** PROTOCOL.md section 10 / Shared/Protocol.swift `WireProtocol`. */
object WireProtocol {
    const val VERSION = 3
    const val PENCIL_WIRE_VERSION = 3
    const val MIN_SUPPORTED_PEER = 1
    const val ASSUMED_WHEN_ABSENT = 1
    const val TCP_PORT = 9000
    const val SERVICE_TYPE = "_opensidecar._tcp"
}

/** Panel facts in the current orientation (PROTOCOL.md 6.7). */
data class Panel(val pixelsWide: Int, val pixelsHigh: Int, val scale: Double)

/** One `hello.videoCaps` entry (PROTOCOL.md 6.5). */
data class VideoCap(
    val codec: Codec,
    val maxWidth: Int? = null,
    val maxHeight: Int? = null,
    val maxFrameRate: Int? = null,
    val maxPixelsPerSecond: Int? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("codec", codec.wire)
        maxWidth?.let { put("maxWidth", it) }
        maxHeight?.let { put("maxHeight", it) }
        maxFrameRate?.let { put("maxFrameRate", it) }
        maxPixelsPerSecond?.let { put("maxPixelsPerSecond", it) }
    }
}

object Messages {
    fun hello(
        panel: Panel,
        installId: String,
        device: String,
        displayMaxFrameRate: Int,
        videoCaps: List<VideoCap>,
        cursorPort: Int?,
    ): JSONObject = JSONObject().apply {
        put("type", "hello")
        // Deprecated (6.1) but still read by senders that predate `panel`.
        put("pixelsWide", panel.pixelsWide)
        put("pixelsHigh", panel.pixelsHigh)
        put("scale", panel.scale)
        put("panel", JSONObject().apply {
            put("pixelsWide", panel.pixelsWide)
            put("pixelsHigh", panel.pixelsHigh)
            put("scale", panel.scale)
        })
        put("device", device)
        put("id", installId)
        put("pv", WireProtocol.VERSION)
        put("displayMaxFrameRate", displayMaxFrameRate)
        put("videoCaps", JSONArray().apply { videoCaps.forEach { put(it.toJson()) } })
        // The legacy H.264 decode ceiling, for senders that predate videoCaps.
        videoCaps.firstOrNull { it.codec == Codec.H264 }?.let { h264 ->
            if (h264.maxWidth != null && h264.maxHeight != null) {
                put("maxEncodeWide", h264.maxWidth)
                put("maxEncodeHigh", h264.maxHeight)
            }
        }
        // Only while the UDP listener is bound (6.3). No `addrs`: a phone's
        // Wi-Fi address would only invite a false cable upgrade (6.4). No
        // `power`: Android cannot power off without root (6.6).
        cursorPort?.let { put("cursorPort", it) }
    }

    fun ping(t: Double): JSONObject = JSONObject().put("type", "ping").put("t", t)

    fun touch(phase: String, x: Double, y: Double, t: Double?): JSONObject =
        JSONObject().apply {
            put("type", "touch")
            put("phase", phase)
            put("x", x)
            put("y", y)
            t?.let { put("t", it) }
        }

    /** pv 3 stylus (6.1). Barrel roll is not measured: `rotation` is always 0. */
    fun pencil(phase: String, s: PenInput.Sample, t: Double?): JSONObject = JSONObject().apply {
        put("type", "pencil")
        put("phase", phase)
        put("x", s.x)
        put("y", s.y)
        put("pressure", s.pressure)
        put("azimuth", s.azimuth)
        put("altitude", s.altitude)
        put("rotation", 0)
        t?.let { put("t", it) }
    }

    fun proximity(entering: Boolean, x: Double, y: Double): JSONObject =
        JSONObject().put("type", "proximity").put("entering", entering).put("x", x).put("y", y)

    fun scroll(dx: Double, dy: Double): JSONObject =
        JSONObject().put("type", "scroll").put("dx", dx).put("dy", dy)

    fun simple(type: String): JSONObject = JSONObject().put("type", type)

    fun bytes(obj: JSONObject): ByteArray = obj.toString().toByteArray(Charsets.UTF_8)
}

/**
 * The cursor sequence floor shared by the TCP and UDP paths (PROTOCOL.md
 * 6.3): a message whose `s` is not above the highest seen is stale. A TCP
 * cursor without `s` (an older sender) always applies.
 */
class CursorSequence {
    private var highest = 0L

    @Synchronized
    fun accept(seq: Long?): Boolean {
        if (seq == null) return true
        if (seq <= highest) return false
        highest = seq
        return true
    }

    @Synchronized
    fun reset() {
        highest = 0
    }
}
