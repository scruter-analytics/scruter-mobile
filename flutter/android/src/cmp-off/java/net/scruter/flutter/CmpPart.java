package net.scruter.flutter;

import java.util.List;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

/** Scruter CMP is left out of the app (android/build.gradle, from its pubspec.yaml): none of its code. */
final class CmpPart {
    private CmpPart() {}

    static void add(List<FlutterPlugin> parts) {}
}
