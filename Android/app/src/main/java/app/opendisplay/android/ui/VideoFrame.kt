package app.opendisplay.android.ui

import android.content.Context
import android.view.ViewGroup

/**
 * Lays its children out in the largest centered rectangle of the video's
 * aspect ratio. Input is normalized against this rectangle (PROTOCOL.md 7),
 * so letterbox bars never skew coordinates.
 */
class VideoFrame(context: Context) : ViewGroup(context) {
    private var videoWidth = 0
    private var videoHeight = 0

    /** The video rectangle inside this view, in this view's pixels. */
    var videoLeft = 0; private set
    var videoTop = 0; private set
    var videoRectWidth = 0; private set
    var videoRectHeight = 0; private set

    fun setVideoSize(width: Int, height: Int) {
        if (width == videoWidth && height == videoHeight) return
        videoWidth = width
        videoHeight = height
        requestLayout()
    }

    /** Screen pixels per video pixel, for scroll deltas. */
    val videoScale: Float
        get() = if (videoWidth > 0) videoRectWidth.toFloat() / videoWidth else 1f

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(w, h)
        computeRect(w, h)
        val cw = MeasureSpec.makeMeasureSpec(videoRectWidth, MeasureSpec.EXACTLY)
        val ch = MeasureSpec.makeMeasureSpec(videoRectHeight, MeasureSpec.EXACTLY)
        for (i in 0 until childCount) getChildAt(i).measure(cw, ch)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        computeRect(r - l, b - t)
        for (i in 0 until childCount) {
            getChildAt(i).layout(videoLeft, videoTop, videoLeft + videoRectWidth, videoTop + videoRectHeight)
        }
    }

    private fun computeRect(w: Int, h: Int) {
        if (videoWidth <= 0 || videoHeight <= 0 || w <= 0 || h <= 0) {
            videoLeft = 0; videoTop = 0; videoRectWidth = w; videoRectHeight = h
            return
        }
        val scale = minOf(w.toFloat() / videoWidth, h.toFloat() / videoHeight)
        videoRectWidth = Math.round(videoWidth * scale)
        videoRectHeight = Math.round(videoHeight * scale)
        videoLeft = (w - videoRectWidth) / 2
        videoTop = (h - videoRectHeight) / 2
    }
}
