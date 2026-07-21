package app.opendisplay.android;

public final class StreamMetrics {
    public final int receiverFps;
    public final double rttMs;
    public final double inputP50Ms;
    public final int macCaptureFps;
    public final double endToEndMs;
    public final double encodeMs;

    public StreamMetrics(int receiverFps, double rttMs, double inputP50Ms, int macCaptureFps,
                         double endToEndMs, double encodeMs) {
        this.receiverFps = receiverFps;
        this.rttMs = rttMs;
        this.inputP50Ms = inputP50Ms;
        this.macCaptureFps = macCaptureFps;
        this.endToEndMs = endToEndMs;
        this.encodeMs = encodeMs;
    }
}
