package app.opendisplay.android;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.UUID;

public final class InstallId {
    private static final String PREFS = "opendisplay_android";
    private static final String KEY = "install_id";

    private InstallId() {}

    public static String get(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String existing = prefs.getString(KEY, null);
        if (existing != null && !existing.isEmpty()) {
            return existing;
        }
        String fresh = UUID.randomUUID().toString();
        prefs.edit().putString(KEY, fresh).apply();
        return fresh;
    }
}
