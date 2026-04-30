import 'package:shelf/shelf.dart';

/// Resolve the public-facing base URL from the request.
///
/// Priority (industry standard):
/// 1. Config override (`SERVER_URL` env var) — if explicitly set
/// 2. `X-Forwarded-Proto` + `X-Forwarded-Host` — set by reverse proxy
/// 3. `Forwarded` header (RFC 7239)
/// 4. Request `Host` header + scheme
Uri resolveBaseUrl(Request request, {Uri? configOverride}) {
  if (configOverride != null) return configOverride;

  final headers = request.headers;

  // X-Forwarded-* (most common — Caddy, nginx, AWS ALB)
  final forwardedHost = headers['x-forwarded-host'];
  final forwardedProto = headers['x-forwarded-proto'] ?? 'https';
  if (forwardedHost != null) {
    return Uri.parse(
      '$forwardedProto://${forwardedHost.split(',').first.trim()}',
    );
  }

  // RFC 7239 Forwarded header
  final forwarded = headers['forwarded'];
  if (forwarded != null) {
    final parts = forwarded.split(';').first.split(',').first;
    String? host;
    String proto = 'https';
    for (final param in parts.split(';')) {
      final kv = param.trim().split('=');
      if (kv.length == 2) {
        final key = kv[0].trim().toLowerCase();
        final value = kv[1].trim().replaceAll('"', '');
        if (key == 'host') host = value;
        if (key == 'proto') proto = value;
      }
    }
    if (host != null) return Uri.parse('$proto://$host');
  }

  // Fall back to Host header
  final host = headers['host'] ?? request.requestedUri.host;
  final scheme = request.requestedUri.scheme.isNotEmpty
      ? request.requestedUri.scheme
      : 'http';
  return Uri.parse('$scheme://$host');
}
