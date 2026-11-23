import 'package:flutter/material.dart';

import 'text.dart';
import 'tree.dart';

/// The forms of one screen view (docs/MOBILE.md §3.9): fields grouped by a [ScruterForm], else by a `Form` with an
/// explicit identifier, else by the screen. Per field: focus count and time, `changed`, errors — never a value, never
/// its length, never a label. Passwords, one-time codes and payment fields are ignored entirely. Caps: 10 forms of 40
/// fields, as the web.
class Forms {
  Forms(this._screen);

  static const required = 1;
  static const format = 2;
  static const refused = 4;
  static const invalid = 8;
  static const _maxMs = 86400000;

  final String _screen;
  final Map<String, _Form> _forms = {};
  final Map<Element, _Ref> _byElement = {};
  final Map<FocusNode, _Ref> _byFocus = {};
  final List<VoidCallback> _detach = [];
  _Ref? _focused;
  bool dirty = false;

  /// Finds the fields of [tree]: at the screen view's start, at focus changes, after taps. [edited] is called on an
  /// edit, which only says that an edit happened.
  void scan(ScreenTree tree, void Function() edited) {
    final positions = <String, int>{};
    for (final n in tree.nodes) {
      if (!n.isField) continue;
      final element = n.fieldElement ?? n.element;
      if (_byElement.containsKey(element) || _sensitive(n)) continue;
      final name = n.form ?? _screen;
      final form = _forms[name] ?? _newForm(name);
      if (form == null || form.fields.length >= 40) continue;
      final position = positions[name] ?? form.fields.length;
      positions[name] = position + 1;
      final type = fieldType(n);
      final key = _key(n, type, position);
      final field = form.fields[key] ??= _Field(key, type, position);
      dirty = true;
      field.element = element;
      final ref = _Ref(form, field);
      _byElement[element] = ref;
      final editable = n.editable;
      if (editable != null) {
        _byFocus[editable.focusNode] = ref;
        final controller = editable.controller;
        var last = controller.text.hashCode;
        void listener() {
          final h = controller.text.hashCode;
          if (h == last) return;
          last = h;
          _changed(ref);
          edited();
        }

        controller.addListener(listener);
        _detach.add(() => controller.removeListener(listener));
      }
    }
  }

  _Form? _newForm(String name) {
    if (_forms.length >= 10) return null;
    final f = _Form(ScruterText.cut(name, 120), _forms.length);
    _forms[name] = f;
    dirty = true;
    return f;
  }

  static bool _sensitive(TreeNode n) {
    if (n.explicit && ScruterText.isSensitiveName(n.part)) return true;
    final e = n.editable;
    if (e != null) {
      if (e.obscureText || e.keyboardType == TextInputType.visiblePassword) return true;
      for (final h in n.autofillHints ?? const <String>[]) {
        final l = h.toLowerCase();
        if (l.contains('password') || l.contains('creditcard') || l.contains('onetimecode') || l.contains('otp') ||
            ScruterText.isSensitiveName(h)) {
          return true;
        }
      }
    }
    return false;
  }

  /// The field's type (`fd[1]`).
  static String fieldType(TreeNode n) {
    final e = n.editable;
    if (e == null) return n.choice ?? 'choice';
    if (e.maxLines != 1) return 'textarea';
    final t = e.keyboardType;
    if (t == TextInputType.number) return 'number';
    if (t == TextInputType.phone) return 'phone';
    if (t == TextInputType.datetime) return 'date';
    if (t == TextInputType.emailAddress) return 'email';
    if (t == TextInputType.url) return 'url';
    if (t == TextInputType.streetAddress) return 'address';
    if (t == TextInputType.name) return 'name';
    return 'text';
  }

  /// §3.9: the explicit identifier, else the autofill type, else `type:position`.
  static String _key(TreeNode n, String type, int position) {
    if (n.explicit) return ScruterText.cut(n.part.substring(1), 100);
    for (final h in n.autofillHints ?? const <String>[]) {
      // Flutter's name for what iOS and Android call `emailAddress`: one key across platforms.
      final key = h == AutofillHints.email ? 'emailAddress' : h;
      if (ScruterText.isStableId(key)) return ScruterText.cut(key, 100);
    }
    return '$type:$position';
  }

  /// The primary focus moved.
  void focus(FocusNode? node, int now) {
    final next = node == null ? null : _byFocus[node];
    final prev = _focused;
    if (identical(prev?.field, next?.field)) return;
    if (prev != null) _blur(prev, now);
    _focused = next;
    if (next != null) _focusOn(next, now);
  }

  void _focusOn(_Ref r, int now) {
    r.field.focusCount++;
    r.field.focusSince = now;
    if (r.form.started == 0) {
      r.form.started = 1;
      r.form.firstFocus = now;
    }
    r.form.lastField = r.field.key;
    dirty = true;
  }

  void _blur(_Ref r, int now) {
    final f = r.field;
    if (f.focusSince > 0) f.focusMs += now - f.focusSince;
    f.focusSince = 0;
    _checkError(f);
    dirty = true;
  }

  void _changed(_Ref r) {
    if (r.field.changed == 0) {
      r.field.changed = 1;
      dirty = true;
    }
  }

  /// A choice was tapped: it counts as focused, then changed.
  void choiceTapped(Element element, int now) {
    final r = _byElement[element];
    if (r == null) return;
    _focusOn(r, now);
    r.field.focusSince = 0;
    _changed(r);
  }

  bool _checkError(_Field f) {
    final e = f.element;
    final error = e != null && e.mounted && _shows(e);
    if (error && !f.showsError) {
      f.errors++;
      f.kinds |= invalid;
      dirty = true;
    }
    f.showsError = error;
    return error;
  }

  /// The error [InputDecoration] draws (`errorText`, `error`, which a `TextFormField`'s validator fills), or the error
  /// of a choice's `FormField`. Only that one is showing, never what it says.
  static bool _shows(Element e) {
    final w = e.widget;
    if (w is TextField) {
      final d = w.decoration;
      return d != null && (d.errorText != null || d.error != null);
    }
    var shown = false;
    void up(Element x) {
      x.visitAncestorElements((a) {
        if (a is StatefulElement && a.state is FormFieldState) {
          shown = (a.state as FormFieldState).hasError;
          return false;
        }
        return a.widget is! Form;
      });
    }

    up(e);
    return shown;
  }

  /// A button of the screen was tapped: a submit attempt, refused when a field then shows an error.
  void submitAttempt() {
    for (final form in _forms.values) {
      if (form.started == 0 || form.sent == 1) continue;
      var refusedNow = false;
      for (final f in form.fields.values) {
        if (_checkError(f)) refusedNow = true;
      }
      if (refusedNow) {
        form.refused++;
        dirty = true;
      }
    }
  }

  /// `Scruter.fieldError(key, kind)`.
  void explicitError(String key, int kind) {
    for (final form in _forms.values) {
      final f = form.fields[key];
      if (f == null) continue;
      f.errors++;
      f.kinds |= kind;
      dirty = true;
    }
  }

  /// `Scruter.formSent(name)`, or the automatic rule at a forward navigation.
  void sent(String? name, int now) {
    for (final form in _forms.values) {
      if ((name != null && form.name != name) || form.sent == 1) continue;
      form.sent = 1;
      if (form.firstFocus > 0) form.fillMs = now - form.firstFocus;
      dirty = true;
    }
  }

  /// §3.9: leaving the screen forward after a field changed, with no field showing an error, sends the form.
  void leaveForward(int now) {
    leave(now);
    for (final form in _forms.values) {
      if (form.sent == 1 || !form.fields.values.any((f) => f.changed == 1)) continue;
      var error = false;
      for (final f in form.fields.values) {
        if (_checkError(f)) error = true;
      }
      if (!error) sent(form.name, now);
    }
  }

  void leave(int now) {
    final f = _focused;
    if (f != null) _blur(f, now);
    _focused = null;
  }

  /// Stops watching the fields: the screen view is over.
  void dispose() {
    for (final d in _detach) {
      d();
    }
    _detach.clear();
  }

  List<Map<String, Object?>> toJson(int now) {
    dirty = false;
    return [
      for (final form in _forms.values)
        {
          's': form.name,
          'i': form.index,
          'v': 1,
          'b': form.started,
          'ok': form.sent,
          'rf': form.refused,
          'ms': form.fillMs.clamp(0, _maxMs),
          if (form.lastField != null) 'lf': form.lastField,
          'fd': [
            for (final f in form.fields.values)
              [
                f.key,
                ScruterText.cut(f.type, 30),
                0,
                f.position.clamp(0, 255),
                f.focusCount.clamp(0, 65535),
                (f.focusMs + (f.focusSince > 0 ? now - f.focusSince : 0)).clamp(0, _maxMs),
                f.errors.clamp(0, 65535),
                f.kinds & 15,
                f.changed,
              ],
          ],
        },
    ];
  }
}

class _Field {
  _Field(this.key, this.type, this.position);

  final String key;
  final String type;
  final int position;
  int focusCount = 0;
  int focusMs = 0;
  int errors = 0;
  int kinds = 0;
  int changed = 0;
  int focusSince = 0;
  bool showsError = false;
  Element? element;
}

class _Form {
  _Form(this.name, this.index);

  final String name;
  final int index;
  int started = 0;
  int sent = 0;
  int refused = 0;
  int firstFocus = 0;
  int fillMs = 0;
  String? lastField;
  final Map<String, _Field> fields = {};
}

class _Ref {
  _Ref(this.form, this.field);

  final _Form form;
  final _Field field;
}
