/// String rules shared by the SDK's Dart layer (docs/MOBILE.md §3.3, §3.5, §3.9). Limits are counted in code points,
/// like the JSON Schemas.
abstract final class ScruterText {
  static const _sensitive = <String>['card', 'cvc', 'cvv', 'iban', 'pin', 'otp', 'token', 'secret', 'password', 'passwd'];

  /// Removes control and format characters, trims, cuts to [max] code points; `null` when nothing is left.
  static String? clean(String? value, int max) {
    if (value == null) return null;
    final out = StringBuffer();
    for (final c in value.runes) {
      if (c < 0x20 || (c >= 0x7F && c < 0xA0) || c == 0xAD || (c >= 0x200B && c <= 0x200F) || (c >= 0x202A && c <= 0x202E) ||
          (c >= 0x2060 && c <= 0x2064) || c == 0xFEFF) {
        continue;
      }
      out.writeCharCode(c);
    }
    final trimmed = out.toString().trim();
    return trimmed.isEmpty ? null : cut(trimmed, max);
  }

  /// The first [max] code points of [value].
  static String cut(String value, int max) {
    if (value.length <= max) return value;
    final runes = value.runes;
    if (runes.length <= max) return value;
    return String.fromCharCodes(runes.take(max));
  }

  static bool _letter(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
  static bool _digit(int c) => c >= 48 && c <= 57;
  static bool _hex(int c) => _digit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70);

  static final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  /// §3.5: an explicit identifier counts when it starts with a letter, holds only `[A-Za-z0-9_.:-]`, ≤ 60 characters,
  /// no run of 5 digits, not a UUID, no hex run of ≥ 8 mixing digits and letters (generated identifiers change).
  static bool isStableId(String id) {
    final u = id.codeUnits;
    if (u.isEmpty || u.length > 60 || !_letter(u[0])) return false;
    var digits = 0;
    var run = 0;
    var hasDigit = false;
    var hasLetter = false;
    for (final c in u) {
      if (!(_letter(c) || _digit(c) || c == 95 || c == 46 || c == 58 || c == 45)) return false;
      digits = _digit(c) ? digits + 1 : 0;
      if (digits >= 5) return false;
      if (_hex(c)) {
        run++;
        if (_digit(c)) {
          hasDigit = true;
        } else {
          hasLetter = true;
        }
        if (run >= 8 && hasDigit && hasLetter) return false;
      } else {
        run = 0;
        hasDigit = false;
        hasLetter = false;
      }
    }
    return !_uuid.hasMatch(id);
  }

  /// §3.9: a name that says the field holds a secret or a payment detail.
  static bool isSensitiveName(String name) {
    final l = name.toLowerCase();
    return _sensitive.any(l.contains);
  }

  /// §3.5: a type name without generic arguments and leading `_`, ≤ 40 characters; `null` for what cannot be a name
  /// (an obfuscated build's 1–3 characters).
  static String? typeName(String raw) {
    var s = raw;
    final lt = s.indexOf('<');
    if (lt >= 0) s = s.substring(0, lt);
    while (s.startsWith('_')) {
      s = s.substring(1);
    }
    if (s.length <= 3 || !_letter(s.codeUnitAt(0))) return null;
    return cut(s, 40);
  }

  /// A route's name as a screen's (§3.3): no query, no fragment, and in a path-like name the segments that are values
  /// (`/product/42`, a UUID) become `:id`: never the parameters.
  static String routeName(String name) {
    var s = name;
    final cut = s.indexOf(RegExp(r'[?#]'));
    if (cut >= 0) s = s.substring(0, cut);
    if (!s.startsWith('/')) return s;
    return s.split('/').map((p) => _isValue(p) ? ':id' : p).join('/');
  }

  static bool _isValue(String p) {
    if (p.isEmpty) return false;
    if (p.codeUnits.every(_digit)) return true;
    return _uuid.hasMatch(p) || (p.length >= 8 && p.codeUnits.every(_hex) && p.codeUnits.any(_digit));
  }
}
