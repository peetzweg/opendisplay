package app.opendisplay.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Locale

/** TouchGestures with a sender that takes the new input features. */
class TouchscreenGesturesTest {
    private val events = mutableListOf<String>()
    private var clock = 0L
    private val tasks = mutableListOf<Pair<Long, () -> Unit>>()
    private lateinit var g: TouchGestures

    @Before
    fun setUp() {
        g = TouchGestures(
            output = object : TouchGestures.Output {
                override fun touch(phase: String, x: Double, y: Double) {
                    events.add("$phase %.2f,%.2f".format(Locale.ROOT, x, y))
                }
                override fun scroll(dx: Double, dy: Double) {
                    events.add("plain scroll %.1f,%.1f".format(Locale.ROOT, dx, dy))
                }
                override fun secondaryTouch(phase: String, x: Double, y: Double) {
                    events.add("right $phase %.2f,%.2f".format(Locale.ROOT, x, y))
                }
                override fun phasedScroll(dx: Double, dy: Double, phase: String) {
                    events.add("scroll $phase %.1f,%.1f".format(Locale.ROOT, dx, dy))
                }
                override fun magnify(phase: String, m: Double) {
                    events.add("magnify $phase %.2f".format(Locale.ROOT, m))
                }
                override fun holdArmed() {
                    events.add("armed")
                }
            },
            scheduler = { delay, action ->
                val task = (clock + delay) to action
                tasks.add(task)
                TouchGestures.Cancellable { tasks.remove(task) }
            },
            dragSlopPx = 10f,
            features = { TouchGestures.Features(button = true, scrollPhase = true, magnify = true) },
            now = { clock },
        )
    }

    /** Advance the fake clock, running every timer that falls due. */
    private fun advance(ms: Long) {
        val end = clock + ms
        while (true) {
            val next = tasks.minByOrNull { it.first } ?: break
            if (next.first > end) break
            tasks.remove(next)
            clock = next.first
            next.second()
        }
        clock = end
    }

    private fun p(px: Float, py: Float, t: Long = clock) = TouchGestures.Point(px, py, px / 1000.0, py / 1000.0, t)

    @Test
    fun tapMovesThePointerThenClicks() {
        g.down(p(100f, 100f))
        advance(80)
        g.up(p(101f, 101f))
        assertEquals(listOf("moved 0.10,0.10", "began 0.10,0.10", "ended 0.10,0.10"), events)
    }

    @Test
    fun dragRightAwayScrollsAndNeverPresses() {
        g.down(p(100f, 100f))
        g.move(1, p(100f, 120f), p(100f, 120f), 1f)   // past slop: position the pointer
        g.move(1, p(100f, 150f), p(100f, 150f), 2f)   // 30 px at 2 px per video pixel
        g.move(1, p(100f, 160f), p(100f, 160f), 2f)
        advance(200)
        g.up(p(100f, 160f))
        assertEquals(listOf("moved 0.10,0.10", "scroll began 0.0,15.0", "scroll changed 0.0,5.0", "scroll ended 0.0,0.0"),
            events)
    }

    @Test
    fun holdThenDragPressesAtTheLandingPoint() {
        g.down(p(100f, 100f))
        advance(500)
        assertEquals(listOf("armed"), events)
        g.move(1, p(150f, 100f), p(150f, 100f), 1f)
        g.up(p(150f, 100f))
        assertEquals(listOf("armed", "moved 0.10,0.10", "began 0.10,0.10", "moved 0.15,0.10", "ended 0.15,0.10"),
            events)
    }

    @Test
    fun holdAndLiftIsASecondaryClick() {
        g.down(p(100f, 100f))
        advance(600)
        g.up(p(100f, 100f))
        assertEquals(listOf("armed", "moved 0.10,0.10", "right began 0.10,0.10", "right ended 0.10,0.10"), events)
    }

    /** A lift delivered after the hold timer fired, for a short press, is still a tap. */
    @Test
    fun lateLiftOfAShortPressIsATap() {
        g.down(p(100f, 100f, t = 1_000))
        advance(600)
        g.up(p(100f, 100f, t = 1_200))   // lifted 200 ms in, delivered after the timer
        assertEquals(listOf("armed", "moved 0.10,0.10", "began 0.10,0.10", "ended 0.10,0.10"), events)
    }

    @Test
    fun flickCoastsUntilItSettles() {
        g.down(p(100f, 100f))
        for (i in 1..6) {
            advance(10)
            g.move(1, p(100f, 100f + 30f * i), p(100f, 100f + 30f * i), 1f)   // 3000 px/s
        }
        g.up(p(100f, 280f))
        assertEquals("scroll ended 0.0,0.0", events.last())
        advance(5_000)
        val coast = events.dropWhile { it != "scroll ended 0.0,0.0" }.drop(1)
        assertTrue(coast.first().startsWith("scroll momentumBegan"))
        assertTrue(coast.drop(1).dropLast(1).all { it.startsWith("scroll momentumChanged") })
        assertEquals("scroll momentumEnded 0.0,0.0", coast.last())
        assertTrue("coasts over many frames", coast.size > 30)
    }

    /** A finger that stops before lifting sets the content down: no coast. */
    @Test
    fun stoppingBeforeLiftHasNoMomentum() {
        g.down(p(100f, 100f))
        for (i in 1..6) {
            advance(10)
            g.move(1, p(100f, 100f + 30f * i), p(100f, 100f + 30f * i), 1f)
        }
        advance(200)
        g.up(p(100f, 280f))
        advance(1_000)
        assertEquals("scroll ended 0.0,0.0", events.last())
    }

    @Test
    fun aNewTouchCatchesTheCoast() {
        g.down(p(100f, 100f))
        for (i in 1..6) {
            advance(10)
            g.move(1, p(100f, 100f + 30f * i), p(100f, 100f + 30f * i), 1f)
        }
        g.up(p(100f, 280f))
        advance(100)
        g.down(p(300f, 300f))
        assertEquals("scroll momentumEnded 0.0,0.0", events.last())
        val before = events.size
        advance(1_000)
        assertEquals("armed", events.drop(before).single())
    }

    @Test
    fun twoFingerTapIsASecondaryClick() {
        g.down(p(100f, 100f))
        g.pointerDown(2, p(150f, 100f), span = 100f)
        advance(100)
        g.pointerUp(p(150f, 100f))
        g.up(p(150f, 100f))
        assertEquals(listOf("moved 0.15,0.10", "moved 0.15,0.10", "right began 0.15,0.10", "right ended 0.15,0.10"),
            events)
    }

    @Test
    fun pinchMagnifiesWithRelativeSteps() {
        g.down(p(100f, 100f))
        g.pointerDown(2, p(150f, 100f), span = 100f)
        g.move(2, p(100f, 100f), p(150f, 100f), 1f, span = 130f)   // spread past slop: pinch
        g.move(2, p(100f, 100f), p(150f, 100f), 1f, span = 156f)
        g.pointerUp(p(150f, 100f))
        g.up(p(150f, 100f))
        assertEquals(listOf("moved 0.15,0.10", "magnify began 0.00", "magnify changed 0.20", "magnify ended 0.00"),
            events)
    }

    @Test
    fun twoFingerPanScrollsWithPhases() {
        g.down(p(100f, 100f))
        g.pointerDown(2, p(150f, 100f), span = 100f)
        g.move(2, p(100f, 120f), p(150f, 120f), 1f, span = 100f)   // travelled past slop
        g.move(2, p(100f, 130f), p(150f, 130f), 1f, span = 100f)
        advance(200)
        g.pointerUp(p(150f, 130f))
        g.up(p(150f, 130f))
        assertEquals(listOf("moved 0.15,0.10", "scroll began 0.0,10.0", "scroll ended 0.0,0.0"), events)
    }

    @Test
    fun aSecondFingerEndsAOneFingerScroll() {
        g.down(p(100f, 100f))
        g.move(1, p(100f, 120f), p(100f, 120f), 1f)
        g.move(1, p(100f, 130f), p(100f, 130f), 1f)
        g.pointerDown(2, p(150f, 130f), span = 100f)
        assertEquals(listOf("moved 0.10,0.10", "scroll began 0.0,10.0", "scroll ended 0.0,0.0", "moved 0.15,0.13"),
            events)
    }

    @Test
    fun cancelReleasesAHeldPress() {
        g.down(p(100f, 100f))
        advance(500)
        g.move(1, p(150f, 100f), p(150f, 100f), 1f)
        g.cancel()
        assertEquals("cancelled 0.15,0.10", events.last())
    }
}
