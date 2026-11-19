package app.opendisplay.android.video

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import app.opendisplay.android.Log
import app.opendisplay.android.protocol.Codec
import app.opendisplay.android.protocol.VideoCap

/**
 * What this device can decode, as `hello.videoCaps` (PROTOCOL.md 6.5). The
 * sender never streams larger than the panel, so each envelope is the panel
 * (current orientation) shrunk until the decoder claims it at frame rate.
 */
object DecoderCaps {
    /** iOS parity (60) on modern devices; old OMX gets a sustainable rate. */
    private fun targetFps(sdkInt: Int) = LegacyCodecs.targetFps(sdkInt)

    fun videoCaps(panelWide: Int, panelHigh: Int, sdkInt: Int = Build.VERSION.SDK_INT): List<VideoCap> {
        val caps = mutableListOf<VideoCap>()
        envelope(Codec.H264, panelWide, panelHigh, requireHardware = false, sdkInt)?.let { caps.add(it) }
            ?: caps.add(VideoCap(Codec.H264, maxFrameRate = targetFps(sdkInt))) // every receiver offers H.264
        // Software HEVC cannot keep up with a desktop stream: hardware only.
        // On Android 5/6 the advertised hardware HEVC decoder is often broken
        // (corrupt or green pictures), so don't offer it at all. The sender
        // then picks H.264, the codec other casting apps use on these devices.
        if (LegacyCodecs.offerHevc(sdkInt)) {
            envelope(Codec.HEVC, panelWide, panelHigh, requireHardware = true, sdkInt)?.let { caps.add(it) }
        } else {
            Log.i(TAG, "legacy OMX (API $sdkInt): H.264 only, 16-pixel aligned rasters, " +
                "${targetFps(sdkInt)} fps cap")
        }
        return caps
    }

    private fun envelope(
        codec: Codec,
        wide: Int,
        high: Int,
        requireHardware: Boolean,
        sdkInt: Int,
    ): VideoCap? {
        val info = decoderFor(codec.mime, requireHardware, sdkInt) ?: return null
        val video = try {
            info.getCapabilitiesForType(codec.mime).videoCapabilities
        } catch (e: IllegalArgumentException) {
            null
        } ?: return null
        // Old OMX components allocate their buffers from the configured raster,
        // so advertise (and later configure) a macroblock-aligned size. Modern
        // decoders keep the historical even-only behaviour.
        val (stepW, stepH) = LegacyCodecs.advertisedAlignments(
            sdkInt, video.widthAlignment, video.heightAlignment)
        var w = LegacyCodecs.floorTo(wide, stepW)
        var h = LegacyCodecs.floorTo(high, stepH)
        while (w >= 320 && h >= 320) {
            if (video.isSizeSupported(w, h)) {
                val fps = try {
                    video.getSupportedFrameRatesFor(w, h).upper.toInt()
                } catch (_: IllegalArgumentException) {
                    0
                }
                if (fps >= 30) {
                    Log.i(TAG, "${codec.wire}: ${info.name} ${w}x$h up to $fps fps")
                    return VideoCap(codec, w, h, minOf(fps, targetFps(sdkInt)))
                }
            }
            w = LegacyCodecs.floorTo(w * 9 / 10, stepW)
            h = LegacyCodecs.floorTo(h * 9 / 10, stepH)
        }
        Log.i(TAG, "${codec.wire}: ${info.name} supports nothing useful under ${wide}x$high")
        return null
    }

    private fun decoderFor(mime: String, requireHardware: Boolean, sdkInt: Int): MediaCodecInfo? {
        val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
        }
        // VideoDecoder picks the software decoder on these platforms: the
        // vendor one cannot decode the sender's High-profile stream cleanly.
        // Advertise the capabilities of the decoder we will actually use.
        if (LegacyCodecs.isLegacy(sdkInt)) {
            return infos.firstOrNull { !isHardware(it) } ?: infos.firstOrNull()
        }
        return infos.firstOrNull { isHardware(it) } ?: infos.firstOrNull().takeIf { !requireHardware }
    }

    fun isHardware(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= 29) return info.isHardwareAccelerated
        val name = info.name.lowercase()
        return !(name.startsWith("omx.google.") || name.startsWith("c2.android.") ||
            name.contains(".sw.") || name.startsWith("omx.ffmpeg"))
    }

    private const val TAG = "OpenDisplay"
}
