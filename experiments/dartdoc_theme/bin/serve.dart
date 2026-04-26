// Tiny static-file server to view the dartdoc-generated site.
//
// Usage:
//   dart run bin/serve.dart                  # serves output/themed if present, else baseline
//   dart run bin/serve.dart baseline         # serves work/<pkg>/doc/api
//   dart run bin/serve.dart themed           # serves output/themed
//   dart run bin/serve.dart <relative_path>  # serves the given dir
//
// Pass --port=NNNN to override the default 5413.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';

Future<void> main(List<String> args) async {
  final scriptDir = p.dirname(Platform.script.toFilePath());
  final root = p.normalize(p.join(scriptDir, '..'));

  var port = 5413;
  final positional = <String>[];
  for (final a in args) {
    if (a.startsWith('--port=')) {
      port = int.parse(a.substring('--port='.length));
    } else {
      positional.add(a);
    }
  }

  final mode = positional.isNotEmpty ? positional[0] : 'auto';
  String dir;
  switch (mode) {
    case 'baseline':
      dir = _findBaselineApiDir(root);
      break;
    case 'themed':
      dir = p.join(root, 'output', 'themed');
      break;
    case 'auto':
      final themed = Directory(p.join(root, 'output', 'themed'));
      dir = themed.existsSync() ? themed.path : _findBaselineApiDir(root);
      break;
    default:
      dir = p.isAbsolute(mode) ? mode : p.normalize(p.join(root, mode));
  }

  if (!Directory(dir).existsSync()) {
    stderr.writeln('Directory does not exist: $dir');
    exit(1);
  }

  final handler = const Pipeline()
      .addMiddleware(_noCache())
      .addMiddleware(logRequests())
      .addHandler(createStaticHandler(dir, defaultDocument: 'index.html'));

  final server = await io.serve(handler, '127.0.0.1', port);
  stdout.writeln('Serving $dir');
  stdout.writeln('  → http://${server.address.host}:${server.port}');
  stdout.writeln('Ctrl+C to stop.');
}

Middleware _noCache() {
  return (Handler inner) {
    return (Request req) async {
      final res = await inner(req);
      return res.change(headers: {'cache-control': 'no-store'});
    };
  };
}

String _findBaselineApiDir(String root) {
  final work = Directory(p.join(root, 'work'));
  if (!work.existsSync()) {
    stderr.writeln('No work/ dir. Run: dart run bin/setup.dart');
    exit(1);
  }
  // First subdir with doc/api/index.html.
  for (final entry in work.listSync().whereType<Directory>()) {
    final api = p.join(entry.path, 'doc', 'api');
    if (File(p.join(api, 'index.html')).existsSync()) return api;
  }
  stderr.writeln('No generated dartdoc found under work/. Run setup first.');
  exit(1);
}
