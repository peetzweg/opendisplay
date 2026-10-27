package app.opendisplay.android.ui

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import app.opendisplay.android.Log
import kotlin.math.sqrt

/** Shake opens settings anytime, as on iOS. Two hard jolts within 600 ms. */
class ShakeDetector(context: Context, private val onShake: () -> Unit) : SensorEventListener {
    private val sensors by lazy { context.getSystemService(Context.SENSOR_SERVICE) as SensorManager }
    private var lastJolt = -10_000L
    private var lastShake = -10_000L

    fun start() {
        sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
            sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
        }
    }

    fun stop() = sensors.unregisterListener(this)

    override fun onSensorChanged(event: SensorEvent) {
        val (x, y, z) = Triple(event.values[0], event.values[1], event.values[2])
        val g = sqrt(x * x + y * y + z * z) / SensorManager.GRAVITY_EARTH
        if (sample(g, SystemClock.elapsedRealtime())) onShake()
    }

    /**
     * Pure decision, unit tested: a jolt is a sample above 2.5 g; two jolts
     * 80-700 ms apart (one back-and-forth) make a shake, at most one per 1.5 s.
     * Samples of one sustained jolt arrive closer than 80 ms and don't count.
     */
    internal fun sample(g: Float, now: Long): Boolean {
        if (g < 2.5f) return false
        val shake = now - lastJolt in 80..700 && now - lastShake > 1500
        if (shake) {
            lastShake = now
            Log.i("OpenDisplay", "shake: opening settings")
        }
        lastJolt = now
        return shake
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
