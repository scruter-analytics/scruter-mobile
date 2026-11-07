package net.scruter.reactnative;

import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Handler;
import android.os.Looper;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReadableArray;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.ReadableMapKeySetIterator;
import com.facebook.react.bridge.ReadableType;
import com.facebook.react.module.annotations.ReactModule;
import com.facebook.react.modules.core.DeviceEventManagerModule;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import net.scruter.FieldError;
import net.scruter.Scruter;
import net.scruter.bridge.ScruterBridge;

/**
 * The JavaScript API on the Android SDK, for both architectures: the generated spec is a TurboModule on the new one and
 * carries the {@code @ReactMethod}s the bridge reads on the old one. Every call returns at once.
 */
@ReactModule(name = ScruterModule.NAME)
public class ScruterModule extends NativeScruterSpec {
  public static final String NAME = "Scruter";
  private static final String ENDPOINT = "https://cdn.scruter.net";
  private static final String API_ENDPOINT = "https://api.scruter.net";
  private static final String LOG_EVENT = "ScruterLog";
  private final Handler main = new Handler(Looper.getMainLooper());

  public ScruterModule(ReactApplicationContext context) {
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

  @Override
  public void start(ReadableMap options) {
    String appId = text(options, "appId");
    if (appId == null) return;
    String endpoint = text(options, "endpoint");
    String api = text(options, "apiEndpoint");
    String version = text(options, "version");
    boolean debug = flag(options, "debug");
    ScruterBridge.setElementInspector(new ReactElements());
    if (debug) {
      ScruterBridge.setLogSink(this::emitLog);
    }
    ScruterBridge.start(
        getReactApplicationContext(),
        appId,
        "react_native/" + (version == null ? "1.0.0" : version),
        text(options, "debugKey"),
        debug,
        flag(options, "testBuild"),
        endpoint == null ? ENDPOINT : endpoint,
        api == null ? API_ENDPOINT : api,
        false,
        ActivityWatch.current());
  }

  private void emitLog(String line) {
    ReactApplicationContext context = getReactApplicationContext();
    if (!context.hasActiveReactInstance()) return;
    context.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class).emit(LOG_EVENT, line);
  }

  @Override
  public void screen(String name, boolean forward) {
    ScruterBridge.screen(name, forward);
  }

  @Override
  public void track(String name, ReadableMap event) {
    Map<String, Object> out = new HashMap<>();
    ReadableMap props = event.hasKey("props") && !event.isNull("props") ? event.getMap("props") : null;
    if (props != null) {
      ReadableMapKeySetIterator keys = props.keySetIterator();
      while (keys.hasNextKey()) {
        String key = keys.nextKey();
        if (props.getType(key) == ReadableType.String) out.put(key, props.getString(key));
      }
    }
    Double revenue = event.hasKey("revenue") && !event.isNull("revenue") ? event.getDouble("revenue") : null;
    String currency = text(event, "currency");
    // After `start`'s turn on the main thread, which opens the session: an event right after `start` belongs to it.
    main.post(() -> Scruter.track(name, out, revenue, currency));
  }

  @Override
  public void fieldError(String key, String kind) {
    try {
      Scruter.fieldError(key, FieldError.valueOf(kind.toUpperCase(Locale.ROOT)));
    } catch (IllegalArgumentException e) {
      Scruter.fieldError(key, FieldError.INVALID);
    }
  }

  @Override
  public void formSent(String name) {
    Scruter.formSent(name);
  }

  @Override
  public void optOut() {
    Scruter.optOut();
  }

  @Override
  public void optIn() {
    Scruter.optIn();
  }

  @Override
  public boolean isOptedOut() {
    return Scruter.isOptedOut();
  }

  @Override
  public void ignoreThisDevice() {
    Scruter.ignoreThisDevice(true);
  }

  @Override
  public void stopIgnoringThisDevice() {
    Scruter.ignoreThisDevice(false);
  }

  @Override
  public boolean isDeviceIgnored() {
    return Scruter.isDeviceIgnored();
  }

  @Override
  public void handle(String url) {
    ScruterBridge.handleUrl(url);
  }

  @Override
  public void openedFromNotification() {
    Scruter.openedFromNotification();
  }

  @Override
  public boolean isTeamPhone() {
    return ScruterBridge.isTeamPhone();
  }

  @Override
  public void leaveTeamMode() {
    ScruterBridge.leaveTeamMode();
  }

  @Override
  public void flush() {
    ScruterBridge.flush();
  }

  @Override
  public boolean reportError(boolean fatal, String type, String reason, ReadableArray frames, String bundleId) {
    List<Map<String, Object>> list = new ArrayList<>(frames.size());
    for (int i = 0; i < frames.size(); i++) {
      ReadableMap f = frames.getMap(i);
      Map<String, Object> m = new HashMap<>();
      if (f.hasKey("fn")) m.put("fn", f.getString("fn"));
      if (f.hasKey("fl")) m.put("fl", f.getString("fl"));
      if (f.hasKey("l")) m.put("l", (long) f.getDouble("l"));
      if (f.hasKey("co")) m.put("co", (long) f.getDouble("co"));
      if (f.hasKey("ia")) m.put("ia", Boolean.TRUE);
      list.add(m);
    }
    ScruterBridge.reportError(fatal, "js", type, reason, list, bundleId.isEmpty() ? null : bundleId, null);
    return true;
  }

  /** {@code rn-android-<version>-<build>}: the same as {@code defaultBundleId} in the CLI. */
  @NonNull
  @Override
  public String defaultBundleId() {
    String version = "0";
    long build = 0;
    try {
      ReactApplicationContext c = getReactApplicationContext();
      PackageInfo info = c.getPackageManager().getPackageInfo(c.getPackageName(), 0);
      if (info.versionName != null) version = info.versionName;
      build = android.os.Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode;
    } catch (PackageManager.NameNotFoundException e) {
      // The app's own package exists.
    }
    String id = ("rn-android-" + version + "-" + build).replaceAll("[^A-Za-z0-9._:-]", "_");
    return id.length() > 100 ? id.substring(0, 100) : id;
  }

  @Override
  public void addListener(String eventName) {}

  @Override
  public void removeListeners(double count) {}
}
