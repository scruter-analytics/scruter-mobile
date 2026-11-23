import 'package:flutter/foundation.dart';

/// A Dart stack trace as the report's frames (docs/API.md §5.3, docs/MOBILE.md §3.10, §6.6). Two forms:
/// - symbolic: `#0  Cart.add (package:atelier/cart.dart:12:3)`, the default of debug and of release builds without
///   `--split-debug-info`: function, file, line, column;
/// - non-symbolic, what `--split-debug-info` or `--obfuscate` leave in a release build: a header naming the snapshot's
///   build id, then `#00 abs 000000723d6346d7 virt 00000000001ed6d7 _kDartIsolateSnapshotInstructions+0x1e26d7` lines:
///   the virtual address, read against that build's symbols (`upload_symbols`). The snapshot is image 0, its load address
///   `0x0` since frames carry virtual addresses.
class DartStack {
  DartStack(this.frames, this.images, this.buildId);

  static const maxFrames = 64;

  final List<Map<String, Object?>> frames;
  final List<Map<String, Object?>> images;
  final String? buildId;

  static final _symbolic = RegExp(r'^#\d+\s+(.+?) \((.+?)(?::(\d+))?(?::(\d+))?\)$');
  static final _absolute = RegExp(r'^\s*#\d+\s+abs\s+([0-9a-fA-F]+)(?:\s+virt\s+([0-9a-fA-F]+))?');
  static final _build = RegExp(r"^build_id:\s*'([0-9a-fA-F]+)'");
  static final _arch = RegExp(r'^os:\s*\S+\s+arch:\s*(\S+)');
  static final _base = RegExp(r'^isolate_dso_base:\s*([0-9a-fA-F]+)');

  static DartStack parse(StackTrace stack) {
    String? build;
    String? arch;
    int? base;
    final frames = <Map<String, Object?>>[];
    for (final line in stack.toString().split('\n')) {
      if (frames.length >= maxFrames) break;
      final l = line.trimRight();
      if (l.isEmpty) continue;
      final sym = _symbolic.firstMatch(l);
      if (sym != null) {
        final file = sym.group(2)!;
        frames.add(<String, Object?>{
          'fn': sym.group(1)!,
          'fl': file,
          if (sym.group(3) != null) 'l': int.parse(sym.group(3)!),
          if (sym.group(4) != null) 'co': int.parse(sym.group(4)!),
          'ia': _inApp(file),
        });
        continue;
      }
      final abs = _absolute.firstMatch(l);
      if (abs != null) {
        final virt = abs.group(2);
        final address = virt != null ? int.tryParse(virt, radix: 16) : _relative(abs.group(1)!, base);
        if (address != null) frames.add(<String, Object?>{'a': '0x${address.toRadixString(16)}', 'i': 0});
        continue;
      }
      build ??= _build.firstMatch(l)?.group(1);
      arch ??= _arch.firstMatch(l)?.group(1);
      final b = _base.firstMatch(l)?.group(1);
      if (b != null) base = int.tryParse(b, radix: 16);
    }
    if (frames.isEmpty) frames.add(<String, Object?>{'fn': '?'});
    final nonSymbolic = frames.first.containsKey('a');
    final images = !nonSymbolic || build == null
        ? const <Map<String, Object?>>[]
        : <Map<String, Object?>>[
            <String, Object?>{
              'n': defaultTargetPlatform == TargetPlatform.iOS ? 'App' : 'libapp.so',
              'u': build,
              'la': '0x0',
              if (arch != null) 'ar': arch,
            },
          ];
    return DartStack(frames, images, build);
  }

  static int? _relative(String abs, int? base) {
    final a = int.tryParse(abs, radix: 16);
    return a == null || base == null || a < base ? null : a - base;
  }

  static bool _inApp(String file) =>
      !(file.startsWith('dart:') || file.startsWith('org-dartlang-sdk:') || file.contains('package:flutter/') ||
          file.contains('package:scruter_flutter/'));
}
