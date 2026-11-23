package net.scruter.reactnative;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.module.model.ReactModuleInfo;
import com.facebook.react.module.model.ReactModuleInfoProvider;
import java.util.HashMap;
import java.util.Map;

/** Autolinked by React Native, for both architectures: the modules the app's package.json takes (android/build.gradle). */
public class ScruterPackage extends PackageBase {
  private static final String ANALYTICS = "Scruter";
  private static final String CMP = "ScruterCMP";

  @Nullable
  @Override
  public NativeModule getModule(@NonNull String name, @NonNull ReactApplicationContext context) {
    if (ANALYTICS.equals(name)) return AnalyticsModules.create(context);
    if (CMP.equals(name)) return CmpModules.create(context);
    return null;
  }

  @NonNull
  @Override
  public ReactModuleInfoProvider getReactModuleInfoProvider() {
    return () -> {
      Map<String, ReactModuleInfo> modules = new HashMap<>();
      if (AnalyticsModules.LINKED) {
        modules.put(ANALYTICS, new ReactModuleInfo(ANALYTICS, "net.scruter.reactnative.ScruterModule", false, false, false, true));
      }
      if (CmpModules.LINKED) {
        modules.put(CMP, new ReactModuleInfo(CMP, "net.scruter.reactnative.ScruterCMPModule", false, false, false, true));
      }
      return modules;
    };
  }
}
