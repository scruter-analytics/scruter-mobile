// Uploads a Flutter build's `--split-debug-info` symbols, so that Dart crash reports become readable
// (docs/MOBILE.md §4.3: POST /m/v1/symbols/missing, POST /m/v1/symbols, PUT to the presigned URL, POST …/complete).
//
//   flutter build ipa --split-debug-info=build/symbols
//   SCRUTER_UPLOAD_TOKEN=scr_up_… dart run scruter_flutter:upload_symbols build/symbols
//
// The token comes from the environment, never from the project (App settings › SDK, kept in your CI's secrets). A build
// never fails for its symbols unless --strict. Run `--help` for the options.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _usage = '''
Usage: dart run scruter_flutter:upload_symbols [options] [directory]

  directory        where --split-debug-info wrote (default build/symbols)
  --app ID         the "App identifier" (default \$SCRUTER_APP_ID, else Scruter.start(appId: …) in lib/)
  --api URL        the API (default \$SCRUTER_API, else https://api.scruter.net)
  --version V      app version (default pubspec.yaml)
  --build B        build number (default pubspec.yaml)
  --dry-run        lists the files and their debug ids, uploads nothing
  --strict         exit 1 on an error (default: warn and exit 0, a build never fails for symbols)

Needs SCRUTER_UPLOAD_TOKEN=scr_up_… in the environment.''';

class SymbolsError implements Exception {
  SymbolsError(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<void> main(List<String> args) async {
  exitCode = await run(args, Platform.environment, Directory.current, stdout, stderr);
}

/// Runs the tool: 0, or 1 with `--strict` on an error.
Future<int> run(List<String> args, Map<String, String> env, Directory project, IOSink out, IOSink err) async {
  String? app = env['SCRUTER_APP_ID'];
  var api = env['SCRUTER_API'] ?? 'https://api.scruter.net';
  String? version;
  String? build;
  var strict = false;
  var dryRun = false;
  String? dir;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String value() => ++i < args.length ? args[i] : '';
    switch (a) {
      case '--app':
        app = value();
      case '--api':
        api = value();
      case '--version':
        version = value();
      case '--build':
        build = value();
      case '--strict':
        strict = true;
      case '--dry-run':
        dryRun = true;
      case '-h' || '--help':
        out.writeln(_usage);
        return 0;
      default:
        dir = a;
    }
  }
  try {
    if (dryRun) {
      final path = dir ?? 'build/symbols';
      for (final f in Directory(path.startsWith('/') ? path : '${project.path}/$path').listSync().whereType<File>()) {
        if (f.path.endsWith('.symbols')) out.writeln('${f.uri.pathSegments.last} ${debugIdOf(f) ?? 'no build id'}');
      }
      return 0;
    }
    final token = env['SCRUTER_UPLOAD_TOKEN'] ?? '';
    if (token.isEmpty) throw SymbolsError('SCRUTER_UPLOAD_TOKEN is not set: symbols not uploaded (App settings › SDK)');
    if (!token.startsWith('scr_up_')) throw SymbolsError('SCRUTER_UPLOAD_TOKEN is not an upload token (scr_up_…)');
    app ??= appIdInSources(project);
    if (app == null) throw SymbolsError('no app id: use --app ATMONA02');
    if (!RegExp(r'^[A-Z0-9_-]{1,32}$').hasMatch(app)) throw SymbolsError('$app is not an app id');
    final pub = pubspecVersion(project);
    final uploader = Uploader(app, api.replaceAll(RegExp(r'/+$'), ''), token, version ?? pub.$1, build ?? pub.$2, out);
    try {
      final path = dir ?? 'build/symbols';
      await uploader.upload(Directory(path.startsWith('/') ? path : '${project.path}/$path'));
    } finally {
      uploader.close();
    }
    return 0;
  } on SymbolsError catch (e) {
    return _fail(err, e.message, strict);
  } on _Status catch (e) {
    return _fail(err, 'the server answered ${e.status}', strict);
  } on IOException catch (e) {
    return _fail(err, '$e', strict);
  }
}

int _fail(IOSink err, String message, bool strict) {
  err.writeln('${strict ? 'error' : 'warning'}: Scruter: $message');
  return strict ? 1 : 0;
}

/// `Scruter.start(appId: 'ATMONA02')` in the project's own sources.
String? appIdInSources(Directory project) {
  final lib = Directory('${project.path}/lib');
  if (!lib.existsSync()) return null;
  final re = RegExp(r'''Scruter\.start\(\s*appId:\s*['"]([A-Z0-9_-]{1,32})['"]''');
  for (final f in lib.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    final m = re.firstMatch(f.readAsStringSync());
    if (m != null) return m.group(1);
  }
  return null;
}

/// `(version, build)` from `version: 2.3.0+230`.
(String, String) pubspecVersion(Directory project) {
  final f = File('${project.path}/pubspec.yaml');
  if (!f.existsSync()) return ('', '');
  final m = RegExp(r'^version:\s*([^\s+#]+)(?:\+([^\s#]+))?', multiLine: true).firstMatch(f.readAsStringSync());
  return (m?.group(1) ?? '', m?.group(2) ?? '');
}

/// The architecture in `app.android-arm64.symbols`, `app.ios-arm64.symbols`.
String archOf(String fileName) {
  final m = RegExp(r'^app\.(?:[a-z]+)-([a-z0-9_]+)\.symbols$').firstMatch(fileName);
  return m?.group(1) ?? '';
}

/// The debug id of a symbols file: an ELF's GNU build id, or a Mach-O's UUID, as the Dart VM prints them.
String? debugIdOf(File file) {
  final raf = file.openSync();
  try {
    final head = raf.readSync(64);
    if (head.length < 32) return null;
    if (head[0] == 0x7F && head[1] == 0x45 && head[2] == 0x4C && head[3] == 0x46) return _elfBuildId(raf, head);
    final magic = ByteData.sublistView(head).getUint32(0, Endian.little);
    if (magic == 0xFEEDFACF) return _machoUuid(raf);
    return null;
  } finally {
    raf.closeSync();
  }
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String? _elfBuildId(RandomAccessFile raf, Uint8List head) {
  final is64 = head[4] == 2;
  if (head[5] != 1) return null;
  final h = ByteData.sublistView(head);
  final shoff = is64 ? h.getUint64(40, Endian.little) : h.getUint32(32, Endian.little);
  final shentsize = h.getUint16(is64 ? 58 : 46, Endian.little);
  final shnum = h.getUint16(is64 ? 60 : 48, Endian.little);
  if (shoff == 0 || shnum == 0 || shentsize < 40) return null;
  for (var i = 0; i < shnum; i++) {
    raf.setPositionSync(shoff + i * shentsize);
    final s = ByteData.sublistView(raf.readSync(shentsize));
    if (s.getUint32(4, Endian.little) != 7) continue; // SHT_NOTE
    final offset = is64 ? s.getUint64(24, Endian.little) : s.getUint32(16, Endian.little);
    final size = is64 ? s.getUint64(32, Endian.little) : s.getUint32(20, Endian.little);
    if (size < 16 || size > 4096) continue;
    raf.setPositionSync(offset);
    final note = raf.readSync(size);
    final n = ByteData.sublistView(note);
    var at = 0;
    while (at + 12 <= size) {
      final namesz = n.getUint32(at, Endian.little);
      final descsz = n.getUint32(at + 4, Endian.little);
      final type = n.getUint32(at + 8, Endian.little);
      final name = at + 12;
      final desc = name + ((namesz + 3) & ~3);
      if (desc + descsz > size) break;
      if (type == 3 && namesz == 4 && String.fromCharCodes(note.sublist(name, name + 3)) == 'GNU') {
        return _hex(note.sublist(desc, desc + descsz));
      }
      at = desc + ((descsz + 3) & ~3);
    }
  }
  return null;
}

String? _machoUuid(RandomAccessFile raf) {
  raf.setPositionSync(0);
  final head = ByteData.sublistView(raf.readSync(32));
  final ncmds = head.getUint32(16, Endian.little);
  final sizeofcmds = head.getUint32(20, Endian.little);
  if (sizeofcmds > 1 << 24) return null;
  final cmds = raf.readSync(sizeofcmds);
  final c = ByteData.sublistView(cmds);
  var at = 0;
  for (var i = 0; i < ncmds && at + 8 <= sizeofcmds; i++) {
    final cmd = c.getUint32(at, Endian.little);
    final size = c.getUint32(at + 4, Endian.little);
    if (cmd == 0x1B && size >= 24) return _hex(cmds.sublist(at + 8, at + 24)); // LC_UUID
    if (size == 0) break;
    at += size;
  }
  return null;
}

class Uploader {
  Uploader(this.app, this.api, this.token, this.version, this.build, this.out);

  final String app;
  final String api;
  final String token;
  final String version;
  final String build;
  final IOSink out;
  final HttpClient _http = HttpClient();

  void close() => _http.close(force: true);

  Future<void> upload(Directory dir) async {
    if (!dir.existsSync()) throw SymbolsError('${dir.path} does not exist: build with --split-debug-info=${dir.path}');
    final files = <String, File>{};
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.symbols')) continue;
      final id = debugIdOf(f);
      if (id == null) {
        out.writeln('Scruter: ${f.path}: no build id, skipped');
        continue;
      }
      files[id] = f;
    }
    if (files.isEmpty) throw SymbolsError('no .symbols file with a build id in ${dir.path}');
    final answer = await _json('POST', '/m/v1/symbols/missing', {
      'app': app,
      'files': [
        for (final id in files.keys) {'kind': 'flutter_symbols', 'debug_id': id},
      ],
    });
    final missing = [for (final m in answer['missing'] as List<dynamic>? ?? const []) (m as Map)['debug_id'] as String];
    out.writeln('Scruter: ${files.length} symbols files, ${missing.length} to upload');
    for (final id in missing) {
      final f = files[id];
      if (f != null) await _one(id, f);
    }
  }

  Future<void> _one(String id, File file) async {
    final name = file.uri.pathSegments.last;
    final tmp = await Directory.systemTemp.createTemp('scruter-symbols');
    try {
      final gz = File('${tmp.path}/$name.gz');
      await file.openRead().transform(gzip.encoder).pipe(gz.openWrite());
      final size = gz.lengthSync();
      final digest = await sha256.bind(gz.openRead()).first;
      final Map<String, dynamic> created;
      try {
        created = await _json('POST', '/m/v1/symbols', {
          'app': app,
          'platform': 'flutter',
          'kind': 'flutter_symbols',
          'debug_id': id,
          if (version.isNotEmpty) 'app_version': version,
          if (build.isNotEmpty) 'build': build,
          if (archOf(name).isNotEmpty) 'arch': archOf(name),
          'file_name': '$name.gz',
          'size': size,
          'sha256': digest.toString(),
        });
      } on _Status catch (e) {
        if (e.status == 409) {
          out.writeln('Scruter: $name is already there');
          return;
        }
        rethrow;
      }
      final upload = created['upload'] as Map<String, dynamic>;
      final request = await _http.openUrl(upload['method'] as String? ?? 'PUT', Uri.parse(upload['url'] as String));
      (upload['headers'] as Map<String, dynamic>? ?? const {}).forEach((k, v) => request.headers.set(k, v as String));
      request.contentLength = size;
      await request.addStream(gz.openRead());
      final put = await request.close();
      await put.drain<void>();
      if (put.statusCode >= 300) throw SymbolsError('upload of $name refused (${put.statusCode})');
      await _json('POST', '/m/v1/symbols/${created['id']}/complete', null);
      out.writeln('Scruter: $name uploaded (${size ~/ 1024} KB)');
    } on _Status catch (e) {
      throw SymbolsError('$name: the server answered ${e.status}');
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  Future<Map<String, dynamic>> _json(String method, String path, Object? body) async {
    for (var attempt = 0;; attempt++) {
      final request = await _http.openUrl(method, Uri.parse('$api$path'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        return text.isEmpty ? const {} : jsonDecode(text) as Map<String, dynamic>;
      }
      if ((status == 429 || status >= 500) && attempt < 3) {
        final wait = int.tryParse(response.headers.value(HttpHeaders.retryAfterHeader) ?? '') ?? (2 << attempt);
        await Future<void>.delayed(Duration(seconds: wait));
        continue;
      }
      if (status == 401) throw SymbolsError('the upload token is unknown or revoked (App settings › SDK)');
      if (status == 403) throw SymbolsError('this upload token is not the app $app');
      throw _Status(status);
    }
  }
}

class _Status implements Exception {
  _Status(this.status);

  final int status;

  @override
  String toString() => 'status $status';
}
