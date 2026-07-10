package app.opendisplay.android;

public enum DisplayProfile {
    NATIVE("native", "原生", 1.0),
    BALANCED("balanced", "均衡 75%", 0.75),
    FAST("fast", "流畅 50%", 0.5);

    public final String key;
    public final String label;
    public final double scale;

    DisplayProfile(String key, String label, double scale) {
        this.key = key;
        this.label = label;
        this.scale = scale;
    }

    public static DisplayProfile fromKey(String key) {
        for (DisplayProfile profile : values()) {
            if (profile.key.equals(key)) {
                return profile;
            }
        }
        return NATIVE;
    }
}
