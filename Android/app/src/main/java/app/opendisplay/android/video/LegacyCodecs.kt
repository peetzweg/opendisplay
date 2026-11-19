package app.opendisplay.android.video

/**
 * Compatibility rules for the vendor OMX decoders shipped with Android 5/6
 * (API 21-23), e.g. the Qualcomm components in CyanogenMod 13 / Android 6.0.1.
 *
 * Those decoders derive the output buffer geometry (stride, slice height) from
 * the width/height in the MediaFormat passed to configure(). H.264 always codes
 * a macroblock-aligned raster (16x16) and crops it to the visible size in the
 * SPS, so a stream whose *visible* width is not a multiple of 16 (1080, 1200,
 * 1536...) makes an old OMX component allocate a buffer that is narrower than
 * the raster it writes. Every row then shifts by a few pixels: diagonal
 * stripes, green edges and coloured blocks - 花屏. Modern decoders allocate
 * from the bitstream and report the crop in the output format instead, which
 * is why the same code is fine on recent Android.
 *
 * This receiver is the only one feeding such a raster to those decoders: the
 * Mac sender encodes the receiver's panel (even-aligned only, see
 * StreamConfiguration.even), while ordinary casting apps use the fixed
 * 1280x720 / 1920x1080 rasters that are already multiples of 16.
 *
 * Everything here is pure Kotlin so the JVM unit tests can cover it; the
 * Android callers pass Build.VERSION.SDK_INT in explicitly.
 */
object LegacyCodecs {
    /** Nougat (API 24) is where vendor OMX components stopped doing this. */
    const val LEGACY_MAX_SDK = 23

    /** H.264 macroblock size; the minimum safe raster alignment on old OMX. */
    const val MACROBLOCK = 16

    /**
     * A desktop stream at 60 fps is far beyond a 2012-era TI/Qualcomm OMX
     * decoder. Measured on a Galaxy Tab 2 (OMAP4 / DUCATI1), 60 fps input
     * rendered at 8-18 fps with ~300-800 ms decode latency and a rising drop
     * count: incomplete pictures (花屏) and wildly uneven frame spacing
     * (抖动). Advertise a rate the decoder can actually sustain.
     */
    const val LEGACY_TARGET_FPS = 15
    const val MODERN_TARGET_FPS = 60

    fun targetFps(sdkInt: Int): Int = if (isLegacy(sdkInt)) LEGACY_TARGET_FPS else MODERN_TARGET_FPS

    fun isLegacy(sdkInt: Int): Boolean = sdkInt <= LEGACY_MAX_SDK

    /** Old decoders need at least 16, even when VideoCapabilities says 2 or 4. */
    fun alignment(reported: Int): Int = maxOf(MACROBLOCK, reported.coerceAtLeast(1))

    fun floorTo(value: Int, step: Int): Int {
        val s = step.coerceAtLeast(1)
        return (value / s) * s
    }

    fun ceilTo(value: Int, step: Int): Int {
        val s = step.coerceAtLeast(1)
        return ((value + s - 1) / s) * s
    }

    /** Alignment steps to use when advertising hello.videoCaps. */
    fun advertisedAlignments(
        sdkInt: Int,
        widthAlignment: Int,
        heightAlignment: Int,
    ): Pair<Int, Int> = if (isLegacy(sdkInt)) {
        alignment(widthAlignment) to alignment(heightAlignment)
    } else {
        2 to 2 // keep the wire behaviour on modern devices unchanged
    }

    /** Raster to put in MediaFormat: roomy enough for old OMX buffer strides. */
    fun configureSize(
        visibleWidth: Int,
        visibleHeight: Int,
        sdkInt: Int,
        widthAlignment: Int,
        heightAlignment: Int,
    ): Pair<Int, Int> = if (isLegacy(sdkInt)) {
        ceilTo(visibleWidth, alignment(widthAlignment)) to
            ceilTo(visibleHeight, alignment(heightAlignment))
    } else {
        visibleWidth to visibleHeight
    }

    /**
     * Android 6-era HEVC decoders advertise themselves in MediaCodecList but
     * frequently output corrupted pictures for a VideoToolbox Main-profile
     * stream. Never offer HEVC there: the sender falls back to H.264.
     */
    fun offerHevc(sdkInt: Int): Boolean = !isLegacy(sdkInt)

    /** Realtime priority and vendor low-latency switches disable error concealment on old OMX. */
    fun allowLowLatencyTuning(sdkInt: Int): Boolean = !isLegacy(sdkInt)

    /** BUFFER_FLAG_KEY_FRAME is an encoder-side flag; some old decoders misread it. */
    fun markSyncFrame(sdkInt: Int): Boolean = !isLegacy(sdkInt)

    /** Don't deepen the queue on old decoders: backlog *is* their latency. */
    fun backlogMultiplier(sdkInt: Int): Int = 1
}
