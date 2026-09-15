import 'dart:io';
import 'package:shelf/shelf.dart';

/// Bundled runtime only: no API, uploaded files, or SPA fallback.
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
      // The loader has an opaque origin even when visited directly. Public
      // runtime scripts can be read from that origin without sending cookies.
      'access-control-allow-origin': '*',
      if (name == 'index.html')
        'content-security-policy':
            "sandbox allow-scripts allow-forms; default-src 'none'; "
            "script-src 'unsafe-inline' 'unsafe-eval' blob: https: http:; "
            "style-src 'unsafe-inline' blob: https: http:; "
            "img-src data: blob: https: http:; font-src data: blob: https: http:; "
            "connect-src blob: https: http: wss: ws:; frame-src blob: https: http:; "
            "media-src data: blob: https: http:; "
            "worker-src blob:; base-uri https: http:; form-action https: http:; "
            "object-src 'none'",
    },
  );
};
