package app.opendisplay.android;

public enum DisplayProfile {
    NATIVE("native", R.string.display_profile_native, 1.0),
    BALANCED("balanced", R.string.display_profile_balanced, 0.75),
    FAST("fast", R.string.display_profile_fast, 0.5);

    public final String key;
    public final int labelResId;
    public final double scale;

    DisplayProfile(String key, int labelResId, double scale) {
        this.key = key;
        this.labelResId = labelResId;
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
