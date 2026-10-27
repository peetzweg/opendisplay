package app.opendisplay.android.protocol

/**
 * NTP-style offset to the sender's clock over ping/pong (PROTOCOL.md 8.1):
 * keep the last 15 samples, trust the one with the smallest RTT.
 * `offset = senderClock - receiverClock`.
 */
class ClockSync {
    private val samples = ArrayDeque<Pair<Double, Double>>() // rtt, offset

    @Volatile
    var offsetMs: Double? = null
        private set

    @Volatile
    var lastRttMs: Double? = null
        private set

    /** [t1] our ping's `t`, [mt] the sender's `mt`, [t2] arrival time. */
    @Synchronized
    fun addSample(t1: Double, mt: Double, t2: Double) {
        val rtt = t2 - t1
        if (rtt < 0 || rtt >= 2000) return
        samples.addLast(rtt to (mt - (t1 + t2) / 2))
        if (samples.size > 15) samples.removeFirst()
        offsetMs = samples.minBy { it.first }.second
        lastRttMs = rtt
    }

    @Synchronized
    fun reset() {
        samples.clear()
        offsetMs = null
        lastRttMs = null
    }

    /** Our wall clock expressed in the sender's clock, or null until known. */
    fun senderNow(receiverNowMs: Double): Double? = offsetMs?.let { receiverNowMs + it }
}
