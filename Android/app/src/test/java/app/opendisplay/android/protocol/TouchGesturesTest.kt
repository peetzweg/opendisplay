package app.opendisplay.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

class TouchGesturesTest {
    private val events = mutableListOf<String>()
    private var pending: (() -> Unit)? = null
    private lateinit var g: TouchGestures

    @Before
    fun setUp() {
        g = TouchGestures(
            output = object : TouchGestures.Output {
                override fun touch(phase: String, x: Double, y: Double) {
                    events.add("$phase %.2f,%.2f".format(x, y))
                }
                override fun scroll(dx: Double, dy: Double) {
                    events.add("scroll %.1f,%.1f".format(dx, dy))
                }
            },
            scheduler = { _, action ->
                pending = action
                TouchGestures.Cancellable { pending = null }
            },
            dragSlopPx = 10f,
        )
    }

    private fun p(px: Float, py: Float) = TouchGestures.Point(px, py, px / 1000.0, py / 1000.0)

    @Test
    fun quickTapIsAWholeClickOnLift() {
        g.down(p(100f, 100f))
        assertEquals(emptyList<String>(), events)
        g.up(p(101f, 101f))
        assertEquals(listOf("began 0.10,0.10", "ended 0.10,0.10"), events)
    }

    @Test
    fun holdCommitsThePress() {
        g.down(p(100f, 100f))
        pending!!.invoke() // hold delay elapsed
        assertEquals(listOf("began 0.10,0.10"), events)
        g.up(p(100f, 100f))
        assertEquals("ended 0.10,0.10", events.last())
    }

    @Test
    fun dragPastSlopStartsAtTheLandingPoint() {
        g.down(p(100f, 100f))
        g.move(1, p(105f, 100f), p(105f, 100f), 1f) // inside slop: cursor only
        assertEquals(listOf("moved 0.11,0.10"), events)
        g.move(1, p(200f, 100f), p(200f, 100f), 1f)
        assertEquals(listOf("moved 0.11,0.10", "began 0.10,0.10", "moved 0.20,0.10"), events)
    }

    @Test
    fun twoFingerScrollNeverClicks() {
        g.down(p(100f, 100f))
        g.pointerDown(2, p(150f, 100f))
        g.move(2, p(100f, 120f), p(150f, 120f), 2f)
        g.move(2, p(100f, 110f), p(150f, 110f), 2f)
        g.pointerUp()
        g.move(1, p(100f, 200f), p(100f, 200f), 2f) // leftover finger: ignored
        g.up(p(100f, 200f))
        // Cursor placed once on the gesture, then natural-sign deltas in video pixels.
        assertEquals(listOf("moved 0.15,0.10", "scroll 0.0,10.0", "scroll 0.0,-5.0"), events)
    }

    @Test
    fun oneFingerDragScrollsInsteadOfPressing() {
        g.oneFingerScroll = true
        g.down(p(100f, 100f))
        g.move(1, p(105f, 100f), p(105f, 100f), 2f) // inside slop: cursor only
        g.move(1, p(100f, 120f), p(100f, 120f), 2f) // past slop: starts scrolling, no delta yet
        g.move(1, p(100f, 140f), p(100f, 140f), 2f)
        g.up(p(100f, 140f))
        assertEquals(listOf("moved 0.11,0.10", "scroll 0.0,10.0"), events)
    }

    @Test
    fun oneFingerScrollStillClicksOnATap() {
        g.oneFingerScroll = true
        g.down(p(100f, 100f))
        g.up(p(101f, 101f))
        assertEquals(listOf("began 0.10,0.10", "ended 0.10,0.10"), events)
    }

    @Test
    fun oneFingerScrollUsesTheLongerHoldBeforeDragging() {
        g.oneFingerScroll = true
        var delay = -1L
        val timed = TouchGestures(
            output = object : TouchGestures.Output {
                override fun touch(phase: String, x: Double, y: Double) {}
                override fun scroll(dx: Double, dy: Double) {}
            },
            scheduler = { d, _ ->
                delay = d
                TouchGestures.Cancellable { }
            },
            dragSlopPx = 10f,
            holdDelayMs = 120,
            scrollModeHoldMs = 350,
        )
        timed.oneFingerScroll = true
        timed.down(p(1f, 1f))
        assertEquals(350L, delay)
        timed.oneFingerScroll = false
        timed.down(p(1f, 1f))
        assertEquals(120L, delay)
    }

    @Test
    fun oneFingerHoldThenDragStillDrags() {
        g.oneFingerScroll = true
        g.down(p(100f, 100f))
        pending!!.invoke() // the longer hold elapsed
        g.move(1, p(200f, 100f), p(200f, 100f), 1f)
        assertEquals(listOf("began 0.10,0.10", "moved 0.20,0.10"), events)
    }

    @Test
    fun secondFingerTurnsOneFingerScrollIntoTwoFingerScroll() {
        g.oneFingerScroll = true
        g.down(p(100f, 100f))
        g.move(1, p(100f, 120f), p(100f, 120f), 2f) // scrolling begins
        g.pointerDown(2, p(125f, 120f))
        g.move(2, p(100f, 130f), p(125f, 130f), 2f)
        assertEquals(listOf("moved 0.13,0.12", "scroll 0.0,5.0"), events)
    }

    @Test
    fun secondFingerAfterCommitCancelsThePress() {
        g.down(p(100f, 100f))
        pending!!.invoke()
        g.pointerDown(2, p(150f, 100f))
        assertEquals(listOf("began 0.10,0.10", "cancelled 0.10,0.10", "moved 0.15,0.10"), events)
    }
}
