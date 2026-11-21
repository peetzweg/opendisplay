package app.opendisplay.android.airplay.renderer

/**
 * Mirrors the native AudioConfig struct. ALAC is forced through FFmpeg because
 * hardware ALAC decoders are effectively absent on Android phones/tablets.
 */
data class AudioConfig(
    val cushionMs: Int = 0,
    val percentilePct: Int = 95,
    val oboeBufferFrames: Int = 0,
    val forceSwAlac: Boolean = true,
    val forceSwAac: Boolean = false,
    val realtimePriority: Boolean = true,
    val lowLatency: Boolean = false,
    val benchmarkLog: Boolean = false,
)
