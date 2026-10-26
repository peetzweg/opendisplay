package app.opendisplay.android.protocol

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.pow

/**
 * Turns raw finger events into `touch`, `scroll` and `magnify` messages,
 * matching the iOS receiver (iOS/OpenSidecarPhoneApp.swift VideoView).
 *
 * With a sender that takes `touch.button` and `scroll.phase`
 * ([Features.touchscreen]), one finger behaves like a touchscreen, as on the
 * device itself and in macOS 27 Sidecar: dragging right away scrolls (and
 * coasts after a flick); holding still for [LONG_PRESS_MS], then moving, drags
 * with the button down (select, move a window); holding and lifting is a
 * secondary click; a tap is a click. Two fingers scroll with trackpad phases,
 * pinch zooms ([Features.magnify]) and a quick two-finger tap is a secondary
 * click.
 *
 * Older senders get the original rules:
 * - A press is only a click once we know a second finger is not coming. The
 *   `began` is withheld until the finger moves past the drag slop or is held
 *   for [holdDelayMs]; a quick tap posts the whole click on lift. Sending
 *   `began` on contact meant every two-finger scroll first clicked whatever
 *   sat under the first finger.
 * - Two fingers scroll: the cursor is put on the gesture once, up front, then
 *   centroid deltas go out in video pixels with natural-scrolling sign.
 *
 * Pure logic: the view feeds positions, a [Scheduler] runs the timers.
 */
class TouchGestures(
    private val output: Output,
    private val scheduler: Scheduler,
    private val dragSlopPx: Float,
    private val holdDelayMs: Long = 120,
    /** What the sender takes, read when a finger lands. */
    private val features: () -> Features = { Features() },
    /** Milliseconds on the clock of [Point.t] (MotionEvent's uptime). */
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    interface Output {
        fun touch(phase: String, x: Double, y: Double)
        fun scroll(dx: Double, dy: Double)
        /** A secondary-button press (`touch.button: "right"`); [Features.button] only. */
        fun secondaryTouch(phase: String, x: Double, y: Double) {}
        /** A trackpad-style scroll (`scroll.phase`); [Features.scrollPhase] only. */
        fun phasedScroll(dx: Double, dy: Double, phase: String) {}
        /** A pinch (`magnify`); [Features.magnify] only. */
        fun magnify(phase: String, m: Double) {}
        /** A hold armed: moving now drags, lifting is a secondary click. Time for a haptic. */
        fun holdArmed() {}
    }

    fun interface Cancellable {
        fun cancel()
    }

    fun interface Scheduler {
        fun schedule(delayMs: Long, action: () -> Unit): Cancellable
    }

    /** What the sender takes, from `welcome.input` (see InputFeature). */
    data class Features(val button: Boolean = false, val scrollPhase: Boolean = false, val magnify: Boolean = false) {
        /** One finger follows the touchscreen rules. */
        val touchscreen: Boolean get() = button && scrollPhase

        companion object {
            fun from(input: Set<String>) = Features(
                button = InputFeature.BUTTON in input,
                scrollPhase = InputFeature.SCROLL_PHASE in input,
                magnify = InputFeature.MAGNIFY in input,
            )
        }
    }

    /**
     * One sample: screen pixels for distances, normalized video for the wire,
     * [t] the event time in milliseconds (0 when unknown).
     */
    class Point(val px: Float, val py: Float, val nx: Double, val ny: Double, val t: Long = 0)

    private var pendingDown: Point? = null
    private var downSent = false
    private var holdTimer: Cancellable? = null
    private var lastNorm: Point? = null

    private var twoFinger = false
    private var lastCentroid: Point? = null

    /** The sender's features for the gesture in progress, fixed when it starts. */
    private var mode = Features()

    private enum class Intent { DECIDING, SCROLLING, HELD, PRESSING }
    private var intent = Intent.DECIDING

    private enum class TwoFinger { DECIDING, SCROLLING, PINCHING, DONE }
    private var twoFingerIntent = TwoFinger.DECIDING
    private var twoFingerStart: Point? = null
    private var startSpan = 0f
    private var lastSpan = 0f

    private var scrollStarted = false
    private var lastScrollPoint: Point? = null
    private var lastVideoScale = 1f
    /** Recent points of the scrolling finger(s), for the lift-off velocity. */
    private val samples = ArrayDeque<Point>()

    private val momentum = Momentum()

    fun down(p: Point) {
        momentum.stop()
        twoFinger = false
        lastCentroid = null
        discardPendingDown()
        mode = features()
        pendingDown = p
        lastNorm = p
        holdTimer = if (mode.touchscreen) {
            scheduler.schedule(LONG_PRESS_MS) { armHold() }
        } else {
            scheduler.schedule(holdDelayMs) { commitPendingDown() }
        }
    }

    /** A further finger landed; [centroid] of all fingers down now, [span] between the first two. */
    fun pointerDown(pointerCount: Int, centroid: Point, span: Float = 0f) {
        if (downSent) lastNorm?.let { output.touch("cancelled", it.nx, it.ny) }
        if (intent == Intent.SCROLLING) endPhasedScroll(lift = null)
        discardPendingDown()
        if (pointerCount == 2 && !twoFinger) {
            twoFinger = true
            // macOS scrolls whatever sits under the cursor; put it on the
            // gesture once so the scroll lands on the window being touched.
            output.touch("moved", centroid.nx, centroid.ny)
            twoFingerIntent = TwoFinger.DECIDING
            twoFingerStart = centroid
            startSpan = span
            lastSpan = span
            scrollStarted = false
            samples.clear()
        }
        lastCentroid = centroid
    }

    /**
     * A finger lifted while others stay down: re-seed so the centroid doesn't
     * jump. Under the new rules this also ends the two-finger gesture (a quick
     * one is a secondary click). [p] carries the lift time.
     */
    fun pointerUp(p: Point? = null) {
        lastCentroid = null
        if (!twoFinger) return
        when (twoFingerIntent) {
            TwoFinger.DECIDING -> {
                val start = twoFingerStart
                if (mode.button && start != null && p != null && p.t - start.t < TWO_FINGER_TAP_MS) {
                    output.touch("moved", start.nx, start.ny)
                    output.secondaryTouch("began", start.nx, start.ny)
                    output.secondaryTouch("ended", start.nx, start.ny)
                }
            }
            TwoFinger.SCROLLING -> endPhasedScroll(lift = p)
            TwoFinger.PINCHING -> output.magnify("ended", 0.0)
            TwoFinger.DONE -> {}
        }
        twoFingerIntent = TwoFinger.DONE
    }

    /**
     * [primary] is the first finger, [centroid] all fingers, [videoScale]
     * screen pixels per video pixel, [span] the distance between the first two.
     */
    fun move(pointerCount: Int, primary: Point, centroid: Point, videoScale: Float, span: Float = 0f) {
        if (videoScale > 0f) lastVideoScale = videoScale
        if (twoFinger) {
            if (pointerCount < 2) return
            val last = lastCentroid
            lastCentroid = centroid
            if (last == null || videoScale <= 0f) return
            if (mode.scrollPhase || mode.magnify) {
                twoFingerMove(centroid, last, videoScale, span)
                return
            }
            val dx = (centroid.px - last.px) / videoScale
            val dy = (centroid.py - last.py) / videoScale
            if (dx != 0f || dy != 0f) output.scroll(dx.toDouble(), dy.toDouble())
            return
        }
        lastNorm = primary
        if (mode.touchscreen) {
            oneFingerMove(primary, videoScale)
            return
        }
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
            if (twoFingerIntent != TwoFinger.DONE) pointerUp(p)
            twoFinger = false
            lastCentroid = null
            discardPendingDown()
            return
        }
        if (mode.touchscreen) {
            oneFingerUp(p)
            return
        }
        // A tap: nothing was posted yet, so post the whole click now.
        if (pendingDown != null && !downSent) commitPendingDown()
        if (downSent) output.touch("ended", p.nx, p.ny)
        discardPendingDown()
    }

    fun cancel() {
        if (intent == Intent.SCROLLING) endPhasedScroll(lift = null)
        if (twoFinger) {
            when (twoFingerIntent) {
                TwoFinger.SCROLLING -> endPhasedScroll(lift = null)
                TwoFinger.PINCHING -> output.magnify("cancelled", 0.0)
                else -> {}
            }
            twoFingerIntent = TwoFinger.DONE
        }
        momentum.stop()
        if (downSent) lastNorm?.let { output.touch("cancelled", it.nx, it.ny) }
        discardPendingDown()
        twoFinger = false
        lastCentroid = null
    }

    // region Touchscreen rules

    private fun oneFingerMove(primary: Point, videoScale: Float) {
        val pending = pendingDown
        val moved = pending != null && hypot(primary.px - pending.px, primary.py - pending.py) > dragSlopPx
        when (intent) {
            Intent.DECIDING -> {
                if (pending == null || !moved) return
                // Moving right away is a scroll. The Mac scrolls whatever is
                // under the pointer: put it where the finger landed, once.
                holdTimer?.cancel()
                holdTimer = null
                intent = Intent.SCROLLING
                output.touch("moved", pending.nx, pending.ny)
                pendingDown = null
                scrollStarted = false
                // Start from here, not the landing point, so the slop is no jump.
                lastScrollPoint = primary
                samples.clear()
                samples.addLast(primary)
            }
            Intent.SCROLLING -> {
                val last = lastScrollPoint ?: primary
                lastScrollPoint = primary
                phasedDelta(primary, last, videoScale)
            }
            Intent.HELD -> {
                if (!moved) return
                intent = Intent.PRESSING
                commitPendingDown()
                output.touch("moved", primary.nx, primary.ny)
            }
            Intent.PRESSING -> output.touch("moved", primary.nx, primary.ny)
        }
    }

    private fun oneFingerUp(p: Point) {
        val pending = pendingDown
        // A lift delivered late after a short press is still a tap.
        if (intent == Intent.HELD && pending != null && p.t > 0 && pending.t > 0 &&
            p.t - pending.t < LONG_PRESS_MS) {
            intent = Intent.DECIDING
        }
        when (intent) {
            Intent.DECIDING -> {
                commitPendingDown()
                if (downSent) output.touch("ended", p.nx, p.ny)
            }
            Intent.HELD -> pending?.let {
                output.touch("moved", it.nx, it.ny)
                output.secondaryTouch("began", it.nx, it.ny)
                output.secondaryTouch("ended", it.nx, it.ny)
            }
            Intent.SCROLLING -> endPhasedScroll(lift = p)
            Intent.PRESSING -> output.touch("ended", p.nx, p.ny)
        }
        discardPendingDown()
    }

    private fun armHold() {
        if (intent != Intent.DECIDING || pendingDown == null) return
        intent = Intent.HELD
        holdTimer = null
        output.holdArmed()
    }

    private fun twoFingerMove(centroid: Point, last: Point, videoScale: Float, span: Float) {
        when (twoFingerIntent) {
            TwoFinger.DECIDING -> {
                // Pan or pinch, decided once, whichever the fingers commit to first.
                val start = twoFingerStart ?: centroid
                val travelled = hypot(centroid.px - start.px, centroid.py - start.py)
                val spread = abs(span - startSpan)
                twoFingerIntent = when {
                    mode.magnify && startSpan > 0f && spread > dragSlopPx && spread > travelled -> TwoFinger.PINCHING
                    travelled > dragSlopPx -> TwoFinger.SCROLLING
                    else -> return
                }
                lastSpan = span
                if (twoFingerIntent == TwoFinger.PINCHING) {
                    output.magnify("began", 0.0)
                } else {
                    samples.clear()
                    samples.addLast(centroid)
                }
            }
            TwoFinger.PINCHING -> {
                // Relative change, so the Mac's running product equals the pinch.
                if (lastSpan > 0f && span > 0f) output.magnify("changed", (span / lastSpan - 1f).toDouble())
                lastSpan = span
            }
            TwoFinger.SCROLLING -> if (mode.scrollPhase) {
                phasedDelta(centroid, last, videoScale)
            } else {
                val dx = (centroid.px - last.px) / videoScale
                val dy = (centroid.py - last.py) / videoScale
                if (dx != 0f || dy != 0f) output.scroll(dx.toDouble(), dy.toDouble())
            }
            TwoFinger.DONE -> {}
        }
    }

    /** Content follows the fingers (natural direction), in video pixels. */
    private fun phasedDelta(p: Point, last: Point, videoScale: Float) {
        samples.addLast(p)
        while (samples.size > 2 && p.t - samples.first().t > VELOCITY_WINDOW_MS) samples.removeFirst()
        if (videoScale <= 0f) return
        val dx = (p.px - last.px) / videoScale
        val dy = (p.py - last.py) / videoScale
        if (dx == 0f && dy == 0f) return
        output.phasedScroll(dx.toDouble(), dy.toDouble(), if (scrollStarted) "changed" else "began")
        scrollStarted = true
    }

    /** End the touch phase; with a [lift] that was a flick, coast. */
    private fun endPhasedScroll(lift: Point?) {
        if (scrollStarted) {
            output.phasedScroll(0.0, 0.0, "ended")
            val first = samples.firstOrNull()
            val last = samples.lastOrNull()
            // A finger that stopped before lifting set the content down: no flick.
            if (lift != null && first != null && last != null &&
                last.t - first.t > 8 && lift.t - last.t < 50) {
                val dt = (last.t - first.t) / 1000f
                momentum.start((last.px - first.px) / dt, (last.py - first.py) / dt, lastVideoScale)
            }
        }
        scrollStarted = false
        samples.clear()
        lastScrollPoint = null
        if (intent == Intent.SCROLLING) intent = Intent.DECIDING
    }

    /**
     * After a flick the content keeps coasting, like a Mac trackpad. Generated
     * here rather than on the Mac: this side has the real finger velocity.
     * Constants from the iOS receiver (#372): 0.96 decay per 1/60 s, stop below
     * 0.3 dp per frame, ignore lift-offs slower than 150 dp/s.
     */
    private inner class Momentum {
        /** Screen pixels per second, natural sign. */
        private var vx = 0f
        private var vy = 0f
        private var videoScale = 1f
        private var started = false
        private var lastTick = 0L
        private var timer: Cancellable? = null

        // The slop is 10 dp, which gives the dp size without a Context.
        private val dp get() = dragSlopPx / 10f

        fun start(vx: Float, vy: Float, videoScale: Float) {
            stop()
            if (hypot(vx, vy) < MIN_FLICK_DP_PER_S * dp || videoScale <= 0f) return
            this.vx = vx
            this.vy = vy
            this.videoScale = videoScale
            lastTick = now()
            timer = scheduler.schedule(FRAME_MS) { tick() }
        }

        private fun tick() {
            val t = now()
            val dt = (t - lastTick).coerceAtLeast(1) / 1000f
            lastTick = t
            val frames = dt * 60f
            val decay = DECAY_PER_FRAME.pow(frames)
            vx *= decay
            vy *= decay
            val dx = vx * dt
            val dy = vy * dt
            if (hypot(dx, dy) < STOP_DP_PER_FRAME * dp * frames) {
                stop()
                return
            }
            output.phasedScroll((dx / videoScale).toDouble(), (dy / videoScale).toDouble(),
                if (started) "momentumChanged" else "momentumBegan")
            started = true
            timer = scheduler.schedule(FRAME_MS) { tick() }
        }

        /** Stop coasting, e.g. because a finger landed and caught the content. */
        fun stop() {
            timer?.cancel()
            timer = null
            if (started) {
                started = false
                output.phasedScroll(0.0, 0.0, "momentumEnded")
            }
        }
    }

    // endregion

    /** Emit the withheld `began` where the finger first landed. */
    private fun commitPendingDown() {
        val p = pendingDown ?: return
        if (downSent) return
        downSent = true
        holdTimer?.cancel()
        holdTimer = null
        // Move first: some apps act on the position the last mouse move left
        // (#310), and under the touchscreen rules no hover moves came before.
        if (mode.touchscreen) output.touch("moved", p.nx, p.ny)
        output.touch("began", p.nx, p.ny)
    }

    private fun discardPendingDown() {
        pendingDown = null
        downSent = false
        holdTimer?.cancel()
        holdTimer = null
        intent = Intent.DECIDING
    }

    companion object {
        /** A press held this long without moving arms a drag or a secondary click. */
        const val LONG_PRESS_MS = 500L
        private const val TWO_FINGER_TAP_MS = 300L
        private const val VELOCITY_WINDOW_MS = 100L
        private const val FRAME_MS = 16L
        private const val DECAY_PER_FRAME = 0.96f
        private const val STOP_DP_PER_FRAME = 0.3f
        private const val MIN_FLICK_DP_PER_S = 150f
    }
}
