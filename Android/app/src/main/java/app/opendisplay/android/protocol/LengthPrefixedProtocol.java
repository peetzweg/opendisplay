package app.opendisplay.android.protocol;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.Map;

public final class LengthPrefixedProtocol {
    public static final int MAX_FRAME_BYTES = 1 << 20;

    private LengthPrefixedProtocol() {}

    public static byte[] encode(byte[] payload) {
        ByteBuffer buffer = ByteBuffer.allocate(4 + payload.length).order(ByteOrder.BIG_ENDIAN);
        buffer.putInt(payload.length);
        buffer.put(payload);
        return buffer.array();
    }

    public static void write(OutputStream out, byte[] payload) throws IOException {
        out.write(encode(payload));
        out.flush();
    }

    public static byte[] read(InputStream in) throws IOException {
        byte[] header = readExact(in, 4);
        int length = ByteBuffer.wrap(header).order(ByteOrder.BIG_ENDIAN).getInt();
        if (length <= 0 || length > MAX_FRAME_BYTES) {
            throw new IOException("invalid OpenDisplay frame length: " + length);
        }
        return readExact(in, length);
    }

    public static byte[] readExact(InputStream in, int length) throws IOException {
        byte[] data = new byte[length];
        int offset = 0;
        while (offset < length) {
            int n = in.read(data, offset, length - offset);
            if (n < 0) {
                throw new EOFException("stream ended after " + offset + " of " + length + " bytes");
            }
            offset += n;
        }
        return data;
    }

    public static boolean isPureJsonControl(byte[] payload) {
        if (payload.length == 0 || payload.length >= 32_768 || payload[0] != '{') {
            return false;
        }
        for (byte b : payload) {
            if (b == 0) {
                return false;
            }
        }
        return true;
    }

    public static byte[] jsonBytes(String json) {
        return json.getBytes(StandardCharsets.UTF_8);
    }

    public static String helloJson(int pixelsWide, int pixelsHigh, double scale,
                                   String device, String installId) {
        return String.format(Locale.US,
                "{\"type\":\"hello\",\"pixelsWide\":%d,\"pixelsHigh\":%d,\"scale\":%.3f,\"device\":\"%s\",\"id\":\"%s\"}",
                pixelsWide, pixelsHigh, scale, escape(device), escape(installId));
    }

    public static String touchJson(String phase, double x, double y, Double macClockMs) {
        String base = String.format(Locale.US,
                "{\"type\":\"touch\",\"phase\":\"%s\",\"x\":%.6f,\"y\":%.6f",
                escape(phase), clamp01(x), clamp01(y));
        if (macClockMs != null) {
            base += String.format(Locale.US, ",\"t\":%.3f", macClockMs);
        }
        return base + "}";
    }

    public static String pingJson(double nowMs) {
        return String.format(Locale.US, "{\"type\":\"ping\",\"t\":%.3f}", nowMs);
    }

    public static String pongJson(double receiverTimeMs, double macTimeMs) {
        return String.format(Locale.US, "{\"type\":\"pong\",\"t\":%.3f,\"mt\":%.3f}",
                receiverTimeMs, macTimeMs);
    }

    public static String keyframeRequestJson() {
        return "{\"type\":\"kf\"}";
    }

    public static String scrollJson(double dx, double dy) {
        return String.format(Locale.US, "{\"type\":\"scroll\",\"dx\":%.3f,\"dy\":%.3f}", dx, dy);
    }

    public static String statsJson(Map<String, Object> values) {
        StringBuilder out = new StringBuilder("{\"type\":\"stats\"");
        for (Map.Entry<String, Object> entry : values.entrySet()) {
            out.append(",\"").append(escape(entry.getKey())).append("\":");
            Object value = entry.getValue();
            if (value instanceof Number || value instanceof Boolean) {
                out.append(value);
            } else {
                out.append("\"").append(escape(String.valueOf(value))).append("\"");
            }
        }
        return out.append("}").toString();
    }

    public static double nowMs() {
        return System.currentTimeMillis();
    }

    private static double clamp01(double value) {
        return Math.max(0.0, Math.min(1.0, value));
    }

    private static String escape(String text) {
        return text.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
