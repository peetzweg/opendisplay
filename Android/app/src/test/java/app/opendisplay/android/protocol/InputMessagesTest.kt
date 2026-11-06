package app.opendisplay.android.protocol

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** The input additions of PROTOCOL.md 6.1/6.2 (welcome.input, touch.button, scroll.phase, magnify, gesture). */
class InputMessagesTest {
    @Test
    fun plainTouchAndScrollStayAsBefore() {
        assertFalse(Messages.touch("began", 0.5, 0.5, null).has("button"))
        assertFalse(Messages.scroll(1.0, 2.0).has("phase"))
    }

    @Test
    fun secondaryTouchAndPhasedScroll() {
        assertEquals("right", Messages.touch("began", 0.5, 0.5, null, button = "right").getString("button"))
        assertEquals("momentumBegan", Messages.scroll(0.0, 3.0, "momentumBegan").getString("phase"))
    }

    @Test
    fun magnifyAndGesture() {
        val m = Messages.magnify("changed", 0.2)
        assertEquals("magnify", m.getString("type"))
        assertEquals(0.2, m.getDouble("m"), 1e-9)
        assertEquals("missionControl", Messages.gesture("missionControl").getString("action"))
    }

    @Test
    fun featuresFromWelcomeInput() {
        val input = JSONArray(listOf("button", "scrollPhase", 7, "future")).strings().toSet()
        val f = TouchGestures.Features.from(input)
        assertEquals(TouchGestures.Features(button = true, scrollPhase = true, magnify = false), f)
        assertEquals(true, f.touchscreen)
    }

    @Test
    fun missingInputMeansNothing() {
        val none: JSONArray? = null
        assertEquals(emptyList<String>(), none.strings())
        assertFalse(TouchGestures.Features.from(emptySet()).touchscreen)
    }
}
