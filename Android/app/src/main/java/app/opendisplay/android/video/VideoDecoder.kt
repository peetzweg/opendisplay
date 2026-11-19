package app.opendisplay.android.video

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
import app.opendisplay.android.Log
import android.view.Surface
import app.opendisplay.android.protocol.AccessUnit
import app.opendisplay.android.protocol.AnnexB
import app.opendisplay.android.protocol.Codec
import app.opendisplay.android.protocol.SpsParser
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit

/**
 * Hardware decode of the Annex B stream (PROTOCOL.md 5) straight to a
 * Surface. All MediaCodec lifecycle runs on one input thread; a per-codec
 * output thread renders each picture as soon as it is decoded (no
 * presentation timestamps cross the wire, frames show in arrival order).
 */
class VideoDecoder(private val callbacks: Callbacks) {
    interface Callbacks {
        fun requestKeyframe()
        /** Visible picture size, from the decoder's output format. */
        fun onVideoSize(width: Int, height: Int)
        /** [receivedNanos] when the frame left the socket, [captureMs] sender telemetry. */
        fun onFrameRendered(receivedNanos: Long, captureMs: Double?)
        fun onDecoderError(message: String)
    }

    private sealed class Work {
        class Frame(val unit: AccessUnit, val receivedNanos: Long) : Work()
        class SetSurface(val surface: Surface?, val done: CountDownLatch?) : Work()
        class SetStream(val codec: Codec, val width: Int, val height: Int) : Work()
        object Reset : Work()
        class Fail(val failed: MediaCodec) : Work()
        object Quit : Work()
    }

    private val queue = LinkedBlockingDeque<Work>()
    private val thread = Thread(::inputLoop, "od-decode-in").apply { isDaemon = true }

    // Input-thread state.
    private var surface: Surface? = null
    private var codec = Codec.H264
    private var announcedWidth = 0
    private var announcedHeight = 0
    private var decoder: MediaCodec? = null
    private var output: OutputDrain? = null
    private var parameterSets: List<ByteArray> = emptyList()
    private var awaitingKeyframe = true
    private var lastKeyframeRequest = 0L
    /**
     * A created-but-unconfigured decoder for the expected codec. Creating a
     * MediaCodec costs a few hundred ms; doing it before the first IDR keeps
     * that frame (and the ones queued behind it) from going stale.
     */
    private var spare: MediaCodec? = null

    /** Telemetry for frames inside the decoder, keyed by presentation time. */
    private val inFlight = ConcurrentHashMap<Long, Pair<Long, Double?>>()

    @Volatile var codecName: String? = null
        private set

    @Volatile var droppedFrames = 0
        private set

    /**
     * True once the current decoder has put out a picture. Until then the
     * frames queued while it was created are expected, not a backlog.
     */
    @Volatile private var decoderLive = false

    /** Raised when a frame overflowed the decoder's input buffers (some OMX caps). */
    private var minInputSize = 2 shl 20

    fun start() = thread.start()

    fun setSurface(surface: Surface?) = queue.put(Work.SetSurface(surface, null))

    /**
     * The surface is about to be destroyed: stop rendering into it before
     * returning, since some vendor codecs fault on a vanished surface.
     */
    fun detachSurface() {
        val done = CountDownLatch(1)
        queue.offerFirst(Work.SetSurface(null, done))
        done.await(500, TimeUnit.MILLISECONDS)
    }

    /** From `streamConfig`: the codec to expect and the announced raster. */
    fun setStream(codec: Codec, width: Int, height: Int) = queue.put(Work.SetStream(codec, width, height))

    /** New session: forget the old stream entirely (pending commands stay). */
    fun reset() {
        queue.removeAll { it is Work.Frame }
        queue.put(Work.Reset)
    }

    fun submit(unit: AccessUnit) = queue.put(Work.Frame(unit, SystemClock.elapsedRealtimeNanos()))

    fun release() {
        queue.removeAll { it is Work.Frame }
        queue.put(Work.Quit)
    }

    // region Input thread

    private fun inputLoop() {
        while (true) {
            when (val work = queue.take()) {
                is Work.Frame -> if (!skipBacklog(work)) handleFrame(work)
                is Work.SetSurface -> {
                    teardown()
                    surface = work.surface
                    awaitingKeyframe = true
                    if (surface != null) {
                        prewarm()
                        requestKeyframe(force = true)
                    }
                    work.done?.countDown()
                }
                is Work.SetStream -> {
                    if (work.codec != codec) {
                        teardown()
                        parameterSets = emptyList()
                        awaitingKeyframe = true
                    }
                    codec = work.codec
                    announcedWidth = work.width
                    announcedHeight = work.height
                    prewarm()
                }
                Work.Reset -> {
                    teardown()
                    codec = Codec.H264 // a sender without streamConfig is legacy H.264
                    announcedWidth = 0
                    announcedHeight = 0
                    parameterSets = emptyList()
                    awaitingKeyframe = true
                    inFlight.clear()
                    prewarm()
                }
                // A Fail from a decoder already replaced must not kill its successor.
                is Work.Fail -> if (work.failed === decoder) fail("output", null)
                Work.Quit -> {
                    teardown()
                    spare?.release()
                    spare = null
                    return
                }
            }
        }
    }

    /**
     * Falling behind adds latency to every later frame, so a backlog is cut
     * rather than decoded. If a keyframe is queued, skip to it for free;
     * otherwise drop everything and ask for one. While a decoder is still
     * being created the queue fills by design, hence the higher limit.
     * Returns true when [work] itself was dropped.
     */
    private fun skipBacklog(work: Work.Frame): Boolean {
        // Old OMX decoders conceal missing reference frames badly (coloured
        // blocks), so allow a deeper queue there instead of cutting to a new
        // keyframe as eagerly as on modern decoders.
        val limit = if (!decoderLive) MAX_STARTUP_BACKLOG
        else MAX_BACKLOG * LegacyCodecs.backlogMultiplier(Build.VERSION.SDK_INT)
        val pending = queue.filterIsInstance<Work.Frame>()
        if (pending.size <= limit) return false
        val lastKey = pending.indexOfLast { isKeyframe(it.unit) }
        val drop = if (lastKey >= 0) pending.subList(0, lastKey) else pending
        drop.forEach { queue.remove(it) }
        droppedFrames += drop.size + 1
        Log.i(TAG, "decode backlog: dropped ${drop.size + 1} frames" +
            if (lastKey >= 0) ", resuming at a queued keyframe" else "")
        if (lastKey < 0) {
            awaitingKeyframe = true
            requestKeyframe(force = true)
        }
        return true
    }

    private fun isKeyframe(unit: AccessUnit) =
        unit.nalus.any { AnnexB.isKeyframeSlice(codec, AnnexB.nalType(codec, it)) }

    private fun handleFrame(work: Work.Frame) {
        val params = ArrayList<ByteArray>(3)
        val slices = ArrayList<ByteArray>(work.unit.nalus.size)
        var keyframe = false
        for (nalu in work.unit.nalus) {
            val type = AnnexB.nalType(codec, nalu)
            when {
                AnnexB.isParameterSet(codec, type) -> params.add(nalu)
                AnnexB.isSkippable(codec, type) -> Unit
                else -> {
                    if (AnnexB.isKeyframeSlice(codec, type)) keyframe = true
                    slices.add(nalu)
                }
            }
        }
        // 5.2: a parameter-set change means a new stream; rebuild the decoder.
        if (params.isNotEmpty() && !sameParameterSets(params, parameterSets)) {
            teardown()
            parameterSets = params
        }
        val surface = surface ?: return
        if (decoder == null) {
            if (!keyframe || parameterSets.isEmpty()) {
                requestKeyframe()
                droppedFrames++
                return
            }
            if (!configure(surface)) return
        }
        if (awaitingKeyframe) {
            if (!keyframe) {
                requestKeyframe()
                droppedFrames++
                return
            }
            awaitingKeyframe = false
        }
        if (slices.isEmpty()) return
        // Keep the original csd-only setup. Feeding SPS/PPS in-band made old
        // OMX components lose their decoder state; they are already in csd-0/1.
        queueInput(AnnexB.join(slices), keyframe, work)
    }

    private fun queueInput(data: ByteArray, keyframe: Boolean, work: Work.Frame) {
        val codec = decoder ?: return
        try {
            val index = codec.dequeueInputBuffer(INPUT_TIMEOUT_US)
            if (index < 0) {
                // The decoder is full: this frame is lost, and so are the
                // frames that reference it, until the next keyframe.
                droppedFrames++
                awaitingKeyframe = true
                requestKeyframe()
                return
            }
            val buffer: ByteBuffer = inputBuffer(codec, index)
            buffer.clear()
            if (data.size > buffer.capacity()) {
                // The next keyframe is just as big: rebuild with room for it,
                // or this repeats forever.
                Log.w(TAG, "frame of ${data.size} B exceeds input buffer ${buffer.capacity()} B; rebuilding")
                codec.queueInputBuffer(index, 0, 0, 0, 0)
                droppedFrames++
                minInputSize = maxOf(minInputSize, data.size * 3 / 2)
                teardown()
                awaitingKeyframe = true
                requestKeyframe(force = true)
                return
            }
            buffer.put(data)
            val pts = work.receivedNanos / 1000
            inFlight[pts] = work.receivedNanos to work.unit.captureMs
            if (inFlight.size > 256) inFlight.clear()
            // BUFFER_FLAG_KEY_FRAME is an encoder-side flag. Some pre-Nougat
            // OMX decoders misread it on an input buffer; they find the IDR in
            // the Annex B stream anyway.
            val flags = if (keyframe && LegacyCodecs.markSyncFrame(Build.VERSION.SDK_INT))
                MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
            codec.queueInputBuffer(index, 0, data.size, pts, flags)
        } catch (e: IllegalStateException) {
            fail("queue input", e)
        }
    }

    private fun inputBuffer(codec: MediaCodec, index: Int): ByteBuffer = codec.getInputBuffer(index)!!

    private fun configure(surface: Surface): Boolean {
        val created = try {
            takeSpare() ?: createDecoder()
        } catch (e: Exception) {
            callbacks.onDecoderError("No ${codec.wire.uppercase()} decoder: ${e.message}")
            return false
        }
        val sdkInt = Build.VERSION.SDK_INT
        val legacy = LegacyCodecs.isLegacy(sdkInt)
        val (visibleWidth, visibleHeight) = configureSize()
        val (widthAlignment, heightAlignment) = codecAlignments(created)
        // Pre-Nougat OMX derives its output stride from KEY_WIDTH/KEY_HEIGHT.
        // Give it a macroblock-aligned raster; the visible size still comes
        // from the SPS, and from the decoder's crop keys once frames flow.
        val (width, height) = LegacyCodecs.configureSize(
            visibleWidth, visibleHeight, sdkInt, widthAlignment, heightAlignment)
        val format = MediaFormat.createVideoFormat(codec.mime, width, height)
        when (codec) {
            Codec.H264 -> {
                parameterSets.firstOrNull { AnnexB.nalType(codec, it) == 7 }?.let {
                    format.setByteBuffer("csd-0", ByteBuffer.wrap(AnnexB.join(listOf(it))))
                }
                parameterSets.firstOrNull { AnnexB.nalType(codec, it) == 8 }?.let {
                    format.setByteBuffer("csd-1", ByteBuffer.wrap(AnnexB.join(listOf(it))))
                }
            }
            // HEVC takes VPS + SPS + PPS together in csd-0.
            Codec.HEVC -> format.setByteBuffer("csd-0", ByteBuffer.wrap(AnnexB.join(parameterSets)))
        }
        // Size the input buffers for a keyframe of the largest raster.
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(width * height, minInputSize))
        // Realtime priority and vendor low-latency switches make old OMX
        // components skip error concealment and emit incomplete reference
        // frames as colour blocks. Modern decoders keep the tuning.
        if (!legacy) {
            if (sdkInt >= 23) {
                format.setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
            }
            // Vendor low-latency switches; unknown keys are ignored by the codec.
            format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            format.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
            format.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1)
            format.setInteger("vendor.low-latency.enable", 1)
            if (sdkInt >= 30) {
                val supportsLowLatency = try {
                    created.codecInfo.getCapabilitiesForType(codec.mime)
                        .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
                } catch (_: Exception) {
                    false
                }
                if (supportsLowLatency) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
        }
        return try {
            created.configure(format, surface, null, 0)
            created.start()
            decoder = created
            codecName = created.name
            output = OutputDrain(created, visibleWidth, visibleHeight).also { it.start() }
            Log.i(TAG, "decoder ${created.name} configured: ${codec.wire} ${width}x$height" +
                if (legacy) " (legacy: visible ${visibleWidth}x$visibleHeight, csd-only parameter sets)" else "")
            true
        } catch (e: Exception) {
            created.release()
            callbacks.onDecoderError("Decoder setup failed: ${e.message}")
            Log.w(TAG, "configure failed", e)
            false
        }
    }

    /**
     * TI's DUCATI1 decoder on CM13 corrupts H.264 High-profile streams: the
     * smooth-gradient macroblocks come out as pink/green blocks while detailed
     * areas look fine. The Mac sender always encodes High profile, so on old
     * platforms use the platform's software H.264 decoder instead. At the
     * reduced legacy frame rate it keeps up and produces a clean picture.
     */
    private fun createDecoder(): MediaCodec {
        if (LegacyCodecs.isLegacy(Build.VERSION.SDK_INT)) {
            val name = try {
                MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
                    !info.isEncoder && info.name.startsWith("OMX.google.", ignoreCase = true) &&
                        info.supportedTypes.any { it.equals(codec.mime, ignoreCase = true) }
                }?.name
            } catch (_: Exception) {
                null
            }
            if (name != null) return MediaCodec.createByCodecName(name)
        }
        return MediaCodec.createDecoderByType(codec.mime)
    }

    /** The decoder's own buffer alignment, when it reports one. */
    private fun codecAlignments(mc: MediaCodec): Pair<Int, Int> = try {
        val video = mc.codecInfo.getCapabilitiesForType(codec.mime).videoCapabilities
        if (video == null) 1 to 1 else video.widthAlignment to video.heightAlignment
    } catch (_: Exception) {
        1 to 1
    }

    /** streamConfig is authoritative for the codec; the SPS for the picture. */
    private fun configureSize(): Pair<Int, Int> {
        if (codec == Codec.H264) {
            parameterSets.firstOrNull { AnnexB.nalType(codec, it) == 7 }
                ?.let { SpsParser.h264Size(it) }
                ?.let { return it.width to it.height }
        }
        if (announcedWidth > 0 && announcedHeight > 0) return announcedWidth to announcedHeight
        return 1920 to 1080
    }

    private fun prewarm() {
        if (surface == null || decoder != null) return
        if (spare?.codecInfo?.supportedTypes?.any { it.equals(codec.mime, true) } == true) return
        spare?.release()
        spare = try {
            createDecoder()
        } catch (e: Exception) {
            null
        }
    }

    private fun takeSpare(): MediaCodec? {
        val s = spare ?: return null
        spare = null
        if (s.codecInfo.supportedTypes.any { it.equals(codec.mime, true) }) return s
        s.release()
        return null
    }

    private fun sameParameterSets(a: List<ByteArray>, b: List<ByteArray>): Boolean =
        a.size == b.size && a.indices.all { a[it].contentEquals(b[it]) }

    private fun fail(where: String, e: Exception?) {
        Log.w(TAG, "decoder failed in $where", e)
        teardown()
        awaitingKeyframe = true
        requestKeyframe(force = true)
    }

    private fun teardown() {
        output?.stopAndJoin()
        output = null
        decoder?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        decoder = null
        decoderLive = false
        codecName = null
    }

    private fun requestKeyframe(force: Boolean = false) {
        val now = SystemClock.elapsedRealtime()
        // A real recovery (teardown, lost decoder, surface change) must not be
        // delayed. Only the ordinary "input buffer full" nags are rate limited:
        // an overloaded decoder otherwise asks for an IDR every few hundred
        // milliseconds, and the sender's bigger IDRs make it worse.
        if (!force && now - lastKeyframeRequest < KEYFRAME_REQUEST_INTERVAL_MS) return
        lastKeyframeRequest = now
        callbacks.requestKeyframe()
    }

    // endregion

    /** Renders decoded pictures the moment they come out. */
    private inner class OutputDrain(
        private val codec: MediaCodec,
        private val visibleWidth: Int,
        private val visibleHeight: Int,
    ) {
        @Volatile private var running = true
        private val thread = Thread(::loop, "od-decode-out").apply { isDaemon = true }

        fun start() = thread.start()

        fun stopAndJoin() {
            running = false
            thread.join(500)
        }

        @Suppress("DEPRECATION") // INFO_OUTPUT_BUFFERS_CHANGED is only emitted by old OMX codecs
        private fun loop() {
            val info = MediaCodec.BufferInfo()
            while (running) {
                val index = try {
                    codec.dequeueOutputBuffer(info, OUTPUT_TIMEOUT_US)
                } catch (e: IllegalStateException) {
                    failed(e)
                    return
                }
                when {
                    index >= 0 -> {
                        try {
                            codec.releaseOutputBuffer(index, true)
                        } catch (e: IllegalStateException) {
                            failed(e)
                            return
                        }
                        decoderLive = true
                        val meta = inFlight.remove(info.presentationTimeUs)
                        if (meta != null) callbacks.onFrameRendered(meta.first, meta.second)
                    }
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> reportSize(codec.outputFormat)
                    // Pre-LOLLIPOP-style OMX components expect the client to
                    // pick up the new output buffer array before draining on.
                    index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> refreshOutputBuffers()
                    index == MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                }
            }
        }

        @Suppress("DEPRECATION")
        private fun refreshOutputBuffers() {
            codec.outputBuffers
        }

        /** Nothing drains this codec any more: have the input thread rebuild it. */
        private fun failed(e: Exception) {
            if (!running) return
            Log.w(TAG, "decoder output failed", e)
            queue.offerFirst(Work.Fail(codec))
        }

        private fun reportSize(format: MediaFormat) {
            var width = format.getInteger(MediaFormat.KEY_WIDTH)
            var height = format.getInteger(MediaFormat.KEY_HEIGHT)
            if (format.containsKey("crop-right") && format.containsKey("crop-left")) {
                width = format.getInteger("crop-right") - format.getInteger("crop-left") + 1
            }
            if (format.containsKey("crop-bottom") && format.containsKey("crop-top")) {
                height = format.getInteger("crop-bottom") - format.getInteger("crop-top") + 1
            }
            // On legacy decoders the configured raster was rounded up only to
            // size their buffers. If the component reports no crop rectangle,
            // the SPS's visible size is the truth for layout and input mapping.
            if (LegacyCodecs.isLegacy(Build.VERSION.SDK_INT) && visibleWidth > 0 && visibleHeight > 0 &&
                !format.containsKey("crop-left") && !format.containsKey("crop-right") &&
                !format.containsKey("crop-top") && !format.containsKey("crop-bottom")) {
                width = visibleWidth
                height = visibleHeight
            }
            Log.i(TAG, "decoder output ${width}x$height")
            callbacks.onVideoSize(width, height)
        }
    }

    private companion object {
        const val TAG = "OpenDisplay"
        const val MAX_BACKLOG = 6
        const val MAX_STARTUP_BACKLOG = 90
        const val INPUT_TIMEOUT_US = 20_000L
        val OUTPUT_TIMEOUT_US = TimeUnit.MILLISECONDS.toMicros(10)
        const val KEYFRAME_REQUEST_INTERVAL_MS = 1000L
    }
}
