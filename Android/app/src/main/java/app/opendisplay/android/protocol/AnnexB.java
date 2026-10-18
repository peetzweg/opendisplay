package app.opendisplay.android.protocol;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class AnnexB {
    private static final byte[] START_CODE = new byte[] {0, 0, 0, 1};

    private AnnexB() {}

    public static byte[] stripTelemetryPrefix(byte[] payload) {
        int start = firstStartCode(payload);
        if (start <= 0) {
            return payload;
        }
        return Arrays.copyOfRange(payload, start, payload.length);
    }

    public static String telemetryPrefix(byte[] payload) {
        int start = firstStartCode(payload);
        if (start <= 0) {
            return null;
        }
        return new String(payload, 0, start, StandardCharsets.UTF_8);
    }

    public static int firstStartCode(byte[] payload) {
        for (int i = 0; i + 4 <= payload.length; i++) {
            if (payload[i] == 0 && payload[i + 1] == 0
                    && payload[i + 2] == 0 && payload[i + 3] == 1) {
                return i;
            }
        }
        return -1;
    }

    public static List<byte[]> nalUnits(byte[] annexBPayload) {
        byte[] payload = stripTelemetryPrefix(annexBPayload);
        List<byte[]> units = new ArrayList<>();
        int start = -1;
        for (int i = 0; i + 4 <= payload.length; ) {
            if (payload[i] == 0 && payload[i + 1] == 0
                    && payload[i + 2] == 0 && payload[i + 3] == 1) {
                if (start >= 0 && start < i) {
                    units.add(Arrays.copyOfRange(payload, start, i));
                }
                start = i + 4;
                i += 4;
            } else {
                i++;
            }
        }
        if (start >= 0 && start < payload.length) {
            units.add(Arrays.copyOfRange(payload, start, payload.length));
        }
        return units;
    }

    public static byte[] findNalUnit(byte[] payload, int nalType) {
        for (byte[] unit : nalUnits(payload)) {
            if (unit.length > 0 && (unit[0] & 0x1F) == nalType) {
                return unit;
            }
        }
        return null;
    }

    public static byte[] withStartCode(byte[] nalu) {
        byte[] out = new byte[START_CODE.length + nalu.length];
        System.arraycopy(START_CODE, 0, out, 0, START_CODE.length);
        System.arraycopy(nalu, 0, out, START_CODE.length, nalu.length);
        return out;
    }
}
