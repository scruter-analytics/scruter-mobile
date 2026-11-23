package net.scruter.reactnative;

import androidx.annotation.Nullable;
import java.io.UnsupportedEncodingException;
import java.net.URLDecoder;

/** The marks {@code ScruterView} writes in {@code nativeID}: {@code scruter:m;g;i=<id>;f=<form>;c=<index>}. */
final class Marks {
  static final String PREFIX = "scruter:";

  boolean mask;
  boolean ignore;
  @Nullable String id;
  @Nullable String form;
  @Nullable Integer index;

  static Marks parse(String raw) {
    Marks m = new Marks();
    for (String part : raw.substring(PREFIX.length()).split(";")) {
      if (part.equals("m")) {
        m.mask = true;
      } else if (part.equals("g")) {
        m.ignore = true;
      } else if (part.length() > 2) {
        String value = part.substring(2);
        switch (part.charAt(0)) {
          case 'i':
            m.id = decode(value);
            break;
          case 'f':
            m.form = decode(value);
            break;
          case 'c':
            try {
              m.index = Integer.valueOf(value);
            } catch (NumberFormatException e) {
              m.index = null;
            }
            break;
          default:
            break;
        }
      }
    }
    return m;
  }

  /** encodeURIComponent's output: a `+` is a plus, never a space. */
  private static String decode(String value) {
    try {
      return URLDecoder.decode(value.replace("+", "%2B"), "UTF-8");
    } catch (UnsupportedEncodingException | IllegalArgumentException e) {
      return value;
    }
  }
}
