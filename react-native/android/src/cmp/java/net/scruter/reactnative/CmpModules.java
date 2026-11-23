package net.scruter.reactnative;

import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;

/** Scruter CMP is linked: the app's package.json has {@code "scruter": { "cmp": true }} (android/build.gradle). */
final class CmpModules {
  static final boolean LINKED = true;

  private CmpModules() {}

  static NativeModule create(ReactApplicationContext context) {
    return new ScruterCMPModule(context);
  }
}
