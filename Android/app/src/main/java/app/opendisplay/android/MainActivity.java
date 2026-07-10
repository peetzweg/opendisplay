package app.opendisplay.android;

import android.Manifest;
import android.app.AlertDialog;
import android.app.Activity;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Rect;
import android.os.Build;
import android.os.Bundle;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.ImageView;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

public final class MainActivity extends Activity implements OpenDisplayServer.Listener {
    private static final int REQUEST_NEARBY_WIFI = 20;
    private static final String PREFS = "OpenDisplayAndroid";
    private static final String KEY_ONBOARDING_DISMISSED = "onboardingDismissed";
    private static final String KEY_KEEP_AWAKE = "keepAwake";
    private static final String KEY_DISCONNECT_ON_PAUSE = "disconnectOnPause";
    private static final String KEY_SHOW_STATUS = "showStatusOverlay";
    private static final String KEY_SHOW_METRICS = "showMetrics";
    private static final String KEY_DISPLAY_PROFILE = "displayProfile";

    private FrameLayout root;
    private SurfaceView surfaceView;
    private CursorOverlayView cursorOverlay;
    private TextView statusView;
    private TextView idleStatusView;
    private View idlePanel;
    private OpenDisplayServer server;
    private SurfaceHolder activeSurface;
    private SharedPreferences prefs;
    private String currentStatus;
    private boolean streaming;
    private final ScrollGestureTracker scrollGesture = new ScrollGestureTracker();
    private TouchGestureCoordinator touchGesture;
    private StreamMetrics lastMetrics = new StreamMetrics(0, 0, 0, 0, 0, 0);

    @Override
    @SuppressWarnings("deprecation")
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        enterImmersiveMode();
        currentStatus = getString(R.string.status_waiting_start);
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {Manifest.permission.NEARBY_WIFI_DEVICES}, REQUEST_NEARBY_WIFI);
        }
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        buildUi();
        applyKeepAwakePreference();
        showOnboardingIfNeeded();
    }

    @Override
    protected void onResume() {
        super.onResume();
        enterImmersiveMode();
        applyKeepAwakePreference();
        startServerIfReady();
    }

    @Override
    protected void onPause() {
        if (prefs != null && prefs.getBoolean(KEY_DISCONNECT_ON_PAUSE, false)) {
            stopServer();
        }
        super.onPause();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            enterImmersiveMode();
        }
    }

    @Override
    protected void onDestroy() {
        stopServer();
        super.onDestroy();
    }

    @SuppressWarnings("deprecation")
    private void enterImmersiveMode() {
        Window window = getWindow();
        window.setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN,
                WindowManager.LayoutParams.FLAG_FULLSCREEN);
        if (Build.VERSION.SDK_INT >= 28) {
            WindowManager.LayoutParams attrs = window.getAttributes();
            attrs.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            window.setAttributes(attrs);
        }
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false);
        }
        window.getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
    }

    @Override
    public void onStatus(String status) {
        runOnUiThread(() -> setStatus(status));
    }

    @Override
    public void onConnected(boolean connected) {
        runOnUiThread(() -> {
            setStatus(getString(connected
                    ? R.string.status_mac_connected_waiting_video
                    : R.string.status_waiting_mac_connection));
            if (!connected) {
                setStreaming(false);
                cursorOverlay.resetCursor();
            }
        });
    }

    @Override
    public void onStreaming(boolean streaming) {
        runOnUiThread(() -> setStreaming(streaming));
    }

    @Override
    public void onCursor(double x, double y, boolean visible) {
        runOnUiThread(() -> cursorOverlay.moveCursor(x, y, visible));
    }

    @Override
    public void onCursorImage(byte[] png, double anchorX, double anchorY,
                              double normalizedWidth, double normalizedHeight) {
        Bitmap bitmap = BitmapFactory.decodeByteArray(png, 0, png.length);
        if (bitmap == null) {
            return;
        }
        runOnUiThread(() -> cursorOverlay.setCursorImage(
                bitmap, anchorX, anchorY, normalizedWidth, normalizedHeight));
    }

    @Override
    public void onMetrics(StreamMetrics metrics) {
        runOnUiThread(() -> {
            lastMetrics = metrics;
            refreshStreamingStatus();
        });
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQUEST_NEARBY_WIFI && hasNearbyWifiPermission()) {
            startServerIfReady();
        } else if (requestCode == REQUEST_NEARBY_WIFI) {
            setStatus(getString(R.string.status_nearby_wifi_permission_required));
        }
    }

    private void buildUi() {
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        surfaceView = new SurfaceView(this);
        root.addView(surfaceView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        cursorOverlay = new CursorOverlayView(this);
        root.addView(cursorOverlay, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        idlePanel = buildIdlePanel();
        root.addView(idlePanel, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        statusView = new TextView(this);
        statusView.setTextColor(Color.WHITE);
        statusView.setTextSize(15);
        statusView.setText(currentStatus);
        statusView.setPadding(18, 12, 18, 12);
        statusView.setBackgroundColor(0x99000000);
        statusView.setOnClickListener(v -> showSettingsDialog());
        FrameLayout.LayoutParams statusParams = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP | Gravity.START);
        statusParams.setMargins(18, 18, 18, 18);
        root.addView(statusView, statusParams);
        setContentView(root);
        updateStatusOverlayVisibility();

        surfaceView.getHolder().addCallback(new SurfaceHolder.Callback() {
            @Override
            public void surfaceCreated(SurfaceHolder holder) {
                activeSurface = holder;
                startServerIfReady();
            }

            @Override
            public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
                if (server != null) {
                    server.updateDisplay(currentDisplaySpec());
                }
            }

            @Override
            public void surfaceDestroyed(SurfaceHolder holder) {
                activeSurface = null;
                stopServer();
            }
        });

        surfaceView.setOnTouchListener(this::handleTouch);
    }

    private View buildIdlePanel() {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(0xFFF7F9FC);

        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setGravity(Gravity.CENTER_HORIZONTAL);
        content.setPadding(36, 42, 36, 28);
        scroll.addView(content, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT,
                ScrollView.LayoutParams.WRAP_CONTENT));

        ImageView logo = new ImageView(this);
        logo.setImageResource(getResources().getIdentifier("app_logo", "drawable", getPackageName()));
        logo.setAdjustViewBounds(true);
        content.addView(logo, new LinearLayout.LayoutParams(dp(118), dp(118)));

        TextView title = text(getString(R.string.app_name), 30, Color.rgb(20, 24, 34), true);
        title.setGravity(Gravity.CENTER);
        content.addView(title, matchWrap());

        idleStatusView = text(currentStatus, 15, Color.rgb(78, 91, 112), false);
        idleStatusView.setGravity(Gravity.CENTER);
        idleStatusView.setPadding(0, dp(8), 0, dp(24));
        content.addView(idleStatusView, matchWrap());

        content.addView(cardText(getString(R.string.idle_instructions)));

        Button settings = new Button(this);
        settings.setText(getString(R.string.button_settings_help));
        settings.setOnClickListener(v -> showSettingsDialog());
        LinearLayout.LayoutParams buttonParams = matchWrap();
        buttonParams.setMargins(0, dp(24), 0, dp(8));
        content.addView(settings, buttonParams);

        TextView footnote = text(getString(R.string.idle_footnote), 13,
                Color.rgb(117, 128, 145), false);
        footnote.setGravity(Gravity.CENTER);
        footnote.setPadding(0, dp(8), 0, 0);
        content.addView(footnote, matchWrap());
        return scroll;
    }

    private TextView cardText(String value) {
        TextView view = text(value, 16, Color.rgb(37, 45, 58), false);
        view.setLineSpacing(dp(4), 1.0f);
        view.setPadding(dp(20), dp(18), dp(20), dp(18));
        view.setBackgroundColor(Color.WHITE);
        return view;
    }

    private void showSettingsDialog() {
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(20), dp(10), dp(20), 0);

        content.addView(text(getString(R.string.settings_connection_status, currentStatus),
                15, Color.rgb(36, 45, 60), false), matchWrap());
        content.addView(text(getString(R.string.settings_server_info, 9000, InstallId.get(this)), 13,
                Color.rgb(95, 105, 120), false), matchWrap());

        CheckBox keepAwake = new CheckBox(this);
        keepAwake.setText(getString(R.string.settings_keep_awake));
        keepAwake.setChecked(prefs.getBoolean(KEY_KEEP_AWAKE, true));
        keepAwake.setOnCheckedChangeListener((button, checked) -> {
            prefs.edit().putBoolean(KEY_KEEP_AWAKE, checked).apply();
            applyKeepAwakePreference();
        });
        content.addView(keepAwake, matchWrap());

        CheckBox disconnectOnPause = new CheckBox(this);
        disconnectOnPause.setText(getString(R.string.settings_disconnect_on_pause));
        disconnectOnPause.setChecked(prefs.getBoolean(KEY_DISCONNECT_ON_PAUSE, false));
        disconnectOnPause.setOnCheckedChangeListener((button, checked) ->
                prefs.edit().putBoolean(KEY_DISCONNECT_ON_PAUSE, checked).apply());
        content.addView(disconnectOnPause, matchWrap());

        CheckBox showStatus = new CheckBox(this);
        showStatus.setText(getString(R.string.settings_show_status));
        showStatus.setChecked(prefs.getBoolean(KEY_SHOW_STATUS, true));
        showStatus.setOnCheckedChangeListener((button, checked) -> {
            prefs.edit().putBoolean(KEY_SHOW_STATUS, checked).apply();
            updateStatusOverlayVisibility();
        });
        content.addView(showStatus, matchWrap());

        CheckBox showMetrics = new CheckBox(this);
        showMetrics.setText(getString(R.string.settings_show_metrics));
        showMetrics.setChecked(prefs.getBoolean(KEY_SHOW_METRICS, true));
        showMetrics.setOnCheckedChangeListener((button, checked) -> {
            prefs.edit().putBoolean(KEY_SHOW_METRICS, checked).apply();
            refreshStreamingStatus();
        });
        content.addView(showMetrics, matchWrap());

        Button quality = new Button(this);
        quality.setText(getString(R.string.settings_quality,
                displayProfileLabel(currentDisplayProfile())));
        quality.setOnClickListener(v -> showDisplayProfileDialog());
        content.addView(quality, matchWrap());

        TextView help = text(getString(R.string.settings_help_text), 14,
                Color.rgb(82, 94, 112), false);
        help.setPadding(0, dp(10), 0, 0);
        content.addView(help, matchWrap());

        if (!hasNearbyWifiPermission() && Build.VERSION.SDK_INT >= 33) {
            Button permission = new Button(this);
            permission.setText(getString(R.string.settings_grant_nearby_wifi));
            permission.setOnClickListener(v -> requestPermissions(
                    new String[] {Manifest.permission.NEARBY_WIFI_DEVICES}, REQUEST_NEARBY_WIFI));
            content.addView(permission, matchWrap());
        }

        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.settings_title))
                .setView(content)
                .setPositiveButton(getString(R.string.action_done), null)
                .show();
    }

    private void showDisplayProfileDialog() {
        DisplayProfile[] profiles = DisplayProfile.values();
        String[] labels = new String[profiles.length];
        int checked = 0;
        DisplayProfile current = currentDisplayProfile();
        for (int i = 0; i < profiles.length; i++) {
            labels[i] = displayProfileLabel(profiles[i]);
            if (profiles[i] == current) {
                checked = i;
            }
        }
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.display_profile_title))
                .setSingleChoiceItems(labels, checked, (dialog, which) -> {
                    prefs.edit().putString(KEY_DISPLAY_PROFILE, profiles[which].key).apply();
                    if (server != null) {
                        server.updateDisplay(currentDisplaySpec());
                    }
                    setStatus(getString(R.string.status_display_profile_requested,
                            labels[which]));
                    dialog.dismiss();
                })
                .setNegativeButton(getString(R.string.action_cancel), null)
                .show();
    }

    private void showOnboardingIfNeeded() {
        if (prefs.getBoolean(KEY_ONBOARDING_DISMISSED, false)) {
            return;
        }
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.onboarding_title))
                .setMessage(getString(R.string.onboarding_message))
                .setPositiveButton(getString(R.string.onboarding_ok), (dialog, which) ->
                        prefs.edit().putBoolean(KEY_ONBOARDING_DISMISSED, true).apply())
                .show();
    }

    private void startServerIfReady() {
        if (server != null || activeSurface == null) {
            return;
        }
        if (!hasNearbyWifiPermission()) {
            setStatus(getString(R.string.status_waiting_nearby_wifi_permission));
            return;
        }
        server = new OpenDisplayServer(MainActivity.this, currentDisplaySpec(), MainActivity.this);
        server.start(activeSurface.getSurface());
    }

    private void stopServer() {
        if (server != null) {
            server.stop();
            server = null;
        }
        setStreaming(false);
        if (cursorOverlay != null) {
            cursorOverlay.resetCursor();
        }
    }

    private boolean hasNearbyWifiPermission() {
        return Build.VERSION.SDK_INT < 33
                || checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES)
                == PackageManager.PERMISSION_GRANTED;
    }

    private boolean handleTouch(View view, MotionEvent event) {
        if (server == null || view.getWidth() <= 0 || view.getHeight() <= 0) {
            return true;
        }
        if (event.getPointerCount() >= 2 || scrollGesture.isActive()) {
            handleScrollGesture(view, event);
            return true;
        }

        int index = TouchEventMapper.safePointerIndex(
                event.getActionMasked(), event.getActionIndex(), event.getPointerCount());
        if (index < 0) {
            return true;
        }
        double x = event.getX(index) / Math.max(1.0, view.getWidth());
        double y = event.getY(index) / Math.max(1.0, view.getHeight());
        if (touchGesture == null) {
            touchGesture = new TouchGestureCoordinator(10.0 / Math.max(view.getWidth(), view.getHeight()));
        }
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                sendTouchEvents(touchGesture.begin(x, y));
                break;
            case MotionEvent.ACTION_MOVE:
                sendTouchEvents(touchGesture.move(x, y));
                break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP:
                sendTouchEvents(touchGesture.end(x, y));
                break;
            case MotionEvent.ACTION_CANCEL:
                sendTouchEvents(touchGesture.cancel());
                break;
            default:
                break;
        }
        return true;
    }

    private void handleScrollGesture(View view, MotionEvent event) {
        if (touchGesture != null) {
            sendTouchEvents(touchGesture.cancel());
        }
        if (event.getPointerCount() < 2) {
            scrollGesture.end();
            return;
        }
        double x = (event.getX(0) + event.getX(1)) / 2.0;
        double y = (event.getY(0) + event.getY(1)) / 2.0;
        if (!scrollGesture.isActive()) {
            scrollGesture.begin(x, y, videoScaleInView(view));
            return;
        }
        if (event.getActionMasked() == MotionEvent.ACTION_POINTER_UP
                || event.getActionMasked() == MotionEvent.ACTION_UP
                || event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
            scrollGesture.end();
            return;
        }
        ScrollGestureTracker.Delta delta = scrollGesture.move(x, y);
        if (delta != null && (Math.abs(delta.dx) > 0.01 || Math.abs(delta.dy) > 0.01)) {
            server.sendScroll(delta.dx, delta.dy);
        }
    }

    private void sendTouchEvents(java.util.List<TouchGestureCoordinator.Event> events) {
        for (TouchGestureCoordinator.Event event : events) {
            server.sendTouch(event.phase, event.x, event.y);
        }
    }

    private double videoScaleInView(View view) {
        DisplaySpec spec = currentDisplaySpec();
        double xScale = view.getWidth() / Math.max(1.0, spec.pixelsWide);
        double yScale = view.getHeight() / Math.max(1.0, spec.pixelsHigh);
        return Math.max(0.001, Math.min(xScale, yScale));
    }

    private void setStatus(String status) {
        currentStatus = status;
        if (statusView != null) {
            statusView.setText(status);
        }
        if (idleStatusView != null) {
            idleStatusView.setText(status);
        }
    }

    private void setStreaming(boolean streaming) {
        this.streaming = streaming;
        if (idlePanel != null) {
            idlePanel.setVisibility(streaming ? View.GONE : View.VISIBLE);
        }
        updateStatusOverlayVisibility();
    }

    private void refreshStreamingStatus() {
        if (!streaming || !prefs.getBoolean(KEY_SHOW_METRICS, true)) {
            return;
        }
        StringBuilder value = new StringBuilder(getString(R.string.status_receiving_prefix));
        if (lastMetrics.receiverFps > 0) {
            value.append(" · ").append(lastMetrics.receiverFps).append(" FPS");
        }
        if (lastMetrics.endToEndMs > 0) {
            value.append(" · ").append(getString(R.string.metrics_end_to_end)).append(" ")
                    .append(Math.round(lastMetrics.endToEndMs)).append(" ms");
        }
        if (lastMetrics.encodeMs > 0) {
            value.append(" · ").append(getString(R.string.metrics_encode)).append(" ")
                    .append(Math.round(lastMetrics.encodeMs)).append(" ms");
        }
        if (lastMetrics.rttMs > 0) {
            value.append(" · RTT ").append(Math.round(lastMetrics.rttMs)).append(" ms");
        }
        if (lastMetrics.inputP50Ms > 0) {
            value.append(" · ").append(getString(R.string.metrics_input)).append(" ")
                    .append(Math.round(lastMetrics.inputP50Ms)).append(" ms");
        }
        if (lastMetrics.macCaptureFps > 0) {
            value.append(" · Mac ").append(lastMetrics.macCaptureFps).append(" FPS");
        }
        setStatus(value.toString());
    }

    private void updateStatusOverlayVisibility() {
        if (statusView == null) {
            return;
        }
        boolean show = streaming && (prefs == null || prefs.getBoolean(KEY_SHOW_STATUS, true));
        statusView.setVisibility(show ? View.VISIBLE : View.GONE);
    }

    private void applyKeepAwakePreference() {
        if (prefs == null || prefs.getBoolean(KEY_KEEP_AWAKE, true)) {
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        } else {
            getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        }
    }

    private DisplaySpec currentDisplaySpec() {
        DisplayMetrics metrics = getResources().getDisplayMetrics();
        DisplayProfile profile = currentDisplayProfile();
        if (Build.VERSION.SDK_INT >= 30) {
            Rect bounds = getWindowManager().getCurrentWindowMetrics().getBounds();
            return scaledDisplaySpec(bounds.width(), bounds.height(), metrics.density, profile);
        }
        DisplayMetrics realMetrics = new DisplayMetrics();
        readLegacyRealMetrics(realMetrics);
        return scaledDisplaySpec(realMetrics.widthPixels, realMetrics.heightPixels, realMetrics.density, profile);
    }

    private DisplaySpec scaledDisplaySpec(int width, int height, double density, DisplayProfile profile) {
        int scaledW = Math.max(2, ((int) Math.round(width * profile.scale)) & ~1);
        int scaledH = Math.max(2, ((int) Math.round(height * profile.scale)) & ~1);
        return new DisplaySpec(scaledW, scaledH, density);
    }

    private DisplayProfile currentDisplayProfile() {
        if (prefs == null) {
            return DisplayProfile.NATIVE;
        }
        return DisplayProfile.fromKey(prefs.getString(KEY_DISPLAY_PROFILE, DisplayProfile.NATIVE.key));
    }

    private String displayProfileLabel(DisplayProfile profile) {
        return getString(profile.labelResId);
    }

    @SuppressWarnings("deprecation")
    private void readLegacyRealMetrics(DisplayMetrics out) {
        getWindowManager().getDefaultDisplay().getRealMetrics(out);
    }

    private TextView text(String value, int sp, int color, boolean bold) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(sp);
        view.setTextColor(color);
        if (bold) {
            view.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);
        }
        return view;
    }

    private LinearLayout.LayoutParams matchWrap() {
        return new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }
}
