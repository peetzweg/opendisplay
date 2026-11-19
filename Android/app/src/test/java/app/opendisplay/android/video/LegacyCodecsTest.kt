package app.opendisplay.android.video

import app.opendisplay.android.protocol.AnnexB
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression tests for the Android 5/6 (CM13) OMX decoder workarounds.
 * The visible 1080-wide raster is the case that used to come out as diagonal
 * stripes: H.264 codes 68 macroblocks (1088 px) and crops 8 px in the SPS.
 */
class LegacyCodecsTest {
    @Test
    fun detectsLegacyPlatforms() {
        assertTrue(LegacyCodecs.isLegacy(21))
        assertTrue(LegacyCodecs.isLegacy(23)) // CyanogenMod 13 / Android 6.0.1
        assertFalse(LegacyCodecs.isLegacy(24))
        assertFalse(LegacyCodecs.isLegacy(36))
    }

    @Test
    fun neverAlignsFinerThanMacroblocksOnLegacy() {
        assertEquals(16, LegacyCodecs.alignment(1))
        assertEquals(16, LegacyCodecs.alignment(2))
        assertEquals(32, LegacyCodecs.alignment(32))
        assertEquals(16 to 16, LegacyCodecs.advertisedAlignments(23, 2, 2))
        assertEquals(2 to 2, LegacyCodecs.advertisedAlignments(24, 2, 2))
    }

    @Test
    fun roundsUpAndDown() {
        assertEquals(1088, LegacyCodecs.ceilTo(1080, 16))
        assertEquals(1072, LegacyCodecs.floorTo(1080, 16))
        assertEquals(1088, LegacyCodecs.ceilTo(1088, 16))
        assertEquals(1080, LegacyCodecs.ceilTo(1080, 1))
    }

    @Test
    fun configureSizeRoundsUpOnlyOnLegacy() {
        assertEquals(1088 to 1920, LegacyCodecs.configureSize(1080, 1920, 23, 2, 2))
        assertEquals(1088 to 1920, LegacyCodecs.configureSize(1080, 1920, 21, 16, 16))
        assertEquals(1080 to 1920, LegacyCodecs.configureSize(1080, 1920, 24, 2, 2))
        assertEquals(1920 to 1088, LegacyCodecs.configureSize(1920, 1080, 23, 2, 2))
        // A decoder that reports a coarser stride wins over the 16 px floor.
        assertEquals(1152 to 1920, LegacyCodecs.configureSize(1080, 1920, 23, 128, 16))
    }

    @Test
    fun legacyTuningSwitches() {
        assertFalse(LegacyCodecs.offerHevc(23))
        assertTrue(LegacyCodecs.offerHevc(24))
        assertFalse(LegacyCodecs.allowLowLatencyTuning(23))
        assertTrue(LegacyCodecs.allowLowLatencyTuning(24))
        assertFalse(LegacyCodecs.markSyncFrame(23))
        assertTrue(LegacyCodecs.markSyncFrame(24))
    }

    @Test
    fun legacyRateIsSustainable() {
        // 60 fps input on the Galaxy Tab 2 rendered at 8-18 fps with 300-800 ms
        // decode latency and ever-growing drops: advertise a rate it can hold.
        assertEquals(15, LegacyCodecs.targetFps(23))
        assertEquals(15, LegacyCodecs.targetFps(21))
        assertEquals(60, LegacyCodecs.targetFps(24))
        assertEquals(1, LegacyCodecs.backlogMultiplier(23))
    }

    @Test
    fun annexBJoinKeepsStartCodesAndOrder() {
        // The decoder input is built from the wire's NALUs; every one must
        // keep its 4-byte start code and the SPS/PPS must precede the IDR.
        val sps = byteArrayOf(0x67, 1)
        val pps = byteArrayOf(0x68, 2)
        val idr = byteArrayOf(0x65, 3)
        val payload = AnnexB.join(listOf(sps, pps, idr))
        assertArrayEquals(
            byteArrayOf(0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2, 0, 0, 0, 1, 0x65, 3),
            payload,
        )
    }
}
