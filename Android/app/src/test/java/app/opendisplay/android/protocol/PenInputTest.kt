package app.opendisplay.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import kotlin.math.PI

class PenInputTest {
    private val events = mutableListOf<String>()
    private var pending: (() -> Unit)? = null
    private var pv = 3
    private lateinit var pen: PenInput

    @Before
    fun setUp() {
        pen = PenInput(
            output = object : PenInput.Output {
                override fun pencil(phase: String, s: PenInput.Sample) {
                    events.add("pencil $phase %.1f".format(s.pressure))
                }
                override fun proximity(entering: Boolean, x: Double, y: Double) {
                    events.add("proximity $entering")
                }
                override fun touch(phase: String, x: Double, y: Double) {
                    events.add("touch $phase")
                }
            },
            scheduler = { _, action ->
                pending = action
                TouchGestures.Cancellable { pending = null }
            },
            senderPv = { pv },
        )
    }

    private fun s(p: Float = 0.5f) = PenInput.Sample.fromAxes(0.5, 0.5, p, 0f, 0f)

    @Test
    fun strokeWithHoverKeepsProximityOpenAcrossTheDown() {
        pen.hover(s(0f))
        pen.hoverExit(0.5, 0.5) // Android: HOVER_EXIT right before DOWN
        pen.down(s())
        pen.move(s(0.8f))
        pen.up(s())
        pen.hover(s(0f)) // back in hover range: no leave/enter flicker
        pen.hoverExit(0.5, 0.5)
        pending!!.invoke() // really gone
        assertEquals(listOf("proximity true", "pencil hover 0.0", "pencil down 0.5", "pencil move 0.8",
            "pencil up 0.0", "pencil hover 0.0", "proximity false"), events)
    }

    @Test
    fun strokeWithoutHoverStillClosesProximity() {
        pen.down(s())
        pen.up(s())
        pending!!.invoke()
        assertEquals(listOf("proximity true", "pencil down 0.5", "pencil up 0.0", "proximity false"), events)
    }

    @Test
    fun oldSenderGetsTouches() {
        pv = 2
        pen.hover(s(0f))
        pen.down(s())
        pen.move(s())
        pen.up(s())
        assertEquals(listOf("touch began", "touch moved", "touch ended"), events)
    }

    @Test
    fun anglesMapToUIKitConventions() {
        // Perpendicular pen: tilt 0 -> altitude pi/2.
        assertEquals(PI / 2, PenInput.altitude(0f), 1e-6)
        assertEquals(0.0, PenInput.altitude((PI / 2).toFloat()), 1e-6)
        // Body pointing down-right (Android 3pi/4 from up) -> pi/4 from +x, y down.
        assertEquals(PI / 4, PenInput.azimuth((3 * PI / 4).toFloat()), 1e-6)
        // Pointing up -> 3pi/2 (normalized into 0..2pi).
        assertEquals(3 * PI / 2, PenInput.azimuth(0f), 1e-6)
    }
}
