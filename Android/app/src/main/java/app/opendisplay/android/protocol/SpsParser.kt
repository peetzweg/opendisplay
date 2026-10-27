package app.opendisplay.android.protocol

/**
 * Picture size from an H.264 SPS (PROTOCOL.md 5.2: video dimensions come from
 * the SPS, never from `hello`). Only needed to configure the decoder; the
 * decoder's output format is authoritative once frames flow.
 */
object SpsParser {
    data class Size(val width: Int, val height: Int)

    /** [sps] is the NAL unit without start code, header byte included. */
    fun h264Size(sps: ByteArray): Size? = try {
        parseH264(BitReader(unescape(sps, 1)))
    } catch (_: Exception) {
        null
    }

    private fun parseH264(r: BitReader): Size {
        val profileIdc = r.bits(8)
        r.bits(16) // constraint flags + level_idc
        r.ue() // seq_parameter_set_id
        var chromaFormatIdc = 1
        if (profileIdc in HIGH_PROFILES) {
            chromaFormatIdc = r.ue()
            if (chromaFormatIdc == 3) r.bits(1) // separate_colour_plane_flag
            r.ue() // bit_depth_luma_minus8
            r.ue() // bit_depth_chroma_minus8
            r.bits(1) // qpprime_y_zero_transform_bypass_flag
            if (r.bits(1) == 1) { // seq_scaling_matrix_present_flag
                val lists = if (chromaFormatIdc != 3) 8 else 12
                for (i in 0 until lists) {
                    if (r.bits(1) == 1) skipScalingList(r, if (i < 6) 16 else 64)
                }
            }
        }
        r.ue() // log2_max_frame_num_minus4
        when (r.ue()) { // pic_order_cnt_type
            0 -> r.ue()
            1 -> {
                r.bits(1)
                r.se()
                r.se()
                val n = r.ue()
                repeat(n) { r.se() }
            }
        }
        r.ue() // max_num_ref_frames
        r.bits(1) // gaps_in_frame_num_value_allowed_flag
        val widthMbs = r.ue() + 1
        val heightMapUnits = r.ue() + 1
        val frameMbsOnly = r.bits(1)
        if (frameMbsOnly == 0) r.bits(1) // mb_adaptive_frame_field_flag
        r.bits(1) // direct_8x8_inference_flag
        var cropL = 0
        var cropR = 0
        var cropT = 0
        var cropB = 0
        if (r.bits(1) == 1) {
            cropL = r.ue(); cropR = r.ue(); cropT = r.ue(); cropB = r.ue()
        }
        val subW = if (chromaFormatIdc == 1 || chromaFormatIdc == 2) 2 else 1
        val subH = if (chromaFormatIdc == 1) 2 else 1
        val cropUnitX = if (chromaFormatIdc == 0) 1 else subW
        val cropUnitY = (if (chromaFormatIdc == 0) 1 else subH) * (2 - frameMbsOnly)
        val width = widthMbs * 16 - (cropL + cropR) * cropUnitX
        val height = (2 - frameMbsOnly) * heightMapUnits * 16 - (cropT + cropB) * cropUnitY
        return Size(width, height)
    }

    private fun skipScalingList(r: BitReader, size: Int) {
        var last = 8
        var next = 8
        for (j in 0 until size) {
            if (next != 0) next = (last + r.se() + 256) % 256
            last = if (next == 0) last else next
        }
    }

    private val HIGH_PROFILES = setOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)

    /** Drops emulation-prevention bytes (00 00 03 -> 00 00), skipping the header. */
    fun unescape(nal: ByteArray, headerBytes: Int): ByteArray {
        val out = ByteArray(nal.size)
        var n = 0
        var zeros = 0
        for (i in headerBytes until nal.size) {
            val b = nal[i].toInt() and 0xFF
            if (zeros >= 2 && b == 3) {
                zeros = 0
                continue
            }
            out[n++] = b.toByte()
            zeros = if (b == 0) zeros + 1 else 0
        }
        return out.copyOf(n)
    }

    private class BitReader(private val data: ByteArray) {
        private var pos = 0

        fun bits(n: Int): Int {
            var v = 0
            repeat(n) {
                val byte = data[pos ushr 3].toInt() and 0xFF
                v = (v shl 1) or ((byte ushr (7 - (pos and 7))) and 1)
                pos++
            }
            return v
        }

        fun ue(): Int {
            var zeros = 0
            while (bits(1) == 0) {
                zeros++
                check(zeros < 32) { "bad exp-golomb" }
            }
            return ((1 shl zeros) - 1) + bits(zeros)
        }

        fun se(): Int {
            val k = ue()
            return if (k and 1 == 1) (k + 1) / 2 else -(k / 2)
        }
    }
}
