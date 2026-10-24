package app.opendisplay.android.protocol

import kotlin.math.hypot

/**
 * Turns raw finger events into `touch` and `scroll` messages, matching the
 * iOS receiver (iOS/OpenSidecarPhoneApp.swift VideoView):
 *
 * - A press is only a click once we know a second finger is not coming. The
 *   `began` is withheld until the finger moves past the drag slop or is held
 *   for [holdDelayMs]; a quick tap posts the whole click on lift. Sending
 *   `began` on contact meant every two-finger scroll first clicked whatever
 *   sat under the first finger.
 * - Two fingers scroll: the cursor is put on the gesture once, up front, then
 *   centroid deltas go out in video pixels with natural-scrolling sign.
 *
 * Pure logic: the view feeds positions, a [Scheduler] runs the hold timer.
 */
class TouchGestures(
    private val output: Output,
    private val scheduler: Scheduler,
    private val dragSlopPx: Float,
    private val holdDelayMs: Long = 120,
) {
    interface Output {
        fun touch(phase: String, x: Double, y: Double)
        fun scroll(dx: Double, dy: Double)
    }

    fun interface Cancellable {
        fun cancel()
    }

    fun interface Scheduler {
        fun schedule(delayMs: Long, action: () -> Unit): Cancellable
    }

    /** One sample: screen pixels for distances, normalized video for the wire. */
    class Point(val px: Float, val py: Float, val nx: Double, val ny: Double)

    private var pendingDown: Point? = null
    private var downSent = false
    private var holdTimer: Cancellable? = null
    private var lastNorm: Point? = null

    private var twoFinger = false
    private var lastCentroid: Point? = null

    fun down(p: Point) {
        twoFinger = false
        lastCentroid = null
        discardPendingDown()
        pendingDown = p
        lastNorm = p
        holdTimer = scheduler.schedule(holdDelayMs) { commitPendingDown() }
    }

    /** A further finger landed; [centroid] of all fingers down now. */
    fun pointerDown(pointerCount: Int, centroid: Point) {
        if (downSent) lastNorm?.let { output.touch("cancelled", it.nx, it.ny) }
        discardPendingDown()
        if (pointerCount == 2 && !twoFinger) {
            twoFinger = true
            // macOS scrolls whatever sits under the cursor; put it on the
            // gesture once so the scroll lands on the window being touched.
            output.touch("moved", centroid.nx, centroid.ny)
        }
        lastCentroid = centroid
    }

    /** A finger lifted while others stay down: re-seed so the centroid doesn't jump. */
    fun pointerUp() {
        lastCentroid = null
    }

    /**
     * [primary] is the first finger, [centroid] all fingers, [videoScale]
     * screen pixels per video pixel.
     */
    fun move(pointerCount: Int, primary: Point, centroid: Point, videoScale: Float) {
        if (twoFinger) {
            if (pointerCount < 2) return
            val last = lastCentroid
            lastCentroid = centroid
            if (last == null || videoScale <= 0f) return
            val dx = (centroid.px - last.px) / videoScale
            val dy = (centroid.py - last.py) / videoScale
            if (dx != 0f || dy != 0f) output.scroll(dx.toDouble(), dy.toDouble())
            return
        }
        lastNorm = primary
        val pending = pendingDown
        if (pending != null && !downSent) {
            if (hypot(primary.px - pending.px, primary.py - pending.py) < dragSlopPx) {
                // Still deciding: track the cursor (a move without a down is
                // a mouseMoved on the Mac) but keep the button up, so a
                // second finger can still turn this into a scroll.
                output.touch("moved", primary.nx, primary.ny)
                return
            }
            commitPendingDown()
        }
        if (downSent) output.touch("moved", primary.nx, primary.ny)
    }

    fun up(p: Point) {
        if (twoFinger) {
            twoFinger = false
            lastCentroid = null
            discardPendingDown()
            return
        }
        // A tap: nothing was posted yet, so post the whole click now.
        if (pendingDown != null && !downSent) commitPendingDown()
        if (downSent) output.touch("ended", p.nx, p.ny)
        discardPendingDown()
    }

    fun cancel() {
        if (downSent) lastNorm?.let { output.touch("cancelled", it.nx, it.ny) }
        discardPendingDown()
        twoFinger = false
        lastCentroid = null
    }

    /** Emit the withheld `began` where the finger first landed. */
    private fun commitPendingDown() {
        val p = pendingDown ?: return
        if (downSent) return
        downSent = true
        holdTimer?.cancel()
        holdTimer = null
        output.touch("began", p.nx, p.ny)
    }

    private fun discardPendingDown() {
        pendingDown = null
        downSent = false
        holdTimer?.cancel()
        holdTimer = null
    }
}
