package app.opendisplay.android;

public final class StreamMetrics {
    public final int receiverFps;
    public final double rttMs;
    public final double inputP50Ms;
    public final int macCaptureFps;

    public StreamMetrics(int receiverFps, double rttMs, double inputP50Ms, int macCaptureFps) {
        this.receiverFps = receiverFps;
        this.rttMs = rttMs;
        this.inputP50Ms = inputP50Ms;
        this.macCaptureFps = macCaptureFps;
    }
}
