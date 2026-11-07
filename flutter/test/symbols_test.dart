import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../bin/upload_symbols.dart' as tool;

/// A minimal ELF64 with one note section holding a GNU build id.
Uint8List elf(List<int> id) {
  final note = BytesBuilder()
    ..add(_u32(4))
    ..add(_u32(id.length))
    ..add(_u32(3))
    ..add(ascii.encode('GNU\u0000'))
    ..add(id);
  final body = note.takeBytes();
  const header = 64;
  final shoff = header + body.length;
  final out = ByteData(shoff + 64 * 2);
  final b = out.buffer.asUint8List();
  b.setRange(0, 4, [0x7F, 0x45, 0x4C, 0x46]);
  b[4] = 2;
  b[5] = 1;
  out.setUint64(40, shoff, Endian.little);
  out.setUint16(58, 64, Endian.little);
  out.setUint16(60, 2, Endian.little);
  b.setRange(header, header + body.length, body);
  final s = shoff + 64;
  out.setUint32(s + 4, 7, Endian.little);
  out.setUint64(s + 24, header, Endian.little);
  out.setUint64(s + 32, body.length, Endian.little);
  return b;
}

Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

class Fake {
  Fake(this.server) {
    server.listen(_serve);
  }

  static Future<Fake> start() async => Fake(await HttpServer.bind('127.0.0.1', 0));

  final HttpServer server;
  final List<String> paths = [];
  final List<Map<String, dynamic>> bodies = [];
  List<String>? missing;
  Uint8List? put;
  String? auth;
  int createStatus = 201;

  String get url => 'http://127.0.0.1:${server.port}';

  Future<void> _serve(HttpRequest r) async {
    final bytes = await r.fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c));
    final body = bytes.takeBytes();
    paths.add('${r.method} ${r.uri.path}');
    auth = r.headers.value('authorization') ?? auth;
    r.response.statusCode = 200;
    if (r.method == 'PUT') {
      put = body;
    } else if (r.uri.path.endsWith('/missing')) {
      final b = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      bodies.add(b);
      final ids = missing ?? [for (final f in b['files'] as List) (f as Map)['debug_id'] as String];
      r.response.write(jsonEncode({
        'missing': [
          for (final id in ids) {'kind': 'flutter_symbols', 'debug_id': id},
        ],
      }));
    } else if (r.uri.path == '/m/v1/symbols') {
      bodies.add(jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
      r.response.statusCode = createStatus;
      if (createStatus == 201) {
        r.response.write(jsonEncode({
          'id': 'f1',
          'upload': {'method': 'PUT', 'url': '$url/bucket/f1', 'headers': {'Content-Type': 'application/octet-stream'}},
        }));
      } else {
        r.response.write(jsonEncode({'error': {'code': 'conflict', 'message': 'x'}}));
      }
    } else {
      r.response.statusCode = 202;
      r.response.write('{}');
    }
    await r.response.close();
  }
}

void main() {
  late Directory project;
  late Fake fake;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('symbols-test');
    Directory('${project.path}/build/symbols').createSync(recursive: true);
    Directory('${project.path}/lib').createSync();
    File('${project.path}/lib/main.dart').writeAsStringSync("void main() { Scruter.start(appId: 'ATMONA02'); }");
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: x\nversion: 2.3.0+230\n');
    File('${project.path}/build/symbols/app.android-arm64.symbols').writeAsBytesSync(elf(List.filled(20, 0xAB)));
    File('${project.path}/build/symbols/notes.txt').writeAsStringSync('x');
    fake = await Fake.start();
  });

  tearDown(() async {
    await fake.server.close(force: true);
    await project.delete(recursive: true);
  });

  Future<(int, String, String)> run(List<String> args, {Map<String, String>? env}) async {
    final o = File('${project.path}/out')..createSync();
    final e = File('${project.path}/err')..createSync();
    final os = o.openWrite();
    final es = e.openWrite();
    final code = await tool.run(args, env ?? {'SCRUTER_UPLOAD_TOKEN': 'scr_up_x', 'SCRUTER_API': fake.url}, project, os, es);
    await os.close();
    await es.close();
    return (code, o.readAsStringSync(), e.readAsStringSync());
  }

  test('reads a GNU build id, an arch, a pubspec, the app id in the sources', () {
    expect(tool.debugIdOf(File('${project.path}/build/symbols/app.android-arm64.symbols')), 'ab' * 20);
    expect(tool.archOf('app.android-arm64.symbols'), 'arm64');
    expect(tool.archOf('app.ios-arm64.symbols'), 'arm64');
    expect(tool.pubspecVersion(project), ('2.3.0', '230'));
    expect(tool.appIdInSources(project), 'ATMONA02');
  });

  test('uploads what the server misses: the §4.3 sequence, gzipped', () async {
    final (code, out, _) = await run(['build/symbols']);
    expect(code, 0);
    expect(out, contains('uploaded'));
    expect(fake.paths, [
      'POST /m/v1/symbols/missing',
      'POST /m/v1/symbols',
      'PUT /bucket/f1',
      'POST /m/v1/symbols/f1/complete',
    ]);
    expect(fake.auth, 'Bearer scr_up_x');
    final create = fake.bodies[1];
    expect(create['app'], 'ATMONA02');
    expect(create['platform'], 'flutter');
    expect(create['kind'], 'flutter_symbols');
    expect(create['debug_id'], 'ab' * 20);
    expect(create['app_version'], '2.3.0');
    expect(create['build'], '230');
    expect(create['arch'], 'arm64');
    expect(create['size'], fake.put!.length);
    expect(gzip.decode(fake.put!), elf(List.filled(20, 0xAB)));
    final dir = Directory('build/conformance')..createSync(recursive: true);
    File('${dir.path}/symbols#upload--create.json').writeAsStringSync(jsonEncode(create));
    File('${dir.path}/symbols#missing--missing.json').writeAsStringSync(jsonEncode(fake.bodies[0]));
  });

  test('skips what the server has, and a 409', () async {
    fake.missing = [];
    expect((await run([])).$1, 0);
    expect(fake.paths, ['POST /m/v1/symbols/missing']);
    fake.missing = null;
    fake.createStatus = 409;
    fake.paths.clear();
    expect((await run([])).$1, 0);
    expect(fake.paths.last, 'POST /m/v1/symbols');
  });

  test('a build never fails for its symbols, unless --strict', () async {
    final none = await run([], env: {});
    expect(none.$1, 0);
    expect(none.$3, contains('SCRUTER_UPLOAD_TOKEN'));
    expect((await run(['--strict'], env: {})).$1, 1);
    expect((await run(['--strict', 'nowhere'])).$1, 1);
    expect((await run(['nowhere'])).$1, 0);
    expect((await run(['--strict', '--app', 'bad id'])).$1, 1);
  });

  test('the token never reaches the output', () async {
    final r = await run(['--strict', 'nowhere']);
    expect(r.$2 + r.$3, isNot(contains('scr_up_x')));
  });
}
