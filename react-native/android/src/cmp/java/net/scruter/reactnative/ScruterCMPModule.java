package net.scruter.reactnative;

import android.app.Activity;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.UiThreadUtil;
import com.facebook.react.bridge.WritableArray;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.module.annotations.ReactModule;
import com.facebook.react.modules.core.DeviceEventManagerModule;
import java.util.List;
import java.util.Map;
import net.scruter.cmp.ConsentState;
import net.scruter.cmp.ScruterCMP;
import net.scruter.cmp.bridge.ScruterCMPBridge;

/**
 * Scruter CMP's JavaScript API on the Android module {@code net.scruter:scruter-cmp}, for both architectures. The sheet,
 * the choice, the proofs and the queue stay in the module: this forwards. Compiled only when the app's package.json
 * asks for the CMP ({@code "scruter": { "cmp": true }}).
 */
@ReactModule(name = ScruterCMPModule.NAME)
public class ScruterCMPModule extends NativeScruterCMPSpec {
  public static final String NAME = "ScruterCMP";
  private static final String EVENT = "ScruterCMPChange";

  public ScruterCMPModule(ReactApplicationContext context) {
    super(context);
  }

  @NonNull
  @Override
  public String getName() {
    return NAME;
  }

  @Nullable
  private static String text(ReadableMap map, String key) {
    return map.hasKey(key) && !map.isNull(key) ? map.getString(key) : null;
  }

  private static boolean flag(ReadableMap map, String key) {
    return map.hasKey(key) && !map.isNull(key) && map.getBoolean(key);
  }

  /**
   * Once per process; a JavaScript reload replaces the listener and starts nothing again. Synchronous, on the JS thread:
   * the module reads the stored choice before the next line of JavaScript.
   */
  @Override
  public boolean start(ReadableMap options) {
    ScruterCMPBridge.listen(this::emit);
    String appId = text(options, "appId");
    if (appId == null) return false;
    String version = text(options, "version");
    Activity activity = getReactApplicationContext().getCurrentActivity();
    boolean started =
        ScruterCMPBridge.start(
            getReactApplicationContext(),
            appId,
            "react_native/" + (version == null ? "1.2.0" : version),
            flag(options, "manual"),
            text(options, "endpoint"),
            activity != null ? activity : ActivityWatch.current(),
            flag(options, "forceShow"),
            flag(options, "debug"));
    String language = text(options, "language");
    if (language != null) ScruterCMP.setLanguage(language);
    if (!started) emit(ScruterCMPBridge.snapshot(), false);
    return started;
  }

  private void emit(Map<String, ?> snapshot, boolean newChoice) {
    ReactApplicationContext context = getReactApplicationContext();
    if (!context.hasActiveReactInstance()) return;
    WritableMap body = Arguments.createMap();
    body.putMap("snapshot", map(snapshot));
    body.putBoolean("newChoice", newChoice);
    context.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class).emit(EVENT, body);
  }

  @SuppressWarnings("unchecked")
  static WritableMap map(Map<String, ?> m) {
    WritableMap out = Arguments.createMap();
    for (Map.Entry<String, ?> e : m.entrySet()) {
      Object v = e.getValue();
      if (v == null) out.putNull(e.getKey());
      else if (v instanceof String) out.putString(e.getKey(), (String) v);
      else if (v instanceof Boolean) out.putBoolean(e.getKey(), (Boolean) v);
      else if (v instanceof Number) out.putDouble(e.getKey(), ((Number) v).doubleValue());
      else if (v instanceof Map) out.putMap(e.getKey(), map((Map<String, ?>) v));
      else if (v instanceof List) {
        WritableArray a = Arguments.createArray();
        for (Object x : (List<?>) v) a.pushString(String.valueOf(x));
        out.putArray(e.getKey(), a);
      }
    }
    return out;
  }

  @Override
  public WritableMap snapshot() {
    return map(ScruterCMPBridge.snapshot());
  }

  @Override
  public void showPreferences() {
    UiThreadUtil.runOnUiThread(
        () -> {
          Activity a = getReactApplicationContext().getCurrentActivity();
          if (a == null) a = ActivityWatch.current();
          if (a != null) ScruterCMP.showPreferences(a);
        });
  }

  @Override
  public boolean showIfNeeded() {
    boolean needed = ScruterCMP.getState() == ConsentState.NEEDS_DECISION;
    UiThreadUtil.runOnUiThread(
        () -> {
          Activity a = getReactApplicationContext().getCurrentActivity();
          if (a == null) a = ActivityWatch.current();
          if (a != null) ScruterCMP.showIfNeeded(a);
        });
    return needed;
  }

  /** Android has no tracking prompt. */
  @Override
  public void requestTrackingIfGranted(Promise promise) {
    promise.resolve("unsupported");
  }

  @Override
  public void setLanguage(@Nullable String language) {
    ScruterCMP.setLanguage(language);
  }

  @Override
  public void setDebug(boolean on) {
    ScruterCMP.setDebug(on);
  }

  @Override
  public void setForceShow(boolean on) {
    ScruterCMP.setForceShow(on);
  }

  @Override
  public void debugReset() {
    ScruterCMP.debugReset();
  }

  @Override
  public void addListener(String eventName) {}

  @Override
  public void removeListeners(double count) {}
}
