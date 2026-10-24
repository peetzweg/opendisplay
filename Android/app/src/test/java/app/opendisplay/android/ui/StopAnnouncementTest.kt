package app.opendisplay.android.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class StopAnnouncementTest {
    private fun announce(finishing: Boolean = false, onAccessory: Boolean = false,
                         interactive: Boolean = true, keyguardLocked: Boolean = false) =
        MainActivity.stopAnnouncement(finishing, onAccessory, interactive, keyguardLocked)

    @Test
    fun tcpSleepsWhetherLeftOrLocked() {
        assertEquals("sleeping", announce())
        assertEquals("sleeping", announce(interactive = false))
    }

    @Test
    fun finishingAlwaysCloses() {
        assertEquals("closing", announce(finishing = true))
        assertEquals("closing", announce(finishing = true, onAccessory = true, interactive = false))
    }

    @Test
    fun accessoryLeftWithScreenOnCloses() = assertEquals("closing", announce(onAccessory = true))

    @Test
    fun accessoryLockedOrScreenOffSleeps() {
        assertEquals("sleeping", announce(onAccessory = true, keyguardLocked = true))
        assertEquals("sleeping", announce(onAccessory = true, interactive = false))
        assertEquals("sleeping", announce(onAccessory = true, interactive = false, keyguardLocked = true))
    }
}
