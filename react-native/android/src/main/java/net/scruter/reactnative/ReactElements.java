package net.scruter.reactnative;

import android.view.View;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.webkit.WebView;
import android.widget.HorizontalScrollView;
import android.widget.ScrollView;
import android.widget.TextView;
import androidx.annotation.Nullable;
import com.facebook.react.R;
import com.facebook.react.uimanager.ReactClippingViewGroup;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import net.scruter.bridge.BridgeElement;
import net.scruter.bridge.ElementInspector;

/**
 * What the Android SDK cannot read on React Native's host views (docs/MOBILE.md §20): {@code testID} and {@code
 * nativeID}, Scruter's marks, roles, and the position of a list's items. The other facts are Android's: a {@code
 * Pressable} is clickable, a text input an {@code EditText}, a list a {@code ScrollView}.
 */
final class ReactElements implements ElementInspector {
  private final Map<String, Marks> marks = new HashMap<>();

  @Nullable
  @Override
  public BridgeElement inspect(View v) {
    Object native_ = v.getTag(R.id.view_tag_native_id);
    Object test = v.getTag(R.id.react_test_id);
    // A web view stays what the SDK says it is, whatever role or position the app gives it: the server masks that kind.
    boolean web = isWebHost(v);
    Object role = web ? null : v.getTag(R.id.accessibility_role);
    Integer index = web ? null : listPosition(v);
    if (native_ == null && test == null && role == null && index == null) return null;
    String id = test instanceof String && !((String) test).isEmpty() ? (String) test : null;
    boolean mask = false;
    boolean ignore = false;
    String form = null;
    if (native_ instanceof String) {
      String raw = (String) native_;
      if (raw.startsWith(Marks.PREFIX)) {
        Marks m = marks.get(raw);
        if (m == null) {
          m = Marks.parse(raw);
          if (marks.size() < 500) marks.put(raw, m);
        }
        mask = m.mask;
        ignore = m.ignore;
        form = m.form;
        if (m.id != null) id = m.id;
        if (m.index != null) index = m.index;
      } else if (id == null && !raw.isEmpty()) {
        // §3.5: testID, else nativeID.
        id = raw;
      }
    }
    return new BridgeElement(id, mask, ignore, form, index, null, kind(v, role));
  }

  /** {@code react-native-webview}: the web view, or the host view around it that carries the props. */
  private static boolean isWebHost(View v) {
    if (v instanceof WebView) return true;
    return v instanceof ViewGroup && ((ViewGroup) v).getChildCount() == 1 && ((ViewGroup) v).getChildAt(0) instanceof WebView;
  }

  /** {@code accessibilityRole}, when it says more than the view's class. */
  @Nullable
  private static String kind(View v, @Nullable Object role) {
    if (role == null || v instanceof TextView && !v.isClickable()) return null;
    switch (role.toString().toLowerCase(Locale.ROOT)) {
      case "button":
      case "togglebutton":
      case "imagebutton":
        return "button";
      case "link":
        return "link";
      case "tab":
        return "tab";
      case "checkbox":
      case "radio":
      case "switch":
      case "adjustable":
        return "choice";
      case "image":
        return "image";
      default:
        return null;
    }
  }

  /**
   * {@code FlatList} keeps its items in JavaScript and mounts a window of them between two empty spacers: the position
   * is the rank among the mounted items, plus what the leading spacer stands for. With {@code removeClippedSubviews},
   * Android's default for {@code FlatList}, items out of sight are detached and only the geometry tells. A list is told
   * from a page of sections by those spacers, else by items of one height. Exact with items of one height; {@code
   * ScruterCell} gives the exact index otherwise.
   */
  @Nullable
  private static Integer listPosition(View v) {
    ViewParent parent = v.getParent();
    if (!(parent instanceof ViewGroup)) return null;
    ViewGroup content = (ViewGroup) parent;
    ViewParent scroller = content.getParent();
    boolean vertical = scroller instanceof ScrollView;
    if (!vertical && !(scroller instanceof HorizontalScrollView)) return null;
    if (!isItem(v)) return null;
    int count = content.getChildCount();
    Map<Integer, Integer> sizes = new HashMap<>();
    int cells = 0;
    int rank = -1;
    int common = 0;
    long extent = 0;
    for (int i = 0; i < count; i++) {
      View s = content.getChildAt(i);
      if (!isItem(s)) continue;
      if (s == v) rank = cells;
      cells++;
      int size = size(s, vertical);
      extent += size;
      Integer n = sizes.get(size);
      int seen = n == null ? 1 : n + 1;
      sizes.put(size, seen);
      common = Math.max(common, seen);
    }
    if (rank < 0 || extent <= 0) return null;
    float average = extent / (float) cells;
    boolean clipped = content instanceof ReactClippingViewGroup && ((ReactClippingViewGroup) content).getRemoveClippedSubviews();
    if (clipped && common * 2 >= cells) return Math.round((vertical ? v.getTop() : v.getLeft()) / average);
    if (cells < 3) return null;
    View first = content.getChildAt(0);
    View last = content.getChildAt(count - 1);
    int leading = isItem(first) ? 0 : size(first, vertical);
    int trailing = isItem(last) ? 0 : size(last, vertical);
    if (leading == 0 && trailing == 0 && common * 2 < cells) return null;
    return Math.round(leading / average) + rank;
  }

  private static boolean isItem(View v) {
    return v instanceof ViewGroup && ((ViewGroup) v).getChildCount() > 0;
  }

  private static int size(View v, boolean vertical) {
    return vertical ? v.getHeight() : v.getWidth();
  }
}
