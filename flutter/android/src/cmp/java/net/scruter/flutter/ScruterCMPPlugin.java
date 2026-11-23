package net.scruter.flutter;

import android.app.Activity;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import net.scruter.cmp.ConsentState;
import net.scruter.cmp.ScruterCMP;
import net.scruter.cmp.bridge.ScruterCMPBridge;

/**
 * The bridge between {@code package:scruter_flutter}'s {@code ScruterCMP} and the Android module (docs/CMP-MOBILE.md
 * §3.16): the sheet, the choice, the proofs and the queue stay in the module; this forwards, and tells Dart of every
 * new snapshot. The sheet shows over the Flutter activity.
 */
public final class ScruterCMPPlugin implements FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private final Handler main = new Handler(Looper.getMainLooper());
    private MethodChannel channel;
    private Context context;
    private Activity activity;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding b) {
        context = b.getApplicationContext();
        channel = new MethodChannel(b.getBinaryMessenger(), "net.scruter/cmp");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding b) {
        channel.setMethodCallHandler(null);
        channel = null;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding b) {
        activity = b.getActivity();
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding b) {
        activity = b.getActivity();
    }

    @Override
    public void onDetachedFromActivity() {
        activity = null;
    }

    private void changed(Map<String, ?> snapshot, boolean newChoice) {
        MethodChannel c = channel;
        if (c == null) return;
        Map<String, Object> args = new HashMap<>();
        args.put("snapshot", snapshot);
        args.put("newChoice", newChoice);
        main.post(() -> c.invokeMethod("changed", args));
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "start": {
                // Once per process; a hot restart replaces the listener and starts nothing again.
                ScruterCMPBridge.listen(this::changed);
                String appId = call.argument("appId");
                if (appId != null) {
                    String version = call.argument("version");
                    ScruterCMPBridge.start(
                            context,
                            appId,
                            "flutter/" + (version == null ? "0" : version),
                            Boolean.TRUE.equals(call.argument("manual")),
                            call.argument("endpoint"),
                            activity,
                            Boolean.TRUE.equals(call.argument("forceShow")),
                            Boolean.TRUE.equals(call.argument("debug")));
                    String language = call.argument("language");
                    if (language != null) ScruterCMP.setLanguage(language);
                }
                result.success(ScruterCMPBridge.snapshot());
                break;
            }
            case "snapshot":
                result.success(ScruterCMPBridge.snapshot());
                break;
            case "showPreferences":
                if (activity != null) ScruterCMP.showPreferences(activity);
                result.success(null);
                break;
            case "showIfNeeded": {
                boolean needed = ScruterCMP.getState() == ConsentState.NEEDS_DECISION;
                if (activity != null) ScruterCMP.showIfNeeded(activity);
                result.success(needed);
                break;
            }
            case "requestTrackingIfGranted":
                // Android has no tracking prompt.
                result.success("unsupported");
                break;
            case "setLanguage":
                ScruterCMP.setLanguage(call.argument("language"));
                result.success(null);
                break;
            case "setDebug":
                ScruterCMP.setDebug(Boolean.TRUE.equals(call.argument("on")));
                result.success(null);
                break;
            case "setForceShow":
                ScruterCMP.setForceShow(Boolean.TRUE.equals(call.argument("on")));
                result.success(null);
                break;
            case "debugReset":
                ScruterCMP.debugReset();
                result.success(null);
                break;
            default:
                result.notImplemented();
        }
    }
}
