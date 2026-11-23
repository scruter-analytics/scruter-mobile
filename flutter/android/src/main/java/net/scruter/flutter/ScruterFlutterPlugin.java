package net.scruter.flutter;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;
import net.scruter.Scruter;
import net.scruter.bridge.ScruterBridge;

/**
 * The bridge between {@code package:scruter_flutter} and the native SDK (docs/MOBILE.md §17): the SDK keeps sessions,
 * transport, native crashes, the install referrer, openings and team phones; the Dart side measures the screens. The
 * team phones' strips, already masked in Dart, are assembled and encoded here, on one background thread.
 */
public final class ScruterFlutterPlugin implements FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
        PluginRegistry.NewIntentListener {
    private static final String ENDPOINT = "https://cdn.scruter.net";
    private static final String API_ENDPOINT = "https://api.scruter.net";
    private static volatile boolean started = false;
    private static volatile Intent pendingLink = null;

    private final Handler main = new Handler(Looper.getMainLooper());
    private MethodChannel channel;
    private Context context;
    private Activity activity;
    private ActivityPluginBinding binding;
    private ExecutorService images;
    private Bitmap image;
    private Canvas canvas;

    /** From {@link ScruterTeamLink}. */
    static void teamLink(Intent intent) {
        if (intent == null) return;
        if (started) {
            Scruter.handle(intent);
        } else {
            pendingLink = intent;
        }
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding b) {
        context = b.getApplicationContext();
        channel = new MethodChannel(b.getBinaryMessenger(), "net.scruter/flutter");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding b) {
        channel.setMethodCallHandler(null);
        channel = null;
        if (images != null) images.shutdown();
        images = null;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding b) {
        binding = b;
        activity = b.getActivity();
        b.addOnNewIntentListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding b) {
        onAttachedToActivity(b);
    }

    @Override
    public void onDetachedFromActivity() {
        if (binding != null) binding.removeOnNewIntentListener(this);
        binding = null;
        activity = null;
    }

    @Override
    public boolean onNewIntent(@NonNull Intent intent) {
        Scruter.handle(intent);
        return false;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "start":
                start(call);
                result.success(null);
                break;
            case "screen":
                ScruterBridge.screen(call.<String>argument("name"));
                result.success(null);
                break;
            case "track":
                track(call);
                result.success(null);
                break;
            case "screenEnd":
                ScruterBridge.screenEnd(call.<String>argument("session"), call.<String>argument("name"),
                        ((Number) call.argument("ms")).longValue(), ((Number) call.argument("depth")).intValue());
                result.success(null);
                break;
            case "analysed":
                ScruterBridge.analysedScreen(call.<String>argument("session"), call.<String>argument("json"));
                result.success(null);
                break;
            case "reportError":
                reportError(call);
                result.success(null);
                break;
            case "flush":
                ScruterBridge.flush();
                result.success(null);
                break;
            case "link":
                Scruter.handle(new Intent(Intent.ACTION_VIEW, Uri.parse(call.<String>argument("url"))));
                result.success(null);
                break;
            case "openedFromNotification":
                Scruter.openedFromNotification();
                result.success(null);
                break;
            case "optOut":
                Scruter.optOut();
                result.success(null);
                break;
            case "optIn":
                Scruter.optIn();
                result.success(null);
                break;
            case "ignoreThisDevice":
                Scruter.ignoreThisDevice(Boolean.TRUE.equals(call.<Boolean>argument("ignore")));
                result.success(null);
                break;
            case "isOptedOut":
                // Shared preferences may still be loading: not on the main thread.
                background(() -> Scruter.isOptedOut(), result);
                break;
            case "isDeviceIgnored":
                background(() -> Scruter.isDeviceIgnored(), result);
                break;
            case "isTeamPhone":
                result.success(ScruterBridge.isTeamPhone());
                break;
            case "leaveTeamMode":
                ScruterBridge.leaveTeamMode();
                result.success(null);
                break;
            case "imageBegin":
                imageBegin(((Number) call.argument("width")).intValue(), ((Number) call.argument("rows")).intValue(), result);
                break;
            case "imageStrip":
                imageStrip(call, result);
                break;
            case "imageFinish":
                imageFinish(call, result);
                break;
            case "imageCancel":
                imageCancel();
                result.success(null);
                break;
            default:
                result.notImplemented();
        }
    }

    private interface Read {
        Object get();
    }

    private void background(Read read, MethodChannel.Result result) {
        executor().execute(() -> {
            Object value = read.get();
            main.post(() -> result.success(value));
        });
    }

    private synchronized ExecutorService executor() {
        if (images == null) images = Executors.newSingleThreadExecutor(r -> new Thread(r, "ScruterFlutter"));
        return images;
    }

    private void start(MethodCall call) {
        String endpoint = call.argument("endpoint");
        String apiEndpoint = call.argument("apiEndpoint");
        ScruterBridge.start(
                context,
                call.<String>argument("appId"),
                "flutter/" + call.<String>argument("version"),
                call.<String>argument("debugKey"),
                Boolean.TRUE.equals(call.<Boolean>argument("debug")),
                Boolean.TRUE.equals(call.<Boolean>argument("testBuild")),
                endpoint != null ? endpoint : ENDPOINT,
                apiEndpoint != null ? apiEndpoint : API_ENDPOINT,
                false,
                activity,
                this::screenStarted);
        started = true;
        Intent link = pendingLink;
        pendingLink = null;
        if (link != null) Scruter.handle(link);
    }

    /** On the SDK's worker: channels are called from the main thread. */
    private void screenStarted(String session, String name, long startMs, boolean analysed, boolean capture, int maxBytes, int maxHeight) {
        Map<String, Object> m = new HashMap<>();
        m.put("session", session);
        m.put("name", name);
        m.put("startMs", startMs);
        m.put("analysed", analysed);
        m.put("capture", capture);
        m.put("maxBytes", maxBytes);
        m.put("maxHeight", maxHeight);
        main.post(() -> {
            if (channel != null) channel.invokeMethod("screenStarted", m);
        });
    }

    private void track(MethodCall call) {
        Map<String, Object> props = call.argument("props");
        Number revenue = call.argument("revenue");
        Scruter.track(call.<String>argument("name"), props != null ? props : new HashMap<String, Object>(),
                revenue != null ? revenue.doubleValue() : null, call.<String>argument("currency"));
    }

    private void reportError(MethodCall call) {
        List<Map<String, Object>> frames = call.argument("frames");
        List<Map<String, Object>> images = call.argument("images");
        ScruterBridge.reportError(
                Boolean.TRUE.equals(call.<Boolean>argument("fatal")),
                "dart",
                call.<String>argument("type"),
                call.<String>argument("reason"),
                new ArrayList<Map<String, ?>>(frames),
                null,
                call.<String>argument("buildId"),
                images != null ? new ArrayList<Map<String, ?>>(images) : new ArrayList<Map<String, ?>>());
    }

    private void imageBegin(int width, int rows, MethodChannel.Result result) {
        executor().execute(() -> {
            drop();
            try {
                image = Bitmap.createBitmap(width, rows, Bitmap.Config.ARGB_8888);
                canvas = new Canvas(image);
            } catch (OutOfMemoryError e) {
                drop();
            }
            main.post(() -> result.success(null));
        });
    }

    private void imageStrip(MethodCall call, MethodChannel.Result result) {
        byte[] rgba = call.argument("rgba");
        int y = ((Number) call.argument("y")).intValue();
        int rows = ((Number) call.argument("rows")).intValue();
        int width = ((Number) call.argument("width")).intValue();
        executor().execute(() -> {
            if (canvas != null && rgba != null) {
                Bitmap strip = Bitmap.createBitmap(width, rows, Bitmap.Config.ARGB_8888);
                strip.copyPixelsFromBuffer(ByteBuffer.wrap(rgba));
                canvas.drawBitmap(strip, 0f, y, null);
                strip.recycle();
            }
            main.post(() -> result.success(null));
        });
    }

    private void imageFinish(MethodCall call, MethodChannel.Result result) {
        String screen = call.argument("screen");
        String tree = call.argument("tree");
        int rows = ((Number) call.argument("rows")).intValue();
        float scale = ((Number) call.argument("scale")).floatValue();
        int maxBytes = ((Number) call.argument("maxBytes")).intValue();
        executor().execute(() -> {
            Bitmap b = image;
            if (b != null && rows > 0 && rows <= b.getHeight()) {
                int width = b.getWidth();
                b.reconfigure(width, rows, Bitmap.Config.ARGB_8888);
                byte[] jpeg = encode(b, maxBytes > 0 ? maxBytes : 2_000_000);
                if (jpeg != null) ScruterBridge.teamImage(screen, jpeg, tree, width, rows, scale);
            }
            drop();
            main.post(() -> result.success(null));
        });
    }

    /** Quality 0.8, lowered by steps to fit the server's limit (docs/MOBILE.md §3.12). */
    private static byte[] encode(Bitmap b, int maxBytes) {
        for (int quality = 80; quality >= 30; quality -= 10) {
            ByteArrayOutputStream out = new ByteArrayOutputStream(Math.min(maxBytes, 1 << 20));
            b.compress(Bitmap.CompressFormat.JPEG, quality, out);
            if (out.size() <= maxBytes) return out.toByteArray();
        }
        return null;
    }

    private void imageCancel() {
        executor().execute(this::drop);
    }

    private void drop() {
        if (image != null) image.recycle();
        image = null;
        canvas = null;
    }
}
