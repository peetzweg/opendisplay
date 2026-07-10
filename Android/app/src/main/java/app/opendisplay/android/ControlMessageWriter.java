package app.opendisplay.android;

import java.io.IOException;
import java.io.OutputStream;
import java.util.concurrent.Executor;

import app.opendisplay.android.protocol.LengthPrefixedProtocol;

public final class ControlMessageWriter {
    private final Executor executor;

    public ControlMessageWriter(Executor executor) {
        this.executor = executor;
    }

    public void send(OutputStream output, String json) {
        if (output == null) {
            return;
        }
        executor.execute(() -> {
            try {
                LengthPrefixedProtocol.write(output, LengthPrefixedProtocol.jsonBytes(json));
            } catch (IOException ignored) {
            }
        });
    }
}
