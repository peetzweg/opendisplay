package app.opendisplay.android;

import android.content.Context;
import android.util.Base64;
import android.view.Surface;

import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

import app.opendisplay.android.protocol.LengthPrefixedProtocol;
import app.opendisplay.android.protocol.MacControlMessage;

public final class OpenDisplayServer implements H264SurfaceDecoder.Listener, NsdAdvertiser.Listener {
    private static final int PORT = 9000;
    private static final long STALE_CONNECTION_MS = 5_000;

    private final Context context;
    private final Listener listener;
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final ExecutorService clientReaders = Executors.newCachedThreadPool();
    private final ExecutorService writer = Executors.newSingleThreadExecutor();
    private final ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor();
    private final String installId;
    private final NsdAdvertiser advertiser;
    private volatile DisplaySpec displaySpec;
    private volatile boolean running;
    private ServerSocket serverSocket;
    private Socket socket;
    private BufferedOutputStream output;
    private H264SurfaceDecoder decoder;
    private volatile Double clockOffsetMs;
    private volatile long lastPayloadReceivedMs;
    private final ControlMessageWriter controlWriter = new ControlMessageWriter(writer);
    private int renderedFrames;
    private long metricsWindowStartMs;
    private double lastRttMs;
    private double lastInputP50Ms;
    private int lastMacCaptureFps;

    public interface Listener {
        void onStatus(String status);
        void onConnected(boolean connected);
        void onStreaming(boolean streaming);
        void onCursor(double x, double y, boolean visible);
        void onCursorImage(byte[] png, double anchorX, double anchorY,
                           double normalizedWidth, double normalizedHeight);
        void onMetrics(StreamMetrics metrics);
    }

    public OpenDisplayServer(Context context, DisplaySpec displaySpec, Listener listener) {
        this.context = context.getApplicationContext();
        this.displaySpec = displaySpec;
        this.listener = listener;
        this.installId = InstallId.get(context);
        this.advertiser = new NsdAdvertiser(context, this);
    }

    public void start(Surface surface) {
        if (running) {
            return;
        }
        running = true;
        decoder = new H264SurfaceDecoder(context, surface, this);
        metricsWindowStartMs = System.currentTimeMillis();
        advertiser.start(context.getString(R.string.app_name), installId, PORT);
        io.execute(this::acceptLoop);
        timer.scheduleAtFixedRate(this::monitorConnection, 2, 2, TimeUnit.SECONDS);
        listener.onStatus(context.getString(R.string.status_listening, PORT));
    }

    public void stop() {
        running = false;
        advertiser.stop();
        closeClient();
        if (serverSocket != null) {
            try {
                serverSocket.close();
            } catch (IOException ignored) {
            }
        }
        if (decoder != null) {
            decoder.release();
        }
        io.shutdownNow();
        clientReaders.shutdownNow();
        writer.shutdownNow();
        timer.shutdownNow();
    }

    public void updateDisplay(DisplaySpec spec) {
        displaySpec = spec;
        sendHello();
    }

    public void sendTouch(String phase, double x, double y) {
        Double macTime = clockOffsetMs == null ? null : LengthPrefixedProtocol.nowMs() + clockOffsetMs;
        sendJson(LengthPrefixedProtocol.touchJson(phase, x, y, macTime));
    }

    public void sendScroll(double dx, double dy) {
        sendJson(LengthPrefixedProtocol.scrollJson(dx, dy));
    }

    private void acceptLoop() {
        try (ServerSocket server = new ServerSocket()) {
            server.setReuseAddress(true);
            server.bind(new InetSocketAddress(PORT));
            serverSocket = server;
            while (running) {
                Socket accepted = server.accept();
                try {
                    accepted.setTcpNoDelay(true);
                    accepted.setKeepAlive(true);
                    BufferedOutputStream acceptedOutput =
                            new BufferedOutputStream(accepted.getOutputStream());
                    installClient(accepted, acceptedOutput);
                    listener.onStreaming(false);
                    listener.onConnected(true);
                    listener.onStatus(context.getString(
                            R.string.status_mac_connected_address,
                            accepted.getInetAddress().getHostAddress()));
                    sendHello();
                    sendJson(LengthPrefixedProtocol.keyframeRequestJson());
                    clientReaders.execute(() -> readLoop(accepted));
                } catch (IOException error) {
                    closeSocket(accepted);
                    if (running) {
                        listener.onStatus(context.getString(
                                R.string.status_listen_failed, error.getMessage()));
                    }
                }
            }
        } catch (IOException error) {
            if (running) {
                listener.onStatus(context.getString(R.string.status_listen_failed, error.getMessage()));
            }
        }
    }

    private void readLoop(Socket active) {
        try {
            BufferedInputStream input = new BufferedInputStream(active.getInputStream());
            while (running && isActiveSocket(active) && !active.isClosed()) {
                byte[] payload = LengthPrefixedProtocol.read(input);
                lastPayloadReceivedMs = System.currentTimeMillis();
                if (LengthPrefixedProtocol.isPureJsonControl(payload)) {
                    handleMacJson(new String(payload, java.nio.charset.StandardCharsets.UTF_8));
                } else if (decoder != null) {
                    decoder.queueFrame(payload);
                }
            }
        } catch (IOException error) {
            if (running && isActiveSocket(active)) {
                listener.onStatus(context.getString(R.string.status_connection_lost));
            }
        } finally {
            if (isActiveSocket(active)) {
                closeClient();
                listener.onConnected(false);
                listener.onStreaming(false);
            }
        }
    }

    private void handleMacJson(String json) {
        try {
            JSONObject object = new JSONObject(json);
            String type = object.optString("type", "");
            if ("ping".equals(type)) {
                double t = object.optDouble("t", 0);
                lastInputP50Ms = object.optDouble("inp50", lastInputP50Ms);
                lastMacCaptureFps = object.optInt("capFps", lastMacCaptureFps);
                sendJson(LengthPrefixedProtocol.pongJson(t, LengthPrefixedProtocol.nowMs()));
            } else if ("pong".equals(type)) {
                double t1 = object.optDouble("t", 0);
                double mt = object.optDouble("mt", 0);
                double t2 = LengthPrefixedProtocol.nowMs();
                double rtt = t2 - t1;
                if (rtt >= 0 && rtt < 2000) {
                    clockOffsetMs = mt - (t1 + t2) / 2.0;
                    lastRttMs = rtt;
                }
            } else if ("cursor".equals(type)) {
                MacControlMessage cursor = MacControlMessage.parse(json);
                listener.onCursor(cursor.x, cursor.y, cursor.visible);
            } else if ("cursorImg".equals(type)) {
                MacControlMessage cursor = MacControlMessage.parse(json);
                byte[] png = Base64.decode(cursor.pngBase64, Base64.DEFAULT);
                listener.onCursorImage(png, cursor.anchorX, cursor.anchorY,
                        cursor.normalizedWidth, cursor.normalizedHeight);
            }
        } catch (Exception ignored) {
        }
    }

    private void sendHello() {
        DisplaySpec spec = displaySpec;
        if (spec == null) {
            return;
        }
        sendJson(LengthPrefixedProtocol.helloJson(
                spec.pixelsWide,
                spec.pixelsHigh,
                spec.scale,
                "Android",
                installId));
    }

    private void monitorConnection() {
        sendJson(LengthPrefixedProtocol.pingJson(LengthPrefixedProtocol.nowMs()));
        Socket active = currentSocket();
        if (active != null
                && System.currentTimeMillis() - lastPayloadReceivedMs > STALE_CONNECTION_MS
                && isActiveSocket(active)) {
            listener.onStatus(context.getString(R.string.status_connection_lost));
            closeClient();
            listener.onConnected(false);
            listener.onStreaming(false);
        }
    }

    private synchronized void sendJson(String json) {
        if (output == null) {
            return;
        }
        controlWriter.send(output, json);
    }

    private void installClient(Socket accepted, BufferedOutputStream acceptedOutput) {
        closeClient();
        resetStreamMetrics();
        synchronized (this) {
            socket = accepted;
            output = acceptedOutput;
            lastPayloadReceivedMs = System.currentTimeMillis();
        }
    }

    private void resetStreamMetrics() {
        clockOffsetMs = null;
        renderedFrames = 0;
        metricsWindowStartMs = System.currentTimeMillis();
        lastRttMs = 0;
        lastInputP50Ms = 0;
        lastMacCaptureFps = 0;
    }

    private void closeClient() {
        Socket closing;
        synchronized (this) {
            closing = socket;
            socket = null;
            output = null;
        }
        closeSocket(closing);
        if (decoder != null) {
            decoder.release();
        }
    }

    private synchronized Socket currentSocket() {
        return socket;
    }

    private synchronized boolean isActiveSocket(Socket active) {
        return active == socket;
    }

    private void closeSocket(Socket closing) {
        if (closing == null) {
            return;
        }
        try {
            closing.close();
        } catch (IOException ignored) {
        }
    }

    @Override
    public void onDecoderStatus(String status) {
        listener.onStatus(status);
        if (status.startsWith(context.getString(R.string.status_receiving_prefix))) {
            listener.onStreaming(true);
        }
    }

    @Override
    public void onDecoderNeedsKeyframe() {
        sendJson(LengthPrefixedProtocol.keyframeRequestJson());
    }

    @Override
    public void onDecoderFrameRendered() {
        renderedFrames++;
        long now = System.currentTimeMillis();
        long elapsed = now - metricsWindowStartMs;
        if (elapsed >= 1000) {
            int fps = (int) Math.round(renderedFrames * 1000.0 / elapsed);
            renderedFrames = 0;
            metricsWindowStartMs = now;
            listener.onMetrics(new StreamMetrics(fps, lastRttMs, lastInputP50Ms, lastMacCaptureFps));
        }
    }

    @Override
    public void onNsdStatus(String status) {
        listener.onStatus(status);
    }
}
