package net.scruter.flutter;

import androidx.annotation.NonNull;

import java.util.ArrayList;
import java.util.List;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;

/**
 * The plugin Flutter registers: Scruter Analytics and Scruter CMP, each compiled only when the app's pubspec.yaml takes
 * it ({@code scruter: { analytics: false, cmp: true }}, docs/CMP-MOBILE.md §3.16). android/build.gradle picks the source
 * sets that hold each module's half, or a stand-in that adds nothing.
 */
public final class ScruterFlutterPlugin implements FlutterPlugin, ActivityAware {
    private final List<FlutterPlugin> parts = new ArrayList<>();

    public ScruterFlutterPlugin() {
        AnalyticsPart.add(parts);
        CmpPart.add(parts);
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        for (FlutterPlugin p : parts) p.onAttachedToEngine(binding);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        for (FlutterPlugin p : parts) p.onDetachedFromEngine(binding);
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        for (FlutterPlugin p : parts) if (p instanceof ActivityAware) ((ActivityAware) p).onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        for (FlutterPlugin p : parts) if (p instanceof ActivityAware) ((ActivityAware) p).onDetachedFromActivityForConfigChanges();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        for (FlutterPlugin p : parts) {
            if (p instanceof ActivityAware) ((ActivityAware) p).onReattachedToActivityForConfigChanges(binding);
        }
    }

    @Override
    public void onDetachedFromActivity() {
        for (FlutterPlugin p : parts) if (p instanceof ActivityAware) ((ActivityAware) p).onDetachedFromActivity();
    }
}
