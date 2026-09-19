package app.opendisplay.android;

public final class DisplaySpec {
    public final int pixelsWide;
    public final int pixelsHigh;
    public final double scale;

    public DisplaySpec(int pixelsWide, int pixelsHigh, double scale) {
        this.pixelsWide = pixelsWide;
        this.pixelsHigh = pixelsHigh;
        this.scale = scale;
    }
}
