package app.opendisplay.android.protocol;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;

import org.junit.Test;

import app.opendisplay.android.ControlMessageWriter;
import app.opendisplay.android.ScrollGestureTracker;
import app.opendisplay.android.TouchGestureCoordinator;
import app.opendisplay.android.TouchEventMapper;

public final class ProtocolSelfTest {
    @Test
    public void protocolAndInputBehavior() throws Exception {
        runAll();
    }

    public static void main(String[] args) throws Exception {
        runAll();
        System.out.println("ProtocolSelfTest PASS");
    }

    private static void runAll() throws Exception {
        testLengthPrefixedRoundTrip();
        testLargeLengthPrefixedRoundTrip();
        testOversizedLengthIsRejectedBeforeAllocation();
        testJsonClassification();
        testAnnexBTelemetryAndNalus();
        testSpsParser();
        testTouchPointerIndexIsSafe();
        testScrollJson();
        testScrollGestureTrackerProducesPixelDeltas();
        testTouchGestureCoordinatorDefersTapUntilGestureIsKnown();
        testTouchGestureCoordinatorCancelsPendingTapForScroll();
        testControlMessageWriterDoesNotWriteOnCallerThread();
    }

    private static void testLengthPrefixedRoundTrip() throws Exception {
        byte[] encoded = LengthPrefixedProtocol.encode("hello".getBytes("UTF-8"));
        byte[] decoded = LengthPrefixedProtocol.read(new ByteArrayInputStream(encoded));
        assertEquals("hello", new String(decoded, "UTF-8"));
    }

    private static void testLargeLengthPrefixedRoundTrip() throws Exception {
        byte[] payload = new byte[(1 << 20) + 1];
        payload[payload.length - 1] = 0x65;
        byte[] decoded = LengthPrefixedProtocol.read(
                new ByteArrayInputStream(LengthPrefixedProtocol.encode(payload)));
        assertEquals(payload.length, decoded.length);
        assertEquals((byte) 0x65, decoded[decoded.length - 1]);
    }

    private static void testOversizedLengthIsRejectedBeforeAllocation() throws Exception {
        int length = LengthPrefixedProtocol.MAX_FRAME_BYTES + 1;
        byte[] header = new byte[] {
                (byte) (length >>> 24),
                (byte) (length >>> 16),
                (byte) (length >>> 8),
                (byte) length
        };
        try {
            LengthPrefixedProtocol.read(new ByteArrayInputStream(header));
            throw new AssertionError("expected oversized frame to be rejected");
        } catch (java.io.IOException expected) {
            assertTrue(expected.getMessage().contains("invalid OpenDisplay frame length"));
        }
    }

    private static void testJsonClassification() {
        assertTrue(LengthPrefixedProtocol.isPureJsonControl("{\"type\":\"ping\"}".getBytes()));
        assertFalse(LengthPrefixedProtocol.isPureJsonControl(new byte[] {'{', 0, 0, 0, 1, 0x65}));
    }

    private static void testAnnexBTelemetryAndNalus() throws Exception {
        byte[] prefix = "{\"cap\":1,\"snd\":2}".getBytes("UTF-8");
        byte[] frame = concat(prefix, new byte[] {0, 0, 0, 1, 0x67, 1, 2},
                new byte[] {0, 0, 0, 1, 0x68, 3, 4});
        assertEquals("{\"cap\":1,\"snd\":2}", AnnexB.telemetryPrefix(frame));
        assertEquals(2, AnnexB.nalUnits(frame).size());
        assertEquals(7, AnnexB.findNalUnit(frame, 7)[0] & 0x1F);
    }

    private static void testSpsParser() {
        byte[] sps = buildBaselineSps(1280, 720);
        SpsParser.Size size = SpsParser.parseDimensions(sps);
        assertEquals(1280, size.width);
        assertEquals(720, size.height);
    }

    private static void testTouchPointerIndexIsSafe() {
        assertEquals(0, TouchEventMapper.safePointerIndex(TouchEventMapper.ACTION_MOVE, 2, 1));
        assertEquals(1, TouchEventMapper.safePointerIndex(TouchEventMapper.ACTION_UP, 99, 2));
        assertEquals(-1, TouchEventMapper.safePointerIndex(TouchEventMapper.ACTION_DOWN, 0, 0));
        assertEquals("moved", TouchEventMapper.phaseForAction(TouchEventMapper.ACTION_MOVE));
        assertEquals("ended", TouchEventMapper.phaseForAction(TouchEventMapper.ACTION_POINTER_UP));
        assertEquals(null, TouchEventMapper.phaseForAction(99));
    }

    private static void testScrollJson() {
        assertEquals("{\"type\":\"scroll\",\"dx\":12.500,\"dy\":-4.250}",
                LengthPrefixedProtocol.scrollJson(12.5, -4.25));
    }

    private static void testScrollGestureTrackerProducesPixelDeltas() {
        ScrollGestureTracker tracker = new ScrollGestureTracker();
        assertFalse(tracker.isActive());
        tracker.begin(100, 200, 2.0);
        assertTrue(tracker.isActive());
        ScrollGestureTracker.Delta first = tracker.move(130, 220);
        assertEquals(15.0, first.dx);
        assertEquals(10.0, first.dy);
        ScrollGestureTracker.Delta second = tracker.move(150, 210);
        assertEquals(10.0, second.dx);
        assertEquals(-5.0, second.dy);
        tracker.end();
        assertFalse(tracker.isActive());
        assertEquals(null, tracker.move(200, 200));
    }

    private static void testTouchGestureCoordinatorDefersTapUntilGestureIsKnown() {
        TouchGestureCoordinator touch = new TouchGestureCoordinator(0.01);
        assertEquals(0, touch.begin(0.5, 0.5).size());
        assertEquals(0, touch.move(0.505, 0.5).size());
        List<TouchGestureCoordinator.Event> tap = touch.end(0.505, 0.5);
        assertEquals(2, tap.size());
        assertEquals("began", tap.get(0).phase);
        assertEquals("ended", tap.get(1).phase);

        assertEquals(0, touch.begin(0.2, 0.2).size());
        List<TouchGestureCoordinator.Event> drag = touch.move(0.25, 0.2);
        assertEquals(2, drag.size());
        assertEquals("began", drag.get(0).phase);
        assertEquals("moved", drag.get(1).phase);
    }

    private static void testTouchGestureCoordinatorCancelsPendingTapForScroll() {
        TouchGestureCoordinator touch = new TouchGestureCoordinator(0.01);
        touch.begin(0.5, 0.5);
        assertEquals(0, touch.cancel().size());
    }

    private static void testControlMessageWriterDoesNotWriteOnCallerThread() throws Exception {
        List<Runnable> queued = new ArrayList<>();
        ControlMessageWriter writer = new ControlMessageWriter(queued::add);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        writer.send(out, "{\"type\":\"touch\"}");
        assertEquals(0, out.size());
        assertEquals(1, queued.size());
        queued.get(0).run();
        byte[] decoded = LengthPrefixedProtocol.read(new ByteArrayInputStream(out.toByteArray()));
        assertEquals("{\"type\":\"touch\"}", new String(decoded, "UTF-8"));
    }

    private static byte[] buildBaselineSps(int width, int height) {
        BitWriter bits = new BitWriter();
        bits.writeByte(0x67);
        bits.writeByte(66);
        bits.writeByte(0);
        bits.writeByte(30);
        bits.writeUE(0);
        bits.writeUE(0);
        bits.writeUE(0);
        bits.writeUE(0);
        bits.writeUE(1);
        bits.writeBit(false);
        bits.writeUE(width / 16 - 1);
        bits.writeUE(height / 16 - 1);
        bits.writeBit(true);
        bits.writeBit(true);
        bits.writeBit(false);
        bits.writeBit(false);
        bits.writeBit(true);
        return bits.toByteArray();
    }

    private static byte[] concat(byte[]... chunks) {
        int len = 0;
        for (byte[] chunk : chunks) len += chunk.length;
        byte[] out = new byte[len];
        int offset = 0;
        for (byte[] chunk : chunks) {
            System.arraycopy(chunk, 0, out, offset, chunk.length);
            offset += chunk.length;
        }
        return out;
    }

    private static void assertTrue(boolean value) {
        if (!value) throw new AssertionError("expected true");
    }

    private static void assertFalse(boolean value) {
        if (value) throw new AssertionError("expected false");
    }

    private static void assertEquals(Object expected, Object actual) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError("expected " + expected + " but got " + actual);
        }
    }

    private static final class BitWriter {
        private final List<Boolean> bits = new ArrayList<>();

        void writeByte(int value) {
            for (int i = 7; i >= 0; i--) {
                writeBit(((value >> i) & 1) == 1);
            }
        }

        void writeBit(boolean bit) {
            bits.add(bit);
        }

        void writeUE(int value) {
            int codeNum = value + 1;
            int bitsRequired = 32 - Integer.numberOfLeadingZeros(codeNum);
            for (int i = 0; i < bitsRequired - 1; i++) writeBit(false);
            for (int i = bitsRequired - 1; i >= 0; i--) {
                writeBit(((codeNum >> i) & 1) == 1);
            }
        }

        byte[] toByteArray() {
            while (bits.size() % 8 != 0) bits.add(false);
            byte[] out = new byte[bits.size() / 8];
            for (int i = 0; i < bits.size(); i++) {
                if (bits.get(i)) {
                    out[i / 8] |= (byte) (1 << (7 - (i % 8)));
                }
            }
            return out;
        }
    }
}
