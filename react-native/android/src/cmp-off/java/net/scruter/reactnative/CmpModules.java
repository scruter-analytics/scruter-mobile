package net.scruter.reactnative;

import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;

/** Scruter CMP is not linked (android/build.gradle): the app carries none of its code. */
final class CmpModules {
  static final boolean LINKED = false;

  private CmpModules() {}

  static NativeModule create(ReactApplicationContext context) {
    return null;
  }
}
