package net.scruter.reactnative;

import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;

/** Scruter Analytics is left out: the app's package.json has {@code "scruter": { "analytics": false }}. */
final class AnalyticsModules {
  static final boolean LINKED = false;

  private AnalyticsModules() {}

  static NativeModule create(ReactApplicationContext context) {
    return null;
  }
}
