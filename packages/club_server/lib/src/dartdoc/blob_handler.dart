/// shelf handler that serves dartdoc trees from the BlobStore.
///
/// Request → lookup `index.json` (cached) → resolve byte range →
/// read bytes via `BlobStore.getAssetRange` (cached when small) →
/// return them with appropriate content-type + cache-control headers.
///
/// Only ever serves the `latest` version of a package (see
/// `docs/PLAN_DARTDOC_BLOB_STORAGE.md`). Non-`latest` URL segments
/// redirect to `latest`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:club_core/club_core.dart';
import 'package:club_indexed_blob/club_indexed_blob.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'cache.dart';

final _log = Logger('BlobDartdocHandler');

/// MIME types club will proxy through. Anything not in this map returns
/// 404. Matches pub.dev's `_safeMimeTypes` except we allow `html` and
/// `svg` directly because club trusts its own dartdoc output (private
/// registry, not public untrusted input).
const _mimeTypes = <String, String>{
  'html': 'text/html; charset=utf-8',
  'css': 'text/css; charset=utf-8',
  'js': 'application/javascript; charset=utf-8',
  'json': 'application/json; charset=utf-8',
  'svg': 'image/svg+xml',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'ico': 'image/vnd.microsoft.icon',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'eot': 'application/vnd.ms-fontobject',
  'map': 'application/json; charset=utf-8',
  'txt': 'text/plain; charset=utf-8',
};

/// Inline size cap for the range cache. Larger assets stream straight
/// through without populating the LRU so the budget isn't eaten by one
/// fat file.
const _cacheSizeThreshold = 1024 * 1024;

/// Public cache-control for dartdoc responses. Short TTL so a re-score
/// propagates within a few minutes without any manual purge.
const _cacheControl = 'public, max-age=300';

/// Build a handler that serves `/documentation/<pkg>/<version>/<rest>`
/// out of the BlobStore. [pkg], [version], [rest] come pre-parsed
/// from the router.
///
/// Returns 404 when the package has no dartdoc (i.e. scoring hasn't
/// run yet or was skipped because this isn't the latest version).
/// Returns 302 to `/documentation/<pkg>/latest/<rest>` when a non-
/// `latest` version is requested, since club only stores latest.
typedef BlobDartdocHandler =
    Future<shelf.Response> Function(
      shelf.Request request,
      String pkg,
      String version,
      String rest,
    );

BlobDartdocHandler makeBlobDartdocHandler({
  required BlobStore blobStore,
  required DartdocCache cache,
}) {
  return (
    shelf.Request request,
    String pkg,
    String version,
    String rest,
  ) async {
    // Single-version policy: redirect anything other than `latest`.
    if (version != 'latest') {
      return shelf.Response.found('/documentation/$pkg/latest$rest');
    }

    // Default to index.html when the path is empty or ends in `/`.
    var path = rest;
    if (path.startsWith('/')) path = path.substring(1);
    if (path.isEmpty || path.endsWith('/')) {
      path = '${path}index.html';
    }

    // Resolve + cache the index. Absent index = scoring hasn't produced
    // dartdoc yet (or failed) — surface a 404 rather than a 500.
    final BlobIndex index;
    try {
      index = await _loadIndex(blobStore, cache, pkg);
    } on NotFoundException {
      return _notFound(
        'Documentation is not available for $pkg yet. '
        'Scoring may still be running.',
      );
    } catch (e, st) {
      _log.warning('Failed to load dartdoc index for $pkg: $e', e, st);
      return shelf.Response.internalServerError(
        body: 'Failed to load documentation index.',
      );
    }

    final range = index.lookup(path);
    if (range == null) {
      // dartdoc generates a static 404 page at `/__404error.html`.
      // Mirror pub.dev's behaviour: if we have that file, serve it
      // with HTTP 404 so in-page navigation still styled-404s.
      final fallback = index.lookup('__404error.html');
      if (fallback != null && path != '__404error.html') {
        final bytes = await _loadRange(blobStore, cache, pkg, fallback);
        return _responseFor(
          request,
          bytes,
          extOf('__404error.html'),
          status: 404,
        );
      }
      return _notFound('Not found.');
    }

    final ext = extOf(path);
    if (!_mimeTypes.containsKey(ext)) {
      // Asset type we don't proxy — don't leak arbitrary bytes with
      // unknown content-type. Very unusual; dart doc output only
      // produces types in the allowlist.
      return _notFound('Unsupported file type.');
    }

    final bytes = await _loadRange(blobStore, cache, pkg, range);
    return _responseFor(request, bytes, ext);
  };
}

Future<BlobIndex> _loadIndex(
  BlobStore blobStore,
  DartdocCache cache,
  String pkg,
) async {
  final key = DartdocCacheKeys.index(pkg);
  final cached = await cache.getBytes(key);
  if (cached != null) return BlobIndex.fromBytes(cached);

  final stream = await blobStore.getAsset(pkg, 'dartdoc/latest/index.json');
  final bytes = await _collect(stream);
  await cache.setBytes(key, bytes);
  return BlobIndex.fromBytes(bytes);
}

Future<List<int>> _loadRange(
  BlobStore blobStore,
  DartdocCache cache,
  String pkg,
  FileRange range,
) async {
  final key = DartdocCacheKeys.range(range.blobId, range.path);
  if (range.length <= _cacheSizeThreshold) {
    final cached = await cache.getBytes(key);
    if (cached != null) return cached;
  }
  final stream = await blobStore.getAssetRange(
    pkg,
    'dartdoc/latest/blob',
    range.start,
    range.length,
  );
  final bytes = await _collect(stream);
  if (range.length <= _cacheSizeThreshold) {
    await cache.setBytes(key, bytes);
  }
  return bytes;
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final buf = <int>[];
  await for (final chunk in stream) {
    buf.addAll(chunk);
  }
  return buf;
}

/// Extract the lowercased extension (no dot) from a path. Returns an
/// empty string when there's no extension.
String extOf(String path) {
  final slash = path.lastIndexOf('/');
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot < slash) return '';
  return path.substring(dot + 1).toLowerCase();
}

shelf.Response _notFound(String body) => shelf.Response.notFound(
  body,
  headers: {'content-type': 'text/plain; charset=utf-8'},
);

/// Build the serve response. Files are gzipped individually in the
/// indexed blob, so if the client sent `Accept-Encoding: gzip` we can
/// hand over the raw bytes with `Content-Encoding: gzip`. Otherwise
/// we decompress server-side.
shelf.Response _responseFor(
  shelf.Request request,
  List<int> gzBytes,
  String ext, {
  int status = 200,
}) {
  final mime = _mimeTypes[ext] ?? 'application/octet-stream';
  final acceptsGzip = (request.headers['accept-encoding'] ?? '')
      .toLowerCase()
      .contains('gzip');

  final body = acceptsGzip ? gzBytes : gzip.decode(gzBytes);
  final headers = <String, String>{
    'content-type': mime,
    'cache-control': _cacheControl,
    // Vary on Accept-Encoding since body shape depends on it.
    'vary': 'Accept-Encoding',
    if (acceptsGzip) 'content-encoding': 'gzip',
    'content-length': body.length.toString(),
  };
  return shelf.Response(status, body: body, headers: headers);
}

/// Extract an optional JSON message from the stored bytes, used for
/// diagnostics. Not part of the serve path.
String? tryDecodeJsonMessage(List<int> bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map && decoded['message'] is String) {
      return decoded['message'] as String;
    }
  } catch (_) {}
  return null;
}
