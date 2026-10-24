package app.opendisplay.android.net

import app.opendisplay.android.protocol.Framing
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.DataInputStream

class PacketInputStreamTest {
    /** Replays [packets] one per read, recording the length asked for. */
    private class FakeEndpoint(packets: List<ByteArray>) {
        private val queue = ArrayDeque(packets)
        val asked = mutableListOf<Int>()
        fun read(b: ByteArray, off: Int, len: Int): Int {
            asked += len
            val packet = queue.removeFirstOrNull() ?: return -1
            System.arraycopy(packet, 0, b, off, packet.size)
            return packet.size
        }
    }

    @Test
    fun alwaysReadsWhole16KPackets() {
        val endpoint = FakeEndpoint(listOf(ByteArray(10) { it.toByte() }))
        val input = PacketInputStream(endpoint::read)
        val out = ByteArray(4)
        assertEquals(4, input.read(out, 0, 4))
        assertEquals(4, input.read(out, 0, 4))
        assertEquals(2, input.read(out, 0, 4))
        assertEquals(-1, input.read(out, 0, 4))
        assertEquals(listOf(16384, 16384), endpoint.asked)
    }

    @Test
    fun zeroLengthPacketIsNotEof() {
        val frame = Framing.encode("{\"type\":\"ping\"}".toByteArray())
        val endpoint = FakeEndpoint(listOf(frame.copyOfRange(0, 3), ByteArray(0), frame.copyOfRange(3, frame.size)))
        val input = DataInputStream(PacketInputStream(endpoint::read))
        assertEquals("{\"type\":\"ping\"}", String(Framing.readFrame(input)!!))
        assertNull(Framing.readFrame(input))
    }

    @Test
    fun reassemblesFramesSpanningPackets() {
        val big = ByteArray(40000) { (it % 251).toByte() }
        val stream = Framing.encode(byteArrayOf(1)) + byteArrayOf(0, 0, 0x9c.toByte(), 0x40) + big
        val packets = stream.toList().chunked(16384).map { it.toByteArray() }
        val input = DataInputStream(PacketInputStream(FakeEndpoint(packets)::read))
        assertArrayEquals(byteArrayOf(1), Framing.readFrame(input))
        assertArrayEquals(big, Framing.readFrame(input))
    }

    @Test
    fun endlessEmptyReadsEndTheStream() {
        val input = PacketInputStream { _, _, _ -> 0 }
        assertEquals(-1, input.read())
    }
}
