import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:club_core/club_core.dart';
import 'package:crypto/crypto.dart';
import 'package:minio/minio.dart';

/// Configuration for [S3BlobStore].
///
/// `endpoint` may be null for AWS S3 (the SDK derives the host from `region`).
/// For Cloudflare R2, set `endpoint` to `https://<account>.r2.cloudflarestorage.com`
/// and `region` to `auto`.
class S3BlobStoreConfig {
  const S3BlobStoreConfig({
    required this.bucket,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    this.endpoint,
    this.pathStyle,
  });

  final String bucket;
  final String region;
  final String accessKey;
  final String secretKey;
  final String? endpoint;

  /// Force path-style addressing (`endpoint/bucket/key`) instead of
  /// virtual-host (`bucket.endpoint/key`). Default null = SDK auto-detect.
  final bool? pathStyle;
}

/// S3-compatible [BlobStore] implementation. Works with AWS S3, MinIO,
/// Cloudflare R2, DigitalOcean Spaces, Backblaze B2, and any other
/// S3-compatible service.
///
/// Layout in the bucket (mirrors the filesystem store):
///   * `<package>/<version>/artifacts/package.tar.gz` — the archive
///   * `<package>/<version>/artifacts/package.json`   — sidecar with
///                                                      {size, sha256, createdAt}
///   * `<package>/<version>/screenshots/<index>`      — per-version assets
///
/// The sidecar exists because [BlobInfo.sha256Hex] is computed while
/// streaming the upload. S3 only allows setting object metadata at PUT
/// time, so we'd need a second metadata-only copy to attach the SHA. A
/// tiny sidecar object is simpler and avoids the extra copy.
class S3BlobStore implements BlobStore {
  S3BlobStore(this.config);

  final S3BlobStoreConfig config;
  late final Minio _client;

  String _archiveKey(String pkg, String ver) =>
      '$pkg/$ver/artifacts/package.tar.gz';
  String _sidecarKey(String pkg, String ver) =>
      '$pkg/$ver/artifacts/package.json';

  @override
  Future<void> open() async {
    final ep = config.endpoint;
    String host;
    int? port;
    bool useSsl;

    if (ep == null || ep.isEmpty) {
      // AWS S3: SDK builds the host from the region.
      host = 's3.${config.region}.amazonaws.com';
      port = null;
      useSsl = true;
    } else {
      final uri = Uri.parse(ep);
      host = uri.host;
      port = uri.hasPort ? uri.port : null;
      useSsl = uri.scheme.toLowerCase() != 'http';

      // Reject plaintext endpoints unless they're clearly local — credentials
      // would otherwise traverse the network unencrypted.
      final isLoopback =
          host == 'localhost' ||
          host == '127.0.0.1' ||
          host == '::1' ||
          host == 'minio'; // common docker-compose service name
      if (!useSsl && !isLoopback) {
        throw StateError(
          'S3_ENDPOINT must use https:// (got "$ep"). Plaintext endpoints '
          'are only allowed for localhost/MinIO development.',
        );
      }
    }

    _client = Minio(
      endPoint: host,
      port: port,
      useSSL: useSsl,
      accessKey: config.accessKey,
      secretKey: config.secretKey,
      region: config.region,
      pathStyle: config.pathStyle,
    );

    // Fail fast on misconfig (wrong creds, wrong bucket, etc).
    final exists = await _client.bucketExists(config.bucket);
    if (!exists) {
      throw StateError(
        'S3 bucket "${config.bucket}" does not exist or is not accessible '
        'with the provided credentials.',
      );
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<BlobInfo> put(
    String package,
    String version,
    Stream<List<int>> bytes, {
    bool overwrite = false,
  }) async {
    final archiveKey = _archiveKey(package, version);

    // Best-effort check; matches FilesystemBlobStore. Two simultaneous
    // first-publishes of the same version can both pass this check and
    // race on the PUT — the database-side uniqueness constraint in
    // PublishService is the authoritative guard.
    if (!overwrite && await _objectExists(archiveKey)) {
      throw ConflictException('Archive for $package $version already exists.');
    }

    final accumulator = _AccumulatorSink<Digest>();
    final hasher = sha256.startChunkedConversion(accumulator);
    var size = 0;

    final tee = bytes.map((chunk) {
      hasher.add(chunk);
      size += chunk.length;
      return chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    });

    try {
      await _client.putObject(
        config.bucket,
        archiveKey,
        tee,
        metadata: const {'content-type': 'application/octet-stream'},
      );
    } catch (_) {
      hasher.close();
      rethrow;
    }
    hasher.close();
    final shaHex = accumulator.events.single.toString();
    final createdAt = DateTime.now().toUtc();

    // Sidecar carries metadata that statObject can't give us (sha256) and
    // pins createdAt to upload time rather than relying on lastModified.
    final sidecar = utf8.encode(
      jsonEncode({
        'size': size,
        'sha256': shaHex,
        'createdAt': createdAt.toIso8601String(),
      }),
    );
    try {
      await _client.putObject(
        config.bucket,
        _sidecarKey(package, version),
        Stream.value(Uint8List.fromList(sidecar)),
        size: sidecar.length,
        metadata: const {'content-type': 'application/json'},
      );
    } catch (_) {
      // Sidecar failed — roll back the archive so we don't leave a blob
      // without its metadata. info() would then return null and the
      // package would appear corrupt.
      try {
        await _client.removeObject(config.bucket, archiveKey);
      } catch (_) {}
      rethrow;
    }

    return BlobInfo(
      package: package,
      version: version,
      sizeBytes: size,
      sha256Hex: shaHex,
      createdAt: createdAt,
    );
  }

  @override
  Future<Stream<List<int>>> get(String package, String version) async {
    final key = _archiveKey(package, version);
    try {
      final stream = await _client.getObject(config.bucket, key);
      return stream;
    } on MinioError catch (e) {
      if (_isNotFound(e)) {
        throw NotFoundException(
          'Archive for $package $version not found.',
        );
      }
      rethrow;
    }
  }

  @override
  Future<BlobInfo?> info(String package, String version) async {
    final sidecarKey = _sidecarKey(package, version);
    try {
      final stream = await _client.getObject(config.bucket, sidecarKey);
      final bytes = <int>[];
      await for (final chunk in stream) {
        bytes.addAll(chunk);
      }
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return BlobInfo(
        package: package,
        version: version,
        sizeBytes: json['size'] as int,
        sha256Hex: json['sha256'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      );
    } on MinioError catch (e) {
      if (_isNotFound(e)) return null;
      rethrow;
    }
  }

  @override
  Future<bool> exists(String package, String version) async {
    return _objectExists(_archiveKey(package, version));
  }

  @override
  Future<void> delete(String package, String version) async {
    try {
      await _client.removeObjects(
        config.bucket,
        [_archiveKey(package, version), _sidecarKey(package, version)],
      );
    } on MinioError catch (e) {
      // Match FilesystemBlobStore: deleting a non-existent blob is a no-op.
      if (_isNotFound(e)) return;
      rethrow;
    }
  }

  @override
  Future<List<String>> listVersions(String package) async {
    // Archive key shape: `<package>/<version>/artifacts/package.tar.gz`.
    // Walking recursively and filtering by suffix is robust against
    // S3's common-prefix semantics, which can miss objects when the
    // bucket already has a matching `<package>/` prefix at the root.
    final prefix = '$package/';
    const suffix = '/artifacts/package.tar.gz';
    final versions = <String>[];
    await for (final result in _client.listObjects(
      config.bucket,
      prefix: prefix,
      recursive: true,
    )) {
      for (final obj in result.objects) {
        final key = obj.key;
        if (key == null || !key.endsWith(suffix)) continue;
        final mid = key.substring(
          prefix.length,
          key.length - suffix.length,
        );
        // mid is the version segment; bail if it contains a slash
        // (defence against unexpected nesting).
        if (mid.isEmpty || mid.contains('/')) continue;
        versions.add(mid);
      }
    }
    return versions;
  }

  @override
  Future<List<String>> listPackages() async {
    final packages = <String>[];
    await for (final result in _client.listObjects(
      config.bucket,
      prefix: '',
      recursive: false,
    )) {
      for (final prefix in result.prefixes) {
        // Common prefixes look like "<package>/" — strip the trailing slash.
        final p = prefix.endsWith('/')
            ? prefix.substring(0, prefix.length - 1)
            : prefix;
        if (p.isNotEmpty) packages.add(p);
      }
    }
    return packages;
  }

  @override
  Future<Uri?> signedDownloadUrl(
    String package,
    String version, {
    Duration expiry = const Duration(hours: 1),
  }) async {
    // SigV4 caps presigned URLs at 7 days.
    const maxExpiry = Duration(days: 7);
    final clamped = expiry > maxExpiry ? maxExpiry : expiry;
    final url = await _client.presignedGetObject(
      config.bucket,
      _archiveKey(package, version),
      expires: clamped.inSeconds,
    );
    return Uri.parse(url);
  }

  // ── Per-package assets ─────────────────────────────────────────
  //
  // Asset keys are stored alongside the archive under `<package>/<assetKey>`.
  // Keys are not validated here — `FilesystemBlobStore` is the only backend
  // that needs path-traversal guards; S3 key space is flat.

  @override
  Future<BlobInfo> putAsset(
    String package,
    String assetKey,
    Stream<List<int>> bytes,
  ) async {
    final accumulator = _AccumulatorSink<Digest>();
    final hasher = sha256.startChunkedConversion(accumulator);
    var size = 0;

    final tee = bytes.map((chunk) {
      hasher.add(chunk);
      size += chunk.length;
      return chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    });

    try {
      await _client.putObject(
        config.bucket,
        '$package/$assetKey',
        tee,
        metadata: const {'content-type': 'application/octet-stream'},
      );
    } catch (_) {
      hasher.close();
      rethrow;
    }
    hasher.close();
    return BlobInfo(
      package: package,
      version: assetKey,
      sizeBytes: size,
      sha256Hex: accumulator.events.single.toString(),
      createdAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<Stream<List<int>>> getAsset(String package, String assetKey) async {
    try {
      return await _client.getObject(config.bucket, '$package/$assetKey');
    } on MinioError catch (e) {
      if (_isNotFound(e)) {
        throw NotFoundException('Asset $assetKey for $package not found.');
      }
      rethrow;
    }
  }

  @override
  Future<Stream<List<int>>> getAssetRange(
    String package,
    String assetKey,
    int offset,
    int length,
  ) async {
    if (offset < 0 || length < 0) {
      throw ArgumentError(
        'offset and length must be non-negative (got $offset, $length)',
      );
    }
    // Minio's getPartialObject asserts `length > 0`, so a caller asking
    // for a zero-byte slice gets an empty stream without a network round-
    // trip. Matches the filesystem backend's behaviour.
    if (length == 0) return const Stream<List<int>>.empty();
    try {
      return await _client.getPartialObject(
        config.bucket,
        '$package/$assetKey',
        offset,
        length,
      );
    } on MinioError catch (e) {
      if (_isNotFound(e)) {
        throw NotFoundException('Asset $assetKey for $package not found.');
      }
      rethrow;
    }
  }

  @override
  Future<BlobInfo?> assetInfo(String package, String assetKey) async {
    try {
      final stat = await _client.statObject(
        config.bucket,
        '$package/$assetKey',
        retrieveAcls: false,
      );
      return BlobInfo(
        package: package,
        version: assetKey,
        sizeBytes: stat.size ?? 0,
        // `statObject` doesn't expose the SHA we stored at put time, and the
        // only caller that reads `assetInfo` consumes sizeBytes — leave the
        // hash empty rather than re-reading the object just to rehash it.
        sha256Hex: '',
        createdAt: stat.lastModified?.toUtc() ?? DateTime.now().toUtc(),
      );
    } on MinioError catch (e) {
      if (_isNotFound(e)) return null;
      rethrow;
    }
  }

  @override
  Future<void> deleteAssetsUnder(String package, String prefix) async {
    final keys = <String>[];
    await for (final result in _client.listObjects(
      config.bucket,
      prefix: '$package/$prefix',
      recursive: true,
    )) {
      for (final obj in result.objects) {
        final key = obj.key;
        if (key != null) keys.add(key);
      }
    }
    if (keys.isEmpty) return;
    try {
      await _client.removeObjects(config.bucket, keys);
    } on MinioError catch (e) {
      if (_isNotFound(e)) return;
      rethrow;
    }
  }

  @override
  Future<void> deleteAsset(String package, String assetKey) async {
    try {
      await _client.removeObject(config.bucket, '$package/$assetKey');
    } on MinioError catch (e) {
      if (_isNotFound(e)) return;
      rethrow;
    }
  }

  Future<bool> _objectExists(String key) async {
    try {
      // Cloudflare R2 rejects the ACL sub-request that statObject sends by
      // default, so we must opt out. AWS S3 accepts either way.
      await _client.statObject(config.bucket, key, retrieveAcls: false);
      return true;
    } on MinioError catch (e) {
      if (_isNotFound(e)) return false;
      rethrow;
    }
  }

  bool _isNotFound(MinioError e) {
    if (e is MinioS3Error) {
      // `error` is minio's own `Error` model, which shadows dart core
      // `Error` if imported. Access via dynamic to skip the type clash.
      final code = (e.error as dynamic)?.code;
      if (code == 'NoSuchKey' || code == 'NotFound' || code == 'Not Found') {
        return true;
      }
      if (e.response?.statusCode == 404) return true;
    }
    final msg = e.message?.toLowerCase() ?? '';
    return msg.contains('not found') || msg.contains('does not exist');
  }
}

/// Collects chunked-conversion outputs so `sha256.startChunkedConversion`
/// can hand us a single `Digest` when closed.
class _AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];

  @override
  void add(T event) => events.add(event);

  @override
  void close() {}
}
