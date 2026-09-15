import 'dart:io';
import 'package:shelf/shelf.dart';

/// Dedicated listener: no API, credentials, uploaded files, or SPA fallback.
Handler siteRunnerHandler(String root) => (request) async {
  const allowed = {
    'index.html': 'text/html',
    'runner.js': 'text/javascript',
    'runtime.js': 'text/javascript',
    'parser.js': 'text/javascript',
    'parser.LICENSE': 'text/plain',
    'untar.js': 'text/javascript',
  };
  final name = request.url.path.isEmpty ? 'index.html' : request.url.path;
  if (!['GET', 'HEAD'].contains(request.method) || !allowed.containsKey(name)) {
    return Response.notFound('Not found');
  }
  final file = File('$root/$name');
  if (!await file.exists()) {
    return Response.notFound('Runner build unavailable');
  }
  return Response.ok(
    request.method == 'HEAD' ? null : file.openRead(),
    headers: {
      'content-type': allowed[name]!,
      'cache-control': 'no-cache',
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
    },
  );
};
