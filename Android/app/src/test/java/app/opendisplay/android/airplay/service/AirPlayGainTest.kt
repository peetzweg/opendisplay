package app.opendisplay.android.airplay.service

import org.junit.Assert.assertEquals
import org.junit.Test

class AirPlayGainTest {
    @Test
    fun dbToGainClampsToRange() {
        assertEquals(0f, AirPlayGain.dbToGain(-40f), 0f)
        assertEquals(0f, AirPlayGain.dbToGain(-30f), 0f)
        assertEquals(1f, AirPlayGain.dbToGain(0f), 0f)
        assertEquals(1f, AirPlayGain.dbToGain(6f), 0f)
    }

    @Test
    fun dbToGainIsLinearInRange() {
        assertEquals(0.5f, AirPlayGain.dbToGain(-15f), 0.0001f)
        assertEquals(0.75f, AirPlayGain.dbToGain(-7.5f), 0.0001f)
    }

    @Test
    fun gainToDbClampsSilenceAndUnity() {
        assertEquals(-144f, AirPlayGain.gainToDb(0f), 0f)
        assertEquals(-144f, AirPlayGain.gainToDb(0.001f), 0f)
        assertEquals(0f, AirPlayGain.gainToDb(1f), 0.0001f)
        assertEquals(0f, AirPlayGain.gainToDb(2f), 0.0001f)
    }

    @Test
    fun gainToDbUsesLinearAmplitudeDecibels() {
        // dbToGain is a UI-volume ramp, not the inverse of gainToDb.
        assertEquals(-1.94f, AirPlayGain.gainToDb(AirPlayGain.dbToGain(-6f)), 0.01f)
    }
}
