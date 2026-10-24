package app.opendisplay.android.protocol

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.IOException

private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

class FramingTest {
    @Test
    fun roundTripsAndReassemblesPackedFrames() {
        val a = Framing.encode("{\"type\":\"ping\"}".toByteArray())
        val b = Framing.encode(byteArrayOf(0, 0, 0, 1, 0x65))
        val input = DataInputStream(ByteArrayInputStream(a + b))
        assertEquals("{\"type\":\"ping\"}", String(Framing.readFrame(input)!!))
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x65), Framing.readFrame(input))
        assertNull(Framing.readFrame(input)) // clean EOF
    }

    @Test(expected = IOException::class)
    fun rejectsAbsurdLength() {
        Framing.readFrame(DataInputStream(ByteArrayInputStream(byteArrayOf(0x7f, -1, -1, -1))))
    }

    @Test(expected = IllegalArgumentException::class)
    fun outboundPayloadMustNotBeEmpty() {
        Framing.encode(ByteArray(0))
    }
}

class DemuxTest {
    @Test
    fun jsonIsControl() = assertTrue(Demux.isControl("{\"type\":\"pong\"}".toByteArray()))

    @Test
    fun videoWithTelemetryPrefixIsVideo() {
        // Starts with '{' but Annex B start codes guarantee a NUL byte.
        assertFalse(Demux.isControl("{\"cap\":1}".toByteArray() + byteArrayOf(0, 0, 0, 1, 0x65)))
    }

    @Test
    fun largeJsonIsVideo() {
        val big = ("{\"x\":\"" + "a".repeat(40000) + "\"}").toByteArray()
        assertFalse(Demux.isControl(big))
    }

    @Test
    fun bareAnnexBIsVideo() = assertFalse(Demux.isControl(byteArrayOf(0, 0, 0, 1, 0x67)))
}

class AnnexBTest {
    @Test
    fun parsesTelemetryAndNalus() {
        val frame = "{\"cap\":1700000000123,\"snd\":1700000000130}".toByteArray() +
            byteArrayOf(0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9)
        val unit = AnnexB.parse(frame)!!
        assertEquals(1700000000123.0, unit.captureMs!!, 0.0)
        assertEquals(1700000000130.0, unit.sendMs!!, 0.0)
        assertEquals(listOf(7, 8, 5), unit.nalus.map { AnnexB.nalType(Codec.H264, it) })
        assertArrayEquals(byteArrayOf(0x67, 1, 2), unit.nalus[0])
    }

    @Test
    fun toleratesMissingTelemetry() {
        val unit = AnnexB.parse(byteArrayOf(0, 0, 0, 1, 0x41, 7))!!
        assertNull(unit.captureMs)
        assertEquals(1, unit.nalus.size)
    }

    @Test
    fun noStartCodeIsNotVideo() = assertNull(AnnexB.parse(byteArrayOf(1, 2, 3, 4, 5)))

    @Test
    fun hevcTypes() {
        // VPS 32, SPS 33, PPS 34, IDR_N_LP 20, prefix SEI 39.
        val types = listOf(0x40, 0x42, 0x44, 0x28, 0x4e).map { AnnexB.nalType(Codec.HEVC, byteArrayOf(it.toByte(), 1)) }
        assertEquals(listOf(32, 33, 34, 20, 39), types)
        assertTrue(AnnexB.isParameterSet(Codec.HEVC, 33))
        assertTrue(AnnexB.isKeyframeSlice(Codec.HEVC, 20))
        assertTrue(AnnexB.isSkippable(Codec.HEVC, 39))
    }

    @Test
    fun joinUsesFourByteStartCodes() {
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x65, 0, 0, 0, 1, 0x41),
            AnnexB.join(listOf(byteArrayOf(0x65), byteArrayOf(0x41))))
    }

    @Test
    fun startCodeSearchFindsCodeAtEveryAlignment() {
        for (pad in 0..6) {
            val data = ByteArray(pad) { 7 } + byteArrayOf(0, 0, 0, 1, 9)
            assertEquals(pad, AnnexB.indexOfStartCode(data, 0))
        }
    }
}

class SpsParserTest {
    // Real x264 SPS NALUs (with cropping and emulation-prevention bytes).
    @Test
    fun baselinePortrait() = assertEquals(SpsParser.Size(1080, 2424),
        SpsParser.h264Size(hex("6742c032d900440131e5970110000003001000000303c0f1832480")))

    @Test
    fun highProfileCropped() = assertEquals(SpsParser.Size(1366, 768),
        SpsParser.h264Size(hex("67640020acd94056061e6f0110000003001000000303c0f1831960")))

    @Test
    fun mainLandscape() = assertEquals(SpsParser.Size(2424, 1080),
        SpsParser.h264Size(hex("674d4032eca0130044f2cb8088000003000800000301e078c18cb0")))

    @Test
    fun garbageIsNull() = assertNull(SpsParser.h264Size(byteArrayOf(0x67)))
}

class ClockSyncTest {
    @Test
    fun usesMinimumRttSample() {
        val c = ClockSync()
        c.addSample(t1 = 1000.0, mt = 6100.0, t2 = 1200.0) // rtt 200, offset 5000
        c.addSample(t1 = 2000.0, mt = 7010.0, t2 = 2020.0) // rtt 20, offset 5000
        c.addSample(t1 = 3000.0, mt = 8300.0, t2 = 3400.0) // rtt 400, offset 5100
        assertEquals(5000.0, c.offsetMs!!, 0.001)
        assertEquals(400.0, c.lastRttMs!!, 0.001)
        assertEquals(15000.0, c.senderNow(10000.0)!!, 0.001)
    }

    @Test
    fun discardsImplausibleSamples() {
        val c = ClockSync()
        c.addSample(1000.0, 5000.0, 900.0) // negative rtt
        c.addSample(1000.0, 5000.0, 3000.0) // rtt >= 2000
        assertNull(c.offsetMs)
        assertNull(c.senderNow(1.0))
    }
}

class CursorSequenceTest {
    @Test
    fun dropsStaleAndAcceptsUnsequenced() {
        val s = CursorSequence()
        assertTrue(s.accept(1))
        assertTrue(s.accept(5))
        assertFalse(s.accept(5))
        assertFalse(s.accept(3))
        assertTrue(s.accept(null)) // old sender, TCP without `s`
        s.reset()
        assertTrue(s.accept(1))
    }
}

class HelloTest {
    @Test
    fun carriesPanelCapsAndLegacyFields() {
        val hello = Messages.hello(
            Panel(1080, 2424, 2.625), "ID", "Android phone", 120,
            listOf(VideoCap(Codec.H264, 1080, 2424, 60), VideoCap(Codec.HEVC, 1080, 2424, 60)),
            cursorPort = 9001,
        )
        val json = JSONObject(hello.toString())
        assertEquals("hello", json.getString("type"))
        assertEquals(3, json.getInt("pv"))
        assertEquals(1080, json.getJSONObject("panel").getInt("pixelsWide"))
        assertEquals(2.625, json.getJSONObject("panel").getDouble("scale"), 0.0)
        assertEquals(2424, json.getInt("pixelsHigh"))
        assertEquals(1080, json.getInt("maxEncodeWide"))
        assertEquals("hevc", json.getJSONArray("videoCaps").getJSONObject(1).getString("codec"))
        assertEquals(9001, json.getInt("cursorPort"))
        assertFalse(json.has("power"))
        assertFalse(json.has("addrs"))
    }

    @Test
    fun omitsCursorPortWhenNotListening() {
        val hello = Messages.hello(Panel(800, 1280, 1.5), "ID", "Android tablet", 60,
            listOf(VideoCap(Codec.H264)), cursorPort = null)
        assertFalse(hello.has("cursorPort"))
        assertFalse(hello.has("maxEncodeWide"))
    }
}
