import 'forms.dart';
import 'scroll.dart';

/// One screen view: engaged time and scroll depth for everyone (`screen_end`) and, in sessions of the Advanced analytics
/// sample, the analysed screen view `x` (docs/MOBILE.md §3.6–§3.9, docs/API.md §5.3): visible and engaged ms, the 50
/// bands, taps, forms, its states numbered 1–10. Pure logic: times in ms, sizes in logical pixels.
class ScreenView {
  ScreenView({
    required this.name,
    required this.session,
    required this.analysed,
    required this.startWall,
    required this.startMono,
    required this.number,
  })  : _lastTick = startMono,
        _lastActive = startMono,
        forms = Forms(name);

  static const bands = 50;
  static const idleMs = 60000;
  static const maxTaps = 300;
  static const tapsPerState = 100;
  static const _maxMs = 86400000;

  final String name;
  final String session;
  final bool analysed;
  final int startWall;
  final int startMono;

  /// `k`: random 1 … 2^53−1, in memory only.
  final int number;
  final Forms forms;

  int _q = 0;
  int _dt = 0;
  int _et = 0;
  int _lastTick;
  int _lastActive;
  final List<int> _at = List<int>.filled(bands, 0);
  double _from = 0;
  double _to = 1;
  bool _hasScroll = false;
  int depth = 0;
  int _interacted = 0;
  int taps = 0;
  int _dead = 0;
  int _rage = 0;
  List<List<Object>> _newTaps = [];
  int _reportedEt = 0;
  int _reportedDepth = -1;
  int vw = 0;
  int vh = 0;
  int ch = 0;
  bool _dirty = true;
  bool visible = true;

  /// Adds the time since the last tick: visible always, engaged while an interaction is under 60 s old (§3.8).
  void tick(int now) {
    if (visible && now > _lastTick) {
      _dt += now - _lastTick;
      final activeUntil = now < _lastActive + idleMs ? now : _lastActive + idleMs;
      final engaged = activeUntil - _lastTick;
      if (engaged > 0) {
        _et += engaged;
        final a = (_from * bands).floor().clamp(0, bands - 1);
        final b = ((_to * bands).ceil() - 1).clamp(a, bands - 1);
        for (var i = a; i <= b; i++) {
          _at[i] += engaged;
        }
        _dirty = true;
      }
    }
    _lastTick = now;
  }

  void interact(int now) {
    tick(now);
    _lastActive = now;
  }

  void suspend(int now) {
    tick(now);
    visible = false;
  }

  void resume(int now) {
    _lastTick = now;
    _lastActive = now;
    visible = true;
  }

  /// The scroll container moved or was measured; [s] null: nothing scrolls (one container of 100 %).
  void scrolled(int now, ScrollInfo? s, {required bool user}) {
    if (user) {
      interact(now);
    } else {
      tick(now);
    }
    if (s == null) {
      if (!_hasScroll) {
        _from = 0;
        _to = 1;
        if (depth < 100) {
          depth = 100;
          _dirty = true;
        }
      }
      return;
    }
    // A container found after the first measure (a list that loaded): the 100 of a screen without one does not hold.
    if (!_hasScroll) depth = 0;
    _hasScroll = true;
    _from = s.from;
    _to = s.to;
    ch = s.content.toInt().clamp(0, 1000000);
    final p = Scrolls.percent(s.depth);
    if (p > depth) {
      depth = p;
      _dirty = true;
    }
    if (user && s.from * s.content >= vh / 2) _interacted = 1;
  }

  /// A tap's record: selector, index, kind, x %, y %, ms since the view started, flags (1 dead, 2 rage).
  void tap(String selector, int index, String kind, int x, int y, int ms, int flags) {
    _interacted = 1;
    if (taps >= maxTaps) return;
    taps++;
    if (flags & 1 != 0) _dead++;
    if (flags & 2 != 0) _rage++;
    _newTaps.add([selector, index, kind, x.clamp(0, 100), y.clamp(0, 100), ms.clamp(0, _maxMs), flags]);
    _dirty = true;
  }

  int get tapsSinceState => _newTaps.length;

  /// The engagement since the last report for `screen_end`: `(ms, depth)`, or null (nothing worth reporting, the
  /// web's rule: not under 1 s unless the depth grew).
  (int, int)? engagement({required bool last}) {
    final delta = _et - _reportedEt;
    final d = _hasScroll || depth > 0 ? depth : 100;
    if (delta < 1000 && d <= _reportedDepth && !(last && _reportedDepth < 0)) return null;
    _reportedEt = _et;
    if (d > _reportedDepth) _reportedDepth = d;
    return (delta, d);
  }

  /// The next state of the analysed screen view, or null (not in the sample, nothing new, or no state number left:
  /// 1–9 for the intermediate ones, the last kept for the end).
  Map<String, Object?>? state({required bool last, required int now}) {
    if (!analysed) return null;
    if (!_dirty && !forms.dirty && _q > 0) return null;
    if (_q >= 10 || (!last && _q >= 9)) return null;
    _q++;
    _dirty = false;
    var used = bands;
    while (used > 0 && _at[used - 1] == 0) {
      used--;
    }
    final o = <String, Object?>{
      's': session,
      'k': number,
      'q': _q,
      'n': name,
      't': startWall,
      'vw': vw.clamp(0, 10000),
      'vh': vh.clamp(0, 10000),
      'ch': (ch > 0 ? ch : vh).clamp(0, 1000000),
      'sd': _hasScroll ? depth : 100,
      'dt': _dt.clamp(0, _maxMs),
      'et': _et.clamp(0, _maxMs),
      'ia': _interacted,
      'at': [for (var i = 0; i < used; i++) _at[i].clamp(0, _maxMs)],
      'cn': taps,
      'cd': _dead,
      'cr': _rage,
    };
    if (_newTaps.isNotEmpty) o['c'] = _newTaps;
    _newTaps = [];
    final f = forms.toJson(now);
    if (f.isNotEmpty) o['f'] = f;
    return o;
  }
}
