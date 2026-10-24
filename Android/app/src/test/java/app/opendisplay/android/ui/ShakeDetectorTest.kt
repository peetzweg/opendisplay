package app.opendisplay.android.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ShakeDetectorTest {
    // SensorManager is only touched in start(); the decision is pure.
    private fun detector() = ShakeDetector(android.app.Application()) {}

    @Test
    fun backAndForthIsAShake() {
        val d = detector()
        assertFalse(d.sample(3f, 1000))
        assertTrue(d.sample(3f, 1250))
    }

    @Test
    fun gentleMovementIsNot() {
        val d = detector()
        for (t in 0L..2000L step 100) assertFalse(d.sample(1.4f, t))
    }

    @Test
    fun oneSustainedJoltIsNot() {
        val d = detector()
        for (t in 1000L..1300L step 60) assertFalse(d.sample(3f, t))
    }

    @Test
    fun oneShakePerSecondAndAHalf() {
        val d = detector()
        d.sample(3f, 1000)
        assertTrue(d.sample(3f, 1200))
        assertFalse(d.sample(3f, 1400)) // still cooling down
        assertFalse(d.sample(3f, 2700)) // a new shake needs its own two jolts
        assertTrue(d.sample(3f, 2900))
    }
}
