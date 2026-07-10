package app.opendisplay.android.protocol;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class MacControlMessage {
    public final String type;
    public final double x;
    public final double y;
    public final boolean visible;
    public final double normalizedWidth;
    public final double normalizedHeight;
    public final double anchorX;
    public final double anchorY;
    public final String pngBase64;

    private MacControlMessage(String type, double x, double y, boolean visible,
                              double normalizedWidth, double normalizedHeight,
                              double anchorX, double anchorY, String pngBase64) {
        this.type = type;
        this.x = x;
        this.y = y;
        this.visible = visible;
        this.normalizedWidth = normalizedWidth;
        this.normalizedHeight = normalizedHeight;
        this.anchorX = anchorX;
        this.anchorY = anchorY;
        this.pngBase64 = pngBase64;
    }

    public static MacControlMessage parse(String json) {
        return new MacControlMessage(
                stringField(json, "type", ""),
                numberField(json, "x", 0),
                numberField(json, "y", 0),
                numberField(json, "v", 0) == 1,
                numberField(json, "nw", 0),
                numberField(json, "nh", 0),
                numberField(json, "ax", 0),
                numberField(json, "ay", 0),
                stringField(json, "png", ""));
    }

    private static double numberField(String json, String key, double fallback) {
        Pattern pattern = Pattern.compile("\"" + Pattern.quote(key)
                + "\"\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?)");
        Matcher matcher = pattern.matcher(json);
        return matcher.find() ? Double.parseDouble(matcher.group(1)) : fallback;
    }

    private static String stringField(String json, String key, String fallback) {
        Pattern pattern = Pattern.compile("\"" + Pattern.quote(key) + "\"\\s*:\\s*\"([^\"]*)\"");
        Matcher matcher = pattern.matcher(json);
        return matcher.find() ? matcher.group(1) : fallback;
    }
}
