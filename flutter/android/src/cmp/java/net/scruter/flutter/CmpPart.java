package net.scruter.flutter;

import java.util.List;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

/** Scruter CMP is in the app (android/build.gradle, from its pubspec.yaml). */
final class CmpPart {
    private CmpPart() {}

    static void add(List<FlutterPlugin> parts) {
        parts.add(new ScruterCMPPlugin());
    }
}
