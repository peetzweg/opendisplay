package app.opendisplay.android.airplay.service

import kotlin.math.log10

/** Pure sender-volume conversions used by the RAOP volume callbacks. */
internal object AirPlayGain {
    fun dbToGain(db: Float): Float = when {
        db <= -30f -> 0f
        db >= 0f -> 1f
        else -> (db + 30f) / 30f
    }

    fun gainToDb(gain: Float): Float =
        if (gain <= 0.001f) -144f
        else (20.0 * log10(gain.toDouble())).toFloat().coerceIn(-30f, 0f)
}
