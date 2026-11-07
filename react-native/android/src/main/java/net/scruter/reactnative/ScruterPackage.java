package net.scruter.reactnative;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.module.model.ReactModuleInfo;
import com.facebook.react.module.model.ReactModuleInfoProvider;
import java.util.Collections;

/** Autolinked by React Native, for both architectures. */
public class ScruterPackage extends PackageBase {
  @Nullable
  @Override
  public NativeModule getModule(@NonNull String name, @NonNull ReactApplicationContext context) {
    return ScruterModule.NAME.equals(name) ? new ScruterModule(context) : null;
  }

  @NonNull
  @Override
  public ReactModuleInfoProvider getReactModuleInfoProvider() {
    return () ->
        Collections.singletonMap(
            ScruterModule.NAME,
            new ReactModuleInfo(
                ScruterModule.NAME, ScruterModule.class.getName(), false, false, false, true));
  }
}
