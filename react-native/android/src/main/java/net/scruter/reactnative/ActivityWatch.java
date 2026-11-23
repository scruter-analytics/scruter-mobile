package net.scruter.reactnative;

import android.app.Activity;
import android.app.Application;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import java.lang.ref.WeakReference;

/**
 * The activity on screen when JavaScript calls {@code start}. The SDK needs it to know that the app is in the
 * foreground, and it came up long before: React Native loads the bundle while the activity resumes, and its own {@code
 * getCurrentActivity()} is still empty at that point on the old bridge. A provider is what runs before any activity,
 * and it does nothing else: it is no provider of data.
 */
public final class ActivityWatch extends ContentProvider implements Application.ActivityLifecycleCallbacks {
  private static volatile WeakReference<Activity> current = new WeakReference<>(null);

  @Nullable
  static Activity current() {
    return current.get();
  }

  @Override
  public boolean onCreate() {
    if (getContext() != null && getContext().getApplicationContext() instanceof Application) {
      ((Application) getContext().getApplicationContext()).registerActivityLifecycleCallbacks(this);
    }
    return true;
  }

  @Override
  public void onActivityStarted(@NonNull Activity activity) {
    current = new WeakReference<>(activity);
  }

  @Override
  public void onActivityStopped(@NonNull Activity activity) {
    if (current.get() == activity) current = new WeakReference<>(null);
  }

  @Override
  public void onActivityCreated(@NonNull Activity activity, @Nullable Bundle state) {}

  @Override
  public void onActivityResumed(@NonNull Activity activity) {}

  @Override
  public void onActivityPaused(@NonNull Activity activity) {}

  @Override
  public void onActivitySaveInstanceState(@NonNull Activity activity, @NonNull Bundle state) {}

  @Override
  public void onActivityDestroyed(@NonNull Activity activity) {}

  @Nullable
  @Override
  public Cursor query(@NonNull Uri uri, @Nullable String[] projection, @Nullable String selection, @Nullable String[] args, @Nullable String order) {
    return null;
  }

  @Nullable
  @Override
  public String getType(@NonNull Uri uri) {
    return null;
  }

  @Nullable
  @Override
  public Uri insert(@NonNull Uri uri, @Nullable ContentValues values) {
    return null;
  }

  @Override
  public int delete(@NonNull Uri uri, @Nullable String selection, @Nullable String[] args) {
    return 0;
  }

  @Override
  public int update(@NonNull Uri uri, @Nullable ContentValues values, @Nullable String selection, @Nullable String[] args) {
    return 0;
  }
}
