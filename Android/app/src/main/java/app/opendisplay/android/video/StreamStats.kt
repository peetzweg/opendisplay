package app.opendisplay.android.video

import org.json.JSONObject

/**
 * Rolling receiver telemetry: feeds the perf overlay and the `stats`
 * message the sender logs as PHONE-STATS (PROTOCOL.md 6.1).
 */
class StreamStats {
    private var windowStart = System.nanoTime()
    private var frames = 0
    private var bytes = 0L
    private val endToEnd = ArrayList<Double>()
    private val decode = ArrayList<Double>()

    @Volatile var lastSummary = Summary()
        private set

    data class Summary(
        val fps: Double = 0.0,
        val mbps: Double = 0.0,
        val e2e50: Double? = null,
        val e2e95: Double? = null,
        val dec50: Double? = null,
    )

    @Synchronized
    fun onFrameReceived(size: Int) {
        bytes += size
    }

    @Synchronized
    fun onFrameRendered(decodeMs: Double, endToEndMs: Double?) {
        frames++
        decode.add(decodeMs)
        if (endToEndMs != null && endToEndMs >= 0 && endToEndMs < 10_000) endToEnd.add(endToEndMs)
    }

    /** Closes the current window; call about once a second. */
    @Synchronized
    fun roll(): Summary {
        val now = System.nanoTime()
        val seconds = (now - windowStart) / 1e9
        windowStart = now
        val summary = if (seconds <= 0) Summary() else Summary(
            fps = frames / seconds,
            mbps = bytes * 8 / seconds / 1e6,
            e2e50 = percentile(endToEnd, 0.5),
            e2e95 = percentile(endToEnd, 0.95),
            dec50 = percentile(decode, 0.5),
        )
        frames = 0
        bytes = 0
        endToEnd.clear()
        decode.clear()
        lastSummary = summary
        return summary
    }

    fun toJson(transport: String, rttMs: Double?, offsetKnown: Boolean, codec: String?, dropped: Int) =
        JSONObject().apply {
            val s = lastSummary
            put("transport", transport)
            put("fps", round1(s.fps))
            put("mbps", round1(s.mbps))
            s.e2e50?.let { put("e2e50", round1(it)) }
            s.e2e95?.let { put("e2e95", round1(it)) }
            s.dec50?.let { put("dec50", round1(it)) }
            rttMs?.let { put("rtt", round1(it)) }
            put("offsetKnown", offsetKnown)
            codec?.let { put("decoder", it) }
            put("drops", dropped)
            put("platform", "android")
        }

    private fun round1(v: Double) = Math.round(v * 10) / 10.0

    private fun percentile(values: List<Double>, p: Double): Double? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        return sorted[((sorted.size - 1) * p).toInt()]
    }
}
