package app.opendisplay.android.protocol

import kotlin.math.PI

/**
 * Stylus input (PROTOCOL.md 6.1 `pencil` / `proximity`), matching the iOS
 * receiver's InputCaptureEngine: `down`, every `move` sample, `up`; `hover`
 * while in range; `proximity` around it all. Senders below pv 3 get the
 * stylus as plain `touch` (normative fallback), so the pen never goes dead.
 */
class PenInput(
    private val output: Output,
    private val scheduler: TouchGestures.Scheduler,
    /** The sender's `welcome.pv`, read per event. */
    private val senderPv: () -> Int,
) {
    interface Output {
        fun pencil(phase: String, s: Sample)
        fun proximity(entering: Boolean, x: Double, y: Double)
        fun touch(phase: String, x: Double, y: Double)
    }

    /** One stylus sample in wire units (normalized position, radians). */
    data class Sample(
        val x: Double,
        val y: Double,
        val pressure: Double,
        val azimuth: Double,
        val altitude: Double,
    ) {
        companion object {
            /** From Android's AXIS_PRESSURE, AXIS_ORIENTATION and AXIS_TILT. */
            fun fromAxes(x: Double, y: Double, pressure: Float, orientation: Float, tilt: Float) =
                Sample(x, y, pressure.toDouble().coerceIn(0.0, 1.0), azimuth(orientation), altitude(tilt))
        }
    }

    var penDown = false
        private set
    private var proximityActive = false
    private var pendingClose: TouchGestures.Cancellable? = null

    private val wire get() = senderPv() >= WireProtocol.PENCIL_WIRE_VERSION

    fun down(s: Sample) {
        penDown = true
        if (!wire) return output.touch("began", s.x, s.y)
        openProximity(s)
        output.pencil("down", s)
    }

    fun move(s: Sample) {
        if (!penDown) return
        if (!wire) return output.touch("moved", s.x, s.y)
        output.pencil("move", s)
    }

    fun up(s: Sample, cancelled: Boolean = false) {
        if (!penDown) return
        penDown = false
        if (!wire) return output.touch(if (cancelled) "cancelled" else "ended", s.x, s.y)
        output.pencil("up", s.copy(pressure = 0.0))
        // Usually the pen is still in hover range: Android sends HOVER_ENTER
        // next. If it doesn't, close proximity like iOS does after a stroke.
        scheduleClose(s.x, s.y)
    }

    fun hover(s: Sample) {
        if (penDown || !wire) return
        openProximity(s)
        output.pencil("hover", s)
    }

    /** HOVER_EXIT also precedes every touch-down; give `down` a moment to cancel it. */
    fun hoverExit(x: Double, y: Double) {
        if (penDown || !wire) return
        scheduleClose(x, y)
    }

    private fun openProximity(s: Sample) {
        pendingClose?.cancel()
        pendingClose = null
        if (proximityActive) return
        proximityActive = true
        output.proximity(true, s.x, s.y)
    }

    private fun scheduleClose(x: Double, y: Double) {
        pendingClose?.cancel()
        pendingClose = scheduler.schedule(PROXIMITY_GRACE_MS) {
            pendingClose = null
            if (!penDown && proximityActive) {
                proximityActive = false
                output.proximity(false, x, y)
            }
        }
    }

    companion object {
        const val PROXIMITY_GRACE_MS = 80L

        /**
         * Android: the direction the stylus points, clockwise from screen-up.
         * Wire (UIKit): clockwise from +x in screen coordinates (y down).
         */
        fun azimuth(orientation: Float): Double {
            val a = orientation.toDouble() - PI / 2
            return ((a % (2 * PI)) + 2 * PI) % (2 * PI)
        }

        /** Android tilt 0 = perpendicular; wire altitude pi/2 = perpendicular. */
        fun altitude(tilt: Float): Double = (PI / 2 - tilt.toDouble()).coerceIn(0.0, PI / 2)
    }
}
