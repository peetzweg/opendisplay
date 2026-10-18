package app.opendisplay.android;

import android.content.Context;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.view.Surface;

import org.json.JSONObject;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

import app.opendisplay.android.protocol.AnnexB;
import app.opendisplay.android.protocol.SpsParser;

public final class H264SurfaceDecoder {
    private final Context context;
    private final Surface surface;
    private final Listener listener;
    private MediaCodec codec;
    private int configuredWidth;
    private int configuredHeight;
    private long presentationUs;
    private final Map<Long, FrameTelemetry> telemetryByPresentationUs = new HashMap<>();

    public static final class FrameTelemetry {
        public final double captureMs;
        public final double sendMs;

        private FrameTelemetry(double captureMs, double sendMs) {
            this.captureMs = captureMs;
            this.sendMs = sendMs;
        }
    }

    public interface Listener {
        void onDecoderStatus(String status);
        void onDecoderNeedsKeyframe();
        void onDecoderFrameRendered(FrameTelemetry telemetry);
    }

    public H264SurfaceDecoder(Context context, Surface surface, Listener listener) {
        this.context = context.getApplicationContext();
        this.surface = surface;
        this.listener = listener;
    }

    public synchronized void queueFrame(byte[] wirePayload) {
        FrameTelemetry telemetry = parseTelemetry(wirePayload);
        byte[] payload = AnnexB.stripTelemetryPrefix(wirePayload);
        byte[] sps = AnnexB.findNalUnit(payload, 7);
        byte[] pps = AnnexB.findNalUnit(payload, 8);
        if (codec == null) {
            if (sps == null) {
                listener.onDecoderNeedsKeyframe();
                return;
            }
            SpsParser.Size size = SpsParser.parseDimensions(sps);
            if (size == null) {
                listener.onDecoderStatus(context.getString(R.string.decoder_sps_failed));
                listener.onDecoderNeedsKeyframe();
                return;
            }
            try {
                configure(size.width, size.height, sps, pps);
            } catch (IOException | RuntimeException error) {
                listener.onDecoderStatus(context.getString(
                        R.string.decoder_start_failed, error.getMessage()));
                release();
                return;
            }
        }

        try {
            int input = codec.dequeueInputBuffer(0);
            if (input < 0) {
                drainOutput();
                input = codec.dequeueInputBuffer(0);
            }
            if (input < 0) {
                listener.onDecoderNeedsKeyframe();
                return;
            }
            java.nio.ByteBuffer buffer = codec.getInputBuffer(input);
            if (buffer == null || payload.length > buffer.capacity()) {
                listener.onDecoderStatus(context.getString(R.string.decoder_frame_too_large));
                listener.onDecoderNeedsKeyframe();
                return;
            }
            buffer.clear();
            buffer.put(payload);
            int flags = containsNalType(payload, 5) ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0;
            long framePresentationUs = presentationUs;
            codec.queueInputBuffer(input, 0, payload.length, framePresentationUs, flags);
            if (telemetry != null) {
                telemetryByPresentationUs.put(framePresentationUs, telemetry);
            }
            presentationUs += 16_666;
            drainOutput();
        } catch (IllegalStateException error) {
            listener.onDecoderStatus(context.getString(R.string.decoder_request_keyframe));
            release();
            listener.onDecoderNeedsKeyframe();
        }
    }

    public synchronized void release() {
        if (codec != null) {
            try {
                codec.stop();
            } catch (RuntimeException ignored) {
            }
            codec.release();
            codec = null;
        }
        telemetryByPresentationUs.clear();
    }

    private void configure(int width, int height, byte[] sps, byte[] pps) throws IOException {
        codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, Math.max(width * height, 1 << 20));
        format.setInteger(MediaFormat.KEY_PRIORITY, 0);
        if (android.os.Build.VERSION.SDK_INT >= 31) {
            format.setInteger(MediaFormat.KEY_ALLOW_FRAME_DROP, 1);
        }
        if (sps != null) {
            format.setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(AnnexB.withStartCode(sps)));
        }
        if (pps != null) {
            format.setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(AnnexB.withStartCode(pps)));
        }
        codec.configure(format, surface, null, 0);
        codec.start();
        configuredWidth = width;
        configuredHeight = height;
        presentationUs = 0;
        listener.onDecoderStatus(context.getString(
                R.string.status_receiving_resolution, configuredWidth, configuredHeight));
    }

    private void drainOutput() {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        while (true) {
            int output = codec.dequeueOutputBuffer(info, 0);
            if (output >= 0) {
                codec.releaseOutputBuffer(output, true);
                listener.onDecoderFrameRendered(
                        telemetryByPresentationUs.remove(info.presentationTimeUs));
            } else if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                MediaFormat format = codec.getOutputFormat();
                configuredWidth = format.getInteger(MediaFormat.KEY_WIDTH);
                configuredHeight = format.getInteger(MediaFormat.KEY_HEIGHT);
                listener.onDecoderStatus(context.getString(
                        R.string.status_receiving_resolution, configuredWidth, configuredHeight));
            } else {
                return;
            }
        }
    }

    private static boolean containsNalType(byte[] payload, int type) {
        for (byte[] unit : AnnexB.nalUnits(payload)) {
            if (unit.length > 0 && (unit[0] & 0x1F) == type) {
                return true;
            }
        }
        return false;
    }

    private static FrameTelemetry parseTelemetry(byte[] payload) {
        String prefix = AnnexB.telemetryPrefix(payload);
        if (prefix == null) {
            return null;
        }
        try {
            JSONObject object = new JSONObject(prefix);
            double captureMs = object.optDouble("cap", Double.NaN);
            double sendMs = object.optDouble("snd", Double.NaN);
            if (Double.isFinite(captureMs) && Double.isFinite(sendMs)) {
                return new FrameTelemetry(captureMs, sendMs);
            }
        } catch (Exception ignored) {
        }
        return null;
    }
}
