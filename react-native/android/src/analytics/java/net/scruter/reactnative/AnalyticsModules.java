package net.scruter.reactnative;

import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;

/** Scruter Analytics is linked, the default (android/build.gradle). */
final class AnalyticsModules {
  static final boolean LINKED = true;

  private AnalyticsModules() {}

  static NativeModule create(ReactApplicationContext context) {
    return new ScruterModule(context);
  }
}
