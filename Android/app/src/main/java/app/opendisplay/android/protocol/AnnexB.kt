package app.opendisplay.android.protocol

import org.json.JSONObject

enum class Codec(val wire: String, val mime: String) {
    H264("h264", "video/avc"),
    HEVC("hevc", "video/hevc");

    companion object {
        fun fromWire(token: String?): Codec? =
            entries.firstOrNull { it.wire == token?.lowercase() }
    }
}

/**
 * One wire video frame (PROTOCOL.md 5.1) split into its parts. [nalus] are
 * the NAL units without start codes.
 */
class AccessUnit(
    val captureMs: Double?,
    val sendMs: Double?,
    val nalus: List<ByteArray>,
)

object AnnexB {
    /**
     * Splits on the 4-byte start code only (5.1: senders MUST NOT emit
     * 3-byte codes). Everything before the first start code is the telemetry
     * prefix. Returns null if the frame carries no start code at all.
     */
    fun parse(frame: ByteArray): AccessUnit? {
        val first = indexOfStartCode(frame, 0)
        if (first < 0) return null
        var captureMs: Double? = null
        var sendMs: Double? = null
        if (first > 0 && frame[0] == '{'.code.toByte()) {
            try {
                val obj = JSONObject(String(frame, 0, first, Charsets.UTF_8))
                if (obj.has("cap")) captureMs = obj.optDouble("cap")
                if (obj.has("snd")) sendMs = obj.optDouble("snd")
            } catch (_: Exception) {
                // Telemetry is measurement plumbing only; a bad prefix costs nothing.
            }
        }
        val nalus = ArrayList<ByteArray>(4)
        var start = first + 4
        while (start <= frame.size) {
            val next = indexOfStartCode(frame, start)
            val end = if (next < 0) frame.size else next
            if (end > start) nalus.add(frame.copyOfRange(start, end))
            if (next < 0) break
            start = next + 4
        }
        return AccessUnit(captureMs, sendMs, nalus)
    }

    fun indexOfStartCode(data: ByteArray, from: Int): Int {
        var i = from
        val last = data.size - 4
        while (i <= last) {
            // Skip ahead fast: a start code needs data[i + 2] == 0.
            if (data[i + 2].toInt() != 0) {
                i += 3
                continue
            }
            if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 &&
                data[i + 2].toInt() == 0 && data[i + 3].toInt() == 1
            ) return i
            i++
        }
        return -1
    }

    fun nalType(codec: Codec, nalu: ByteArray): Int {
        if (nalu.isEmpty()) return -1
        val b = nalu[0].toInt() and 0xFF
        return when (codec) {
            Codec.H264 -> b and 0x1F
            Codec.HEVC -> (b ushr 1) and 0x3F
        }
    }

    fun isParameterSet(codec: Codec, type: Int): Boolean = when (codec) {
        Codec.H264 -> type == 7 || type == 8
        Codec.HEVC -> type in 32..34
    }

    /** IDR for H.264; any IRAP picture (BLA/IDR/CRA, 16..21) for HEVC. */
    fun isKeyframeSlice(codec: Codec, type: Int): Boolean = when (codec) {
        Codec.H264 -> type == 5
        Codec.HEVC -> type in 16..21
    }

    /** Access unit delimiters and SEI carry nothing a decoder needs here. */
    fun isSkippable(codec: Codec, type: Int): Boolean = when (codec) {
        Codec.H264 -> type == 6 || type == 9
        Codec.HEVC -> type == 35 || type == 39 || type == 40
    }

    /** Joins NALUs back into an Annex B buffer with 4-byte start codes. */
    fun join(nalus: List<ByteArray>): ByteArray {
        var size = 0
        for (n in nalus) size += 4 + n.size
        val out = ByteArray(size)
        var p = 0
        for (n in nalus) {
            out[p + 3] = 1
            p += 4
            System.arraycopy(n, 0, out, p, n.size)
            p += n.size
        }
        return out
    }
}
