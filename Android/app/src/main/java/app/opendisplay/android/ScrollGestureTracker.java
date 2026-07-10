package app.opendisplay.android;

public final class ScrollGestureTracker {
    private boolean active;
    private double lastX;
    private double lastY;
    private double viewPixelsPerVideoPixel = 1.0;

    public static final class Delta {
        public final double dx;
        public final double dy;

        private Delta(double dx, double dy) {
            this.dx = dx;
            this.dy = dy;
        }
    }

    public boolean isActive() {
        return active;
    }

    public void begin(double x, double y, double viewPixelsPerVideoPixel) {
        active = true;
        lastX = x;
        lastY = y;
        this.viewPixelsPerVideoPixel = Math.max(0.001, viewPixelsPerVideoPixel);
    }

    public Delta move(double x, double y) {
        if (!active) {
            return null;
        }
        double dx = -(x - lastX) / viewPixelsPerVideoPixel;
        double dy = -(y - lastY) / viewPixelsPerVideoPixel;
        lastX = x;
        lastY = y;
        return new Delta(dx, dy);
    }

    public void end() {
        active = false;
    }
}
