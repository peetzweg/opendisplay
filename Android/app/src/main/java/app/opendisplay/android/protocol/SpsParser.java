package app.opendisplay.android.protocol;

import java.util.Arrays;

public final class SpsParser {
    private SpsParser() {}

    public static Size parseDimensions(byte[] spsNalUnit) {
        if (spsNalUnit == null || spsNalUnit.length < 4) {
            return null;
        }
        byte[] rbsp = removeEmulationPrevention(Arrays.copyOfRange(spsNalUnit, 1, spsNalUnit.length));
        BitReader bits = new BitReader(rbsp);
        int profileIdc = bits.readBits(8);
        bits.readBits(8); // constraint flags + reserved bits
        bits.readBits(8); // level_idc
        bits.readUE();    // seq_parameter_set_id

        if (isHighProfile(profileIdc)) {
            int chromaFormatIdc = bits.readUE();
            if (chromaFormatIdc == 3) {
                bits.readBit();
            }
            bits.readUE();
            bits.readUE();
            bits.readBit();
            if (bits.readBit()) {
                int count = chromaFormatIdc != 3 ? 8 : 12;
                for (int i = 0; i < count; i++) {
                    if (bits.readBit()) {
                        skipScalingList(bits, i < 6 ? 16 : 64);
                    }
                }
            }
        }

        bits.readUE(); // log2_max_frame_num_minus4
        int picOrderCntType = bits.readUE();
        if (picOrderCntType == 0) {
            bits.readUE();
        } else if (picOrderCntType == 1) {
            bits.readBit();
            bits.readSE();
            bits.readSE();
            int cycle = bits.readUE();
            for (int i = 0; i < cycle; i++) {
                bits.readSE();
            }
        }

        bits.readUE(); // max_num_ref_frames
        bits.readBit(); // gaps_in_frame_num_value_allowed_flag
        int picWidthInMbsMinus1 = bits.readUE();
        int picHeightInMapUnitsMinus1 = bits.readUE();
        boolean frameMbsOnly = bits.readBit();
        if (!frameMbsOnly) {
            bits.readBit();
        }
        bits.readBit(); // direct_8x8_inference_flag

        int cropLeft = 0;
        int cropRight = 0;
        int cropTop = 0;
        int cropBottom = 0;
        if (bits.readBit()) {
            cropLeft = bits.readUE();
            cropRight = bits.readUE();
            cropTop = bits.readUE();
            cropBottom = bits.readUE();
        }

        int width = (picWidthInMbsMinus1 + 1) * 16;
        int height = (picHeightInMapUnitsMinus1 + 1) * 16 * (frameMbsOnly ? 1 : 2);
        width -= (cropLeft + cropRight) * 2;
        height -= (cropTop + cropBottom) * 2;
        return new Size(width, height);
    }

    private static boolean isHighProfile(int profileIdc) {
        switch (profileIdc) {
            case 100:
            case 110:
            case 122:
            case 244:
            case 44:
            case 83:
            case 86:
            case 118:
            case 128:
            case 138:
            case 144:
                return true;
            default:
                return false;
        }
    }

    private static void skipScalingList(BitReader bits, int size) {
        int lastScale = 8;
        int nextScale = 8;
        for (int j = 0; j < size; j++) {
            if (nextScale != 0) {
                int deltaScale = bits.readSE();
                nextScale = (lastScale + deltaScale + 256) % 256;
            }
            lastScale = nextScale == 0 ? lastScale : nextScale;
        }
    }

    private static byte[] removeEmulationPrevention(byte[] data) {
        byte[] tmp = new byte[data.length];
        int out = 0;
        for (int i = 0; i < data.length; i++) {
            if (i + 2 < data.length && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 3) {
                tmp[out++] = 0;
                tmp[out++] = 0;
                i += 2;
            } else {
                tmp[out++] = data[i];
            }
        }
        return Arrays.copyOf(tmp, out);
    }

    public static final class Size {
        public final int width;
        public final int height;

        public Size(int width, int height) {
            this.width = width;
            this.height = height;
        }
    }

    private static final class BitReader {
        private final byte[] data;
        private int bitOffset = 0;

        BitReader(byte[] data) {
            this.data = data;
        }

        boolean readBit() {
            return readBits(1) == 1;
        }

        int readBits(int count) {
            int value = 0;
            for (int i = 0; i < count; i++) {
                int byteIndex = bitOffset / 8;
                int shift = 7 - (bitOffset % 8);
                bitOffset++;
                value = (value << 1) | ((data[byteIndex] >> shift) & 1);
            }
            return value;
        }

        int readUE() {
            int zeros = 0;
            while (!readBit()) {
                zeros++;
            }
            int suffix = zeros == 0 ? 0 : readBits(zeros);
            return (1 << zeros) - 1 + suffix;
        }

        int readSE() {
            int codeNum = readUE();
            int sign = (codeNum & 1) == 0 ? -1 : 1;
            return sign * ((codeNum + 1) / 2);
        }
    }
}
