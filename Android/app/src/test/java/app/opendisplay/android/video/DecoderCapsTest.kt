package app.opendisplay.android.video

import app.opendisplay.android.protocol.Codec
import org.junit.Assert.assertEquals
import org.junit.Test

class DecoderCapsTest {
    @Test
    fun floorAndCeilAreStepAligned() {
        assertEquals(48, DecoderCaps.floorTo(63, 16))
        assertEquals(64, DecoderCaps.ceilTo(63, 16))
        assertEquals(64, DecoderCaps.floorTo(64, 16))
        assertEquals(64, DecoderCaps.ceilTo(64, 16))
    }

    @Test
    fun compatCapsStayH264AlignedAndFifteenFps() {
        val caps = DecoderCaps.videoCaps(1920, 1080, compat = true)

        assertEquals(1, caps.size)
        val cap = caps.single()
        assertEquals(Codec.H264, cap.codec)
        assertEquals(1920, cap.maxWidth)
        assertEquals(1072, cap.maxHeight)
        assertEquals(DecoderCaps.LEGACY_TARGET_FPS, cap.maxFrameRate)
    }
}
