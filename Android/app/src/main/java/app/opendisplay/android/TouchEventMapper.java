package app.opendisplay.android;

public final class TouchEventMapper {
    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int ACTION_MOVE = 2;
    public static final int ACTION_CANCEL = 3;
    public static final int ACTION_POINTER_DOWN = 5;
    public static final int ACTION_POINTER_UP = 6;

    private TouchEventMapper() {}

    public static int safePointerIndex(int actionMasked, int actionIndex, int pointerCount) {
        if (pointerCount <= 0) {
            return -1;
        }
        if (actionMasked == ACTION_MOVE) {
            return 0;
        }
        if (actionIndex < 0 || actionIndex >= pointerCount) {
            return pointerCount - 1;
        }
        return actionIndex;
    }

    public static String phaseForAction(int actionMasked) {
        switch (actionMasked) {
            case ACTION_DOWN:
            case ACTION_POINTER_DOWN:
                return "began";
            case ACTION_MOVE:
                return "moved";
            case ACTION_UP:
            case ACTION_POINTER_UP:
                return "ended";
            case ACTION_CANCEL:
                return "cancelled";
            default:
                return null;
        }
    }
}
