package net.scruter.flutter;

import java.util.List;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

/** Scruter Analytics is in the app (android/build.gradle, from its pubspec.yaml). */
final class AnalyticsPart {
    private AnalyticsPart() {}

    static void add(List<FlutterPlugin> parts) {
        parts.add(new ScruterAnalyticsPlugin());
    }
}
