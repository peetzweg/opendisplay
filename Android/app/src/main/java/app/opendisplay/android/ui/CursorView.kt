package app.opendisplay.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.View

/**
 * The sender's cursor, drawn over the video at input rate rather than baked
 * into the stream (PROTOCOL.md 6.2). Main thread only.
 */
class CursorView(context: Context) : View(context) {
    private var x = 0.5
    private var y = 0.5
    private var visible = false
    private var sprite: Bitmap? = null
    private var spriteNw = 0.0
    private var spriteNh = 0.0
    private var anchorX = 0.0
    private var anchorY = 0.0

    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = 2f * resources.displayMetrics.density
    }
    private val arrow = Path()
    private val dst = RectF()

    fun update(x: Double, y: Double, visible: Boolean) {
        if (x == this.x && y == this.y && visible == this.visible) return
        this.x = x
        this.y = y
        this.visible = visible
        postInvalidateOnAnimation()
    }

    fun setSprite(bitmap: Bitmap?, nw: Double, nh: Double, ax: Double, ay: Double) {
        sprite = bitmap
        spriteNw = nw
        spriteNh = nh
        anchorX = ax
        anchorY = ay
        invalidate()
    }

    fun clear() {
        visible = false
        sprite = null
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        if (!visible || width == 0) return
        val px = (x * width).toFloat()
        val py = (y * height).toFloat()
        val bmp = sprite
        if (bmp != null && spriteNw > 0 && spriteNh > 0) {
            val w = (spriteNw * width).toFloat()
            val h = (spriteNh * height).toFloat()
            val left = px - (anchorX * w).toFloat()
            val top = py - (anchorY * h).toFloat()
            dst.set(left, top, left + w, top + h)
            canvas.drawBitmap(bmp, null, dst, bitmapPaint)
            return
        }
        // No sprite yet: a plain arrow so the pointer is never invisible.
        val s = 18f * resources.displayMetrics.density
        arrow.reset()
        arrow.moveTo(px, py)
        arrow.lineTo(px, py + s)
        arrow.lineTo(px + s * 0.28f, py + s * 0.75f)
        arrow.lineTo(px + s * 0.5f, py + s * 1.15f)
        arrow.lineTo(px + s * 0.62f, py + s * 1.08f)
        arrow.lineTo(px + s * 0.42f, py + s * 0.7f)
        arrow.lineTo(px + s * 0.75f, py + s * 0.7f)
        arrow.close()
        canvas.drawPath(arrow, fill)
        canvas.drawPath(arrow, stroke)
    }
}
