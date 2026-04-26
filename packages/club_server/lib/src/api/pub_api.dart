import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';
import '../middleware/request_url.dart';

/// Handlers for the pub repository spec v2 API endpoints.
///
/// These endpoints are consumed by `dart pub get` and `dart pub publish`.
class PubApi {
  PubApi({
    required this.packageService,
    required this.publishService,
    required this.blobStore,
    required this.metadataStore,
    required this.downloadService,
    this.serverUrlOverride,
  });

  static final _log = Logger('PubApi');

  final PackageService packageService;
  final PublishService publishService;
  final BlobStore blobStore;
  final MetadataStore metadataStore;
  final DownloadService downloadService;
  final Uri? serverUrlOverride;

  Uri _baseUrl(Request request) =>
      resolveBaseUrl(request, configOverride: serverUrlOverride);

  DecodedRouter get router {
    final router = DecodedRouter();

    router.get('/api/packages/<package>', _listVersions);
    router.get('/api/packages/<package>/versions/<version>', _getVersion);
    router.get('/api/archives/<package>-<version>.tar.gz', _downloadArchive);
    router.get(
      '/packages/<package>/versions/<version>.tar.gz',
      _legacyRedirect,
    );
    router.get(
      '/api/packages/<package>/versions/<version>/archive.tar.gz',
      _legacyRedirect,
    );
    router.get('/api/packages/versions/new', _startUpload);
    router.post('/api/packages/versions/upload', _receiveUpload);
    router.get('/api/packages/versions/newUploadFinish', _finalizeUpload);
    router.get(
      '/api/packages/versions/newUploadFinish/<uploadId>',
      _finalizeUploadPath,
    );
    router.get('/api/packages/<package>/score', _getScore);
    router.get(
      '/api/packages/<package>/versions/<version>/score',
      _getScoreVersion,
    );
    router.get(
      '/api/packages/<package>/versions/<version>/content',
      _getVersionContent,
    );
    // Convenience: get latest version content
    router.get('/api/packages/<package>/content', _getLatestContent);

    // Screenshot asset proxy. Public (no auth) so `<img src>` works
    // without credentials; bytes are served from the blob store.
    router.get(
      '/api/packages/<package>/versions/<version>/screenshots/<index>',
      _getScreenshot,
    );

    // README-referenced asset proxy (images, video, pdf, csv, txt the
    // README links to with relative paths). Public for the same reason
    // as screenshots; the rewritten README in `readme_content` points
    // here so the browser can render relative refs without auth.
    router.get(
      '/api/packages/<package>/versions/<version>/readme-assets/<filename>',
      _getReadmeAsset,
    );

    return router;
  }

  Future<Response> _listVersions(Request request, String package) async {
    final data = await packageService.listVersions(
      package,
      baseUrl: _baseUrl(request),
    );
    return _jsonResponse(data.toJson());
  }

  Future<Response> _getVersion(
    Request request,
    String package,
    String version,
  ) async {
    final info = await packageService.getVersion(
      package,
      version,
      baseUrl: _baseUrl(request),
    );
    return _jsonResponse(info.toJson());
  }

  Future<Response> _downloadArchive(
    Request request,
    String package,
    String version,
  ) async {
    // Record the download without blocking the response.
    unawaited(
      downloadService
          .record(package, version)
          .then(
            (_) {},
            onError: (Object e, StackTrace st) =>
                _log.warning('Download tracking failed: $e', e, st),
          ),
    );

    final signedUrl = await blobStore.signedDownloadUrl(package, version);
    if (signedUrl != null) {
      return Response.found(signedUrl.toString());
    }
    final stream = await blobStore.get(package, version);
    final info = await blobStore.info(package, version);
    return Response.ok(
      stream,
      headers: {
        'content-type': 'application/gzip',
        if (info != null) 'content-length': info.sizeBytes.toString(),
      },
    );
  }

  Future<Response> _legacyRedirect(
    Request request,
    String package,
    String version,
  ) async {
    return Response.seeOther(
      Uri.parse('/api/archives/$package-$version.tar.gz'),
    );
  }

  Future<Response> _startUpload(Request request) async {
    final user = requireAuthUser(request);
    final result = await publishService.startUpload(
      user.userId,
      baseUrl: _baseUrl(request),
    );
    return _jsonResponse(result);
  }

  Future<Response> _receiveUpload(Request request) async {
    requireAuthUser(request);

    final contentType = request.headers['content-type'] ?? '';
    String? uploadId;

    if (contentType.contains('multipart/form-data')) {
      final boundary = _extractBoundary(contentType);
      if (boundary == null) {
        throw const InvalidInputException('Missing multipart boundary.');
      }
      uploadId = await _handleMultipartUpload(request, boundary);
    } else {
      uploadId = request.url.queryParameters['upload_id'];
      if (uploadId != null) {
        final session = await publishService.lookupSession(uploadId);
        if (session != null) {
          await _streamBodyToFile(request.read(), session.tempPath);
        }
      }
    }

    if (uploadId == null || uploadId.isEmpty) {
      throw const InvalidInputException('Missing upload_id.');
    }

    await publishService.markReceived(uploadId);

    // Must be an absolute URL — dart pub client doesn't resolve relative redirects
    final base = _baseUrl(request);
    final finalizeUrl = base.resolve(
      '/api/packages/versions/newUploadFinish?upload_id=$uploadId',
    );

    return Response.found(finalizeUrl);
  }

  Future<Response> _finalizeUpload(Request request) async {
    final user = requireAuthUser(request);
    final uploadId = request.url.queryParameters['upload_id'];
    if (uploadId == null || uploadId.isEmpty) {
      throw const InvalidInputException('Missing upload_id.');
    }
    return _doFinalize(uploadId, user.userId, _forceFlag(request));
  }

  Future<Response> _finalizeUploadPath(Request request, String uploadId) async {
    final user = requireAuthUser(request);
    return _doFinalize(uploadId, user.userId, _forceFlag(request));
  }

  Future<Response> _doFinalize(
    String uploadId,
    String userId,
    bool force,
  ) async {
    final message = await publishService.finalize(
      uploadId,
      userId,
      force: force,
    );
    return _jsonResponse({
      'success': {'message': message},
    });
  }

  /// `?force=true` on the finalize URL authorises overwriting an existing
  /// version with different content. Club extension over the pub spec.
  bool _forceFlag(Request request) =>
      request.url.queryParameters['force']?.toLowerCase() == 'true';

  Future<Response> _getScore(Request request, String package) async {
    final score = await packageService.getScore(package);
    return _jsonResponse(score.toJson());
  }

  Future<Response> _getScoreVersion(
    Request request,
    String package,
    String version,
  ) async {
    final score = await packageService.getScore(package, version: version);
    return _jsonResponse(score.toJson());
  }

  Future<Response> _getVersionContent(
    Request request,
    String package,
    String version,
  ) async {
    final pv = await metadataStore.lookupVersion(package, version);
    if (pv == null) throw NotFoundException.version(package, version);
    return _jsonResponse(_buildContentPayload(pv, _baseUrl(request)));
  }

  Future<Response> _getLatestContent(Request request, String package) async {
    final pkg = await metadataStore.lookupPackage(package);
    if (pkg == null) throw NotFoundException.package(package);
    final version = pkg.latestVersion;
    if (version == null) throw NotFoundException.package(package);
    final pv = await metadataStore.lookupVersion(package, version);
    if (pv == null) throw NotFoundException.version(package, version);
    return _jsonResponse(_buildContentPayload(pv, _baseUrl(request)));
  }

  /// Serve screenshot bytes from the blob store. The `<index>` path segment
  /// is the zero-based position of the screenshot in the pubspec-declared
  /// list, with its extension (e.g. `0.png`). Resolving by index (not by
  /// filename) keeps the URL space stable even if the author later adds
  /// screenshots with the same basename but from different directories.
  Future<Response> _getScreenshot(
    Request request,
    String package,
    String version,
    String index,
  ) async {
    final pv = await metadataStore.lookupVersion(package, version);
    if (pv == null) throw NotFoundException.version(package, version);

    // Accept either `0` or `0.png` — tolerate the extension when present so
    // the URL is slightly self-describing in logs, but also work without it.
    var idxStr = index;
    final dot = idxStr.indexOf('.');
    if (dot > 0) idxStr = idxStr.substring(0, dot);
    final i = int.tryParse(idxStr);
    if (i == null || i < 0 || i >= pv.screenshots.length) {
      throw const NotFoundException('Screenshot not found.');
    }

    final meta = pv.screenshots[i];
    final assetKey = '$version/screenshots/$i';
    final stream = await blobStore.getAsset(package, assetKey);
    final info = await blobStore.assetInfo(package, assetKey);

    return Response.ok(
      stream,
      headers: {
        'content-type': meta.mimeType,
        // Screenshots are immutable per-version — safe to cache hard. A
        // re-published (forced) version overwrites the bytes but clients
        // rarely hold a version's URL across a forced re-publish.
        'cache-control': 'public, max-age=31536000, immutable',
        if (info != null) 'content-length': info.sizeBytes.toString(),
      },
    );
  }

  /// Serve README-referenced asset bytes from the blob store. The
  /// `<filename>` segment is `<index>.<extension>` — both halves were
  /// baked into the rewritten README at publish time, so an arbitrary
  /// extension here is treated as a 404 (we never accept a different
  /// extension for the same index).
  Future<Response> _getReadmeAsset(
    Request request,
    String package,
    String version,
    String filename,
  ) async {
    final dot = filename.indexOf('.');
    if (dot <= 0 || dot >= filename.length - 1) {
      throw const NotFoundException('Readme asset not found.');
    }
    final indexStr = filename.substring(0, dot);
    final ext = filename.substring(dot + 1).toLowerCase();
    final i = int.tryParse(indexStr);
    if (i == null || i < 0) {
      throw const NotFoundException('Readme asset not found.');
    }
    final mime = readmeAssetMimeFor(ext);
    if (mime == null) {
      throw const NotFoundException('Readme asset not found.');
    }

    final assetKey = '$version/readme-assets/$i.$ext';
    final info = await blobStore.assetInfo(package, assetKey);
    if (info == null) {
      throw const NotFoundException('Readme asset not found.');
    }
    final stream = await blobStore.getAsset(package, assetKey);

    return Response.ok(
      stream,
      headers: {
        'content-type': mime,
        // Same immutability rationale as screenshots — once published, a
        // version's README assets don't change (force-republish writes
        // fresh assets but clients rarely cache across that).
        'cache-control': 'public, max-age=31536000, immutable',
        'content-length': info.sizeBytes.toString(),
      },
    );
  }

  Map<String, Object?> _buildContentPayload(
    PackageVersion pv,
    Uri baseUrl,
  ) {
    final screenshots = <Map<String, Object?>>[];
    for (var i = 0; i < pv.screenshots.length; i++) {
      final s = pv.screenshots[i];
      final ext = screenshotExtOf(s.path);
      screenshots.add({
        'url': baseUrl
            .resolve(
              '/api/packages/${pv.packageName}/versions/${pv.version}'
              '/screenshots/$i.$ext',
            )
            .toString(),
        'description': s.description,
        'path': s.path,
        'mimeType': s.mimeType,
      });
    }
    return {
      'package': pv.packageName,
      'version': pv.version,
      'readme': pv.readmeContent,
      'changelog': pv.changelogContent,
      'example': pv.exampleContent,
      'examplePath': pv.examplePath,
      'binExecutables': pv.binExecutables,
      'screenshots': screenshots,
    };
  }

  // ── Helpers ─────────────────────────────────────────────────

  Response _jsonResponse(Object data) => Response.ok(
    jsonEncode(data),
    headers: {'content-type': 'application/vnd.pub.v2+json'},
  );

  String? _extractBoundary(String contentType) {
    final match = RegExp(r'boundary=(.+)').firstMatch(contentType);
    return match?.group(1)?.trim();
  }

  /// Parse multipart form data using MimeMultipartTransformer.
  Future<String?> _handleMultipartUpload(
    Request request,
    String boundary,
  ) async {
    final transformer = MimeMultipartTransformer(boundary);
    final parts = await transformer.bind(request.read()).toList();

    String? uploadId;
    List<int>? fileBytes;

    for (final part in parts) {
      final disposition = part.headers['content-disposition'] ?? '';
      final bytes = await part.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );

      if (disposition.contains('name="upload_id"')) {
        uploadId = utf8.decode(bytes).trim();
      } else if (disposition.contains('name="file"') ||
          disposition.contains('filename=')) {
        fileBytes = bytes;
      }
    }

    if (uploadId == null) return null;

    if (fileBytes != null) {
      final session = await publishService.lookupSession(uploadId);
      if (session != null) {
        final file = File(session.tempPath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(fileBytes);
      }
    }

    return uploadId;
  }

  Future<void> _streamBodyToFile(Stream<List<int>> stream, String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    await for (final chunk in stream) {
      sink.add(chunk);
    }
    await sink.flush();
    await sink.close();
  }
}
