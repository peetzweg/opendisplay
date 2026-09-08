package app.opendisplay.android;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;

public final class CursorOverlayView extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private Bitmap bitmap;
    private double x = 0.5;
    private double y = 0.5;
    private double normalizedWidth;
    private double normalizedHeight;
    private double anchorX;
    private double anchorY;
    private boolean visible;

    public CursorOverlayView(Context context) {
        super(context);
        setWillNotDraw(false);
        setClickable(false);
        setFocusable(false);
    }

    public void moveCursor(double x, double y, boolean visible) {
        this.x = clamp01(x);
        this.y = clamp01(y);
        this.visible = visible;
        invalidate();
    }

    public void setCursorImage(Bitmap bitmap, double anchorX, double anchorY,
                               double normalizedWidth, double normalizedHeight) {
        this.bitmap = bitmap;
        this.anchorX = clamp01(anchorX);
        this.anchorY = clamp01(anchorY);
        this.normalizedWidth = Math.max(0, normalizedWidth);
        this.normalizedHeight = Math.max(0, normalizedHeight);
        invalidate();
    }

    public void resetCursor() {
        visible = false;
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (!visible || bitmap == null || normalizedWidth <= 0 || normalizedHeight <= 0) {
            return;
        }
        float width = (float) (normalizedWidth * getWidth());
        float height = (float) (normalizedHeight * getHeight());
        float left = (float) (x * getWidth() - anchorX * width);
        float top = (float) (y * getHeight() - anchorY * height);
        canvas.drawBitmap(bitmap, null, new RectF(left, top, left + width, top + height), paint);
    }

    private static double clamp01(double value) {
        return Math.max(0.0, Math.min(1.0, value));
    }
}
