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
    /** Parity with the iOS receiver: offer 60 even on 90/120 Hz panels. */
    private const val TARGET_FPS = 60

    fun videoCaps(panelWide: Int, panelHigh: Int): List<VideoCap> {
        val caps = mutableListOf<VideoCap>()
        envelope(Codec.H264, panelWide, panelHigh, requireHardware = false)?.let { caps.add(it) }
            ?: caps.add(VideoCap(Codec.H264, maxFrameRate = TARGET_FPS)) // every receiver offers H.264
        // Software HEVC cannot keep up with a desktop stream: hardware only.
        envelope(Codec.HEVC, panelWide, panelHigh, requireHardware = true)?.let { caps.add(it) }
        return caps
    }

    private fun envelope(codec: Codec, wide: Int, high: Int, requireHardware: Boolean): VideoCap? {
        val info = decoderFor(codec.mime, requireHardware) ?: return null
        val video = try {
            info.getCapabilitiesForType(codec.mime).videoCapabilities
        } catch (e: IllegalArgumentException) {
            null
        } ?: return null
        var w = wide
        var h = high
        while (w >= 320 && h >= 320) {
            val ew = w and 1.inv()
            val eh = h and 1.inv()
            if (video.isSizeSupported(ew, eh)) {
                val fps = try {
                    video.getSupportedFrameRatesFor(ew, eh).upper.toInt()
                } catch (_: IllegalArgumentException) {
                    0
                }
                if (fps >= 30) {
                    Log.i(TAG, "${codec.wire}: ${info.name} ${ew}x$eh up to $fps fps")
                    return VideoCap(codec, ew, eh, minOf(fps, TARGET_FPS))
                }
            }
            w = w * 9 / 10
            h = h * 9 / 10
        }
        Log.i(TAG, "${codec.wire}: ${info.name} supports nothing useful under ${wide}x$high")
        return null
    }

    private fun decoderFor(mime: String, requireHardware: Boolean): MediaCodecInfo? {
        val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
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
