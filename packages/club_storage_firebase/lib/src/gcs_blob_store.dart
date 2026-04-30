import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:club_core/club_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:googleapis/storage/v1.dart' as gcs;
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:pointycastle/api.dart' show PrivateKeyParameter;
import 'package:pointycastle/asymmetric/api.dart' show RSAPrivateKey;
import 'package:pointycastle/digests/sha256.dart' show SHA256Digest;
import 'package:pointycastle/signers/rsa_signer.dart' show RSASigner;

/// Configuration for [GcsBlobStore].
///
/// Auth resolution priority: [credentialsFile] > [credentialsJson] > ADC.
/// When both credential fields are null, falls back to Application Default
/// Credentials (GCE/GKE metadata server, `gcloud auth application-default
/// login`, or `GOOGLE_APPLICATION_CREDENTIALS`).
class GcsBlobStoreConfig {
  const GcsBlobStoreConfig({
    required this.bucket,
    this.credentialsFile,
    this.credentialsJson,
  });

  final String bucket;
  final String? credentialsFile;
  final String? credentialsJson;
}

/// Google Cloud Storage / Firebase Storage [BlobStore] implementation.
///
/// Firebase Storage buckets are plain GCS buckets (default bucket name:
/// `<project-id>.appspot.com`). This implementation targets the GCS JSON API
/// directly and signs download URLs locally when a service-account key is
/// available.
///
/// Layout in the bucket (mirrors the filesystem + S3 stores):
///   * `<package>/<version>/artifacts/package.tar.gz` — the archive
///   * `<package>/<version>/artifacts/package.json`   — sidecar with
///                                                      {size, sha256, createdAt}
///   * `<package>/<version>/screenshots/<index>`      — per-version assets
///
/// The sidecar mirrors the S3 implementation's shape: SHA-256 is computed
/// while streaming the upload, and GCS only accepts object metadata at PUT
/// time, so we write a tiny companion object instead of rewriting metadata.
class GcsBlobStore implements BlobStore {
  GcsBlobStore(this.config);

  final GcsBlobStoreConfig config;

  late final auth.AutoRefreshingAuthClient _http;
  late final gcs.StorageApi _api;

  /// Populated when credentials were supplied via file or inline JSON. Null
  /// under ADC — in which case we cannot generate V4 signed URLs locally and
  /// [signedDownloadUrl] returns null so the server proxies bytes instead.
  auth.ServiceAccountCredentials? _saCreds;

  String _archiveKey(String pkg, String ver) =>
      '$pkg/$ver/artifacts/package.tar.gz';
  String _sidecarKey(String pkg, String ver) =>
      '$pkg/$ver/artifacts/package.json';

  @override
  Future<void> open() async {
    const scopes = [gcs.StorageApi.devstorageReadWriteScope];

    final file = config.credentialsFile;
    final inline = config.credentialsJson;
    if (file != null && file.isNotEmpty) {
      final json = await File(file).readAsString();
      _saCreds = auth.ServiceAccountCredentials.fromJson(json);
      _http = await auth.clientViaServiceAccount(_saCreds!, scopes);
    } else if (inline != null && inline.isNotEmpty) {
      _saCreds = auth.ServiceAccountCredentials.fromJson(inline);
      _http = await auth.clientViaServiceAccount(_saCreds!, scopes);
    } else {
      _saCreds = null;
      _http = await auth.clientViaApplicationDefaultCredentials(scopes: scopes);
    }
    _api = gcs.StorageApi(_http);

    try {
      await _api.buckets.get(config.bucket);
    } on gcs.DetailedApiRequestError catch (e) {
      throw StateError(
        'GCS bucket "${config.bucket}" is not accessible: '
        '${e.message ?? "HTTP ${e.status}"}',
      );
    }
  }

  @override
  Future<void> close() async {
    _http.close();
  }

  @override
  Future<BlobInfo> put(
    String package,
    String version,
    Stream<List<int>> bytes, {
    bool overwrite = false,
  }) async {
    final archiveKey = _archiveKey(package, version);

    // Best-effort pre-flight check; matches FilesystemBlobStore semantics.
    // The authoritative guard for duplicate publishes lives in the DB.
    if (!overwrite && await exists(package, version)) {
      throw ConflictException('Archive for $package $version already exists.');
    }

    final accumulator = _AccumulatorSink<crypto.Digest>();
    final hasher = crypto.sha256.startChunkedConversion(accumulator);
    var size = 0;

    final tee = bytes.map((chunk) {
      hasher.add(chunk);
      size += chunk.length;
      return chunk;
    });

    try {
      await _api.objects.insert(
        gcs.Object(),
        config.bucket,
        name: archiveKey,
        // Stream length is unknown up front — resumable uploads accept a
        // null-length Media and chunk the body for us.
        uploadMedia: gcs.Media(
          tee,
          null,
          contentType: 'application/octet-stream',
        ),
        uploadOptions: gcs.ResumableUploadOptions(),
      );
    } catch (_) {
      hasher.close();
      rethrow;
    }
    hasher.close();
    final shaHex = accumulator.events.single.toString();
    final createdAt = DateTime.now().toUtc();

    final sidecarBytes = utf8.encode(
      jsonEncode({
        'size': size,
        'sha256': shaHex,
        'createdAt': createdAt.toIso8601String(),
      }),
    );
    try {
      await _api.objects.insert(
        gcs.Object(),
        config.bucket,
        name: _sidecarKey(package, version),
        uploadMedia: gcs.Media(
          Stream.value(Uint8List.fromList(sidecarBytes)),
          sidecarBytes.length,
          contentType: 'application/json',
        ),
      );
    } catch (_) {
      // Sidecar failed — roll back the archive so we don't leave an orphan
      // without readable metadata.
      try {
        await _api.objects.delete(config.bucket, archiveKey);
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
    try {
      final media =
          await _api.objects.get(
                config.bucket,
                _archiveKey(package, version),
                downloadOptions: gcs.DownloadOptions.fullMedia,
              )
              as gcs.Media;
      return media.stream;
    } on gcs.DetailedApiRequestError catch (e) {
      if (e.status == 404) {
        throw NotFoundException(
          'Archive for $package $version not found.',
        );
      }
      rethrow;
    }
  }

  @override
  Future<BlobInfo?> info(String package, String version) async {
    try {
      final media =
          await _api.objects.get(
                config.bucket,
                _sidecarKey(package, version),
                downloadOptions: gcs.DownloadOptions.fullMedia,
              )
              as gcs.Media;
      final buf = <int>[];
      await for (final chunk in media.stream) {
        buf.addAll(chunk);
      }
      final json = jsonDecode(utf8.decode(buf)) as Map<String, dynamic>;
      return BlobInfo(
        package: package,
        version: version,
        sizeBytes: json['size'] as int,
        sha256Hex: json['sha256'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      );
    } on gcs.DetailedApiRequestError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<bool> exists(String package, String version) async {
    try {
      await _api.objects.get(config.bucket, _archiveKey(package, version));
      return true;
    } on gcs.DetailedApiRequestError catch (e) {
      if (e.status == 404) return false;
      rethrow;
    }
  }

  @override
  Future<void> delete(String package, String version) async {
    for (final key in [
      _archiveKey(package, version),
      _sidecarKey(package, version),
    ]) {
      try {
        await _api.objects.delete(config.bucket, key);
      } on gcs.DetailedApiRequestError catch (e) {
        // Match FilesystemBlobStore: deleting a non-existent blob is a no-op.
        if (e.status != 404) rethrow;
      }
    }
  }

  @override
  Future<List<String>> listVersions(String package) async {
    // Archive key shape: `<package>/<version>/artifacts/package.tar.gz`.
    // Walk the prefix recursively (no delimiter) and match on the full
    // suffix so we pick up version dirs exactly.
    final prefix = '$package/';
    const suffix = '/artifacts/package.tar.gz';
    final names = <String>[];
    String? pageToken;
    do {
      final resp = await _api.objects.list(
        config.bucket,
        prefix: prefix,
        pageToken: pageToken,
      );
      for (final item in resp.items ?? const <gcs.Object>[]) {
        final name = item.name;
        if (name == null || !name.endsWith(suffix)) continue;
        final mid = name.substring(
          prefix.length,
          name.length - suffix.length,
        );
        if (mid.isEmpty || mid.contains('/')) continue;
        names.add(mid);
      }
      pageToken = resp.nextPageToken;
    } while (pageToken != null);
    return names;
  }

  @override
  Future<List<String>> listPackages() async {
    final packages = <String>[];
    String? pageToken;
    do {
      final resp = await _api.objects.list(
        config.bucket,
        delimiter: '/',
        pageToken: pageToken,
      );
      for (final p in resp.prefixes ?? const <String>[]) {
        final name = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
        if (name.isNotEmpty) packages.add(name);
      }
      pageToken = resp.nextPageToken;
    } while (pageToken != null);
    return packages;
  }

  // ── Per-package assets ─────────────────────────────────────────
  //
  // Asset objects live at `<package>/<assetKey>` in the same bucket as the
  // archive. GCS key space is flat; no path-traversal guard needed here.

  @override
  Future<BlobInfo> putAsset(
    String package,
    String assetKey,
    Stream<List<int>> bytes,
  ) async {
    final accumulator = _AccumulatorSink<crypto.Digest>();
    final hasher = crypto.sha256.startChunkedConversion(accumulator);
    var size = 0;

    final tee = bytes.map((chunk) {
      hasher.add(chunk);
      size += chunk.length;
      return chunk;
    });

    try {
      await _api.objects.insert(
        gcs.Object(),
        config.bucket,
        name: '$package/$assetKey',
        uploadMedia: gcs.Media(
          tee,
          null,
          contentType: 'application/octet-stream',
        ),
        uploadOptions: gcs.ResumableUploadOptions(),
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
      final media =
          await _api.objects.get(
                config.bucket,
                '$package/$assetKey',
                downloadOptions: gcs.DownloadOptions.fullMedia,
              )
              as gcs.Media;
      return media.stream;
    } on gcs.DetailedApiRequestError catch (e) {
      if (e.status == 404) {
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
    if (length == 0) return const Stream<List<int>>.empty();
    // GCS byte ranges are INCLUSIVE on both ends, so a request for
    // `length` bytes starting at `offset` ends at `offset + length - 1`.
    try {
      final media =
          await _api.objects.get(
                config.bucket,
                '$package/$assetKey',
                downloadOptions: gcs.PartialDownloadOptions(
                  gcs.ByteRange(offset, offset + length - 1),
                ),
              )
              as gcs.Media;
      return media.stream;
    } on gcs.DetailedApiRequestError catch (e) {
      if (e.status == 404) {
        throw NotFoundException('Asset $assetKey for $package not found.');
      }
      rethrow;
    }
  }

  @override
  Future<BlobInfo?> assetInfo(String package, String assetKey) async {
    try {
      final meta =
          await _api.objects.get(config.bucket, '$package/$assetKey')
              as gcs.Object;
      return BlobInfo(
        package: package,
        version: assetKey,
        sizeBytes: int.tryParse(meta.size ?? '0') ?? 0,
        // GCS stores an md5/crc32c, not sha256 — rather than fetching the
        // object to rehash, leave the hash empty. The only caller consumes
        // sizeBytes.
        sha256Hex: '',
        createdAt: meta.timeCreated?.toUtc() ?? DateTime.now().toUtc(),
      );
    } on gcs.DetailedApiRequestError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<void> deleteAssetsUnder(String package, String prefix) async {
    final fullPrefix = '$package/$prefix';
    String? pageToken;
    do {
      final resp = await _api.objects.list(
        config.bucket,
        prefix: fullPrefix,
        pageToken: pageToken,
      );
      for (final item in resp.items ?? const <gcs.Object>[]) {
        final name = item.name;
        if (name == null) continue;
        try {
          await _api.objects.delete(config.bucket, name);
        } on gcs.DetailedApiRequestError catch (e) {
          if (e.status != 404) rethrow;
        }
      }
      pageToken = resp.nextPageToken;
    } while (pageToken != null);
  }

  @override
  Future<void> deleteAsset(String package, String assetKey) async {
    try {
      await _api.objects.delete(config.bucket, '$package/$assetKey');
    } on gcs.DetailedApiRequestError catch (e) {
      if (e.status != 404) rethrow;
    }
  }

  @override
  Future<Uri?> signedDownloadUrl(
    String package,
    String version, {
    Duration expiry = const Duration(hours: 1),
  }) async {
    final creds = _saCreds;
    if (creds == null) {
      // Under ADC there's no private key in-process, so we can't sign
      // locally. Returning null falls back to proxying bytes through the
      // server — same behavior as FilesystemBlobStore.
      return null;
    }
    // GCS V4 signing caps expiry at 7 days.
    const maxExpiry = Duration(days: 7);
    final clamped = expiry > maxExpiry ? maxExpiry : expiry;
    return _signV4GetUrl(
      credentials: creds,
      bucket: config.bucket,
      objectKey: _archiveKey(package, version),
      expirySeconds: clamped.inSeconds,
    );
  }
}

// ── V4 signed URL helpers ────────────────────────────────────────────────
//
// See https://cloud.google.com/storage/docs/access-control/signing-urls-manually
// for the spec. We keep this self-contained because googleapis ships no
// signed-URL helper.

Uri _signV4GetUrl({
  required auth.ServiceAccountCredentials credentials,
  required String bucket,
  required String objectKey,
  required int expirySeconds,
}) {
  const host = 'storage.googleapis.com';

  final now = DateTime.now().toUtc();
  final datestamp = _yyyymmdd(now);
  final timestamp = '${datestamp}T${_hhmmss(now)}Z';
  final credentialScope = '$datestamp/auto/storage/goog4_request';
  final credentialValue = '${credentials.email}/$credentialScope';
  final encodedPath = '/$bucket/${_pathEncode(objectKey)}';

  // Query params must be sorted by name. Values are URL-encoded in the
  // canonical request AND in the final URL.
  final queryParams = <String, String>{
    'X-Goog-Algorithm': 'GOOG4-RSA-SHA256',
    'X-Goog-Credential': credentialValue,
    'X-Goog-Date': timestamp,
    'X-Goog-Expires': '$expirySeconds',
    'X-Goog-SignedHeaders': 'host',
  };
  final sortedKeys = queryParams.keys.toList()..sort();
  final canonicalQuery = sortedKeys
      .map((k) => '${_urlEncode(k)}=${_urlEncode(queryParams[k]!)}')
      .join('&');

  final canonicalRequest = [
    'GET',
    encodedPath,
    canonicalQuery,
    'host:$host',
    '',
    'host',
    'UNSIGNED-PAYLOAD',
  ].join('\n');

  final canonicalRequestHash = crypto.sha256
      .convert(utf8.encode(canonicalRequest))
      .toString();

  final stringToSign = [
    'GOOG4-RSA-SHA256',
    timestamp,
    credentialScope,
    canonicalRequestHash,
  ].join('\n');

  final hexSig = _rsaSha256SignHex(credentials, stringToSign);
  final finalQuery = '$canonicalQuery&X-Goog-Signature=$hexSig';
  return Uri.parse('https://$host$encodedPath?$finalQuery');
}

String _rsaSha256SignHex(
  auth.ServiceAccountCredentials credentials,
  String stringToSign,
) {
  // googleapis_auth already parsed the PEM into its own RSA key model. Copy
  // the integers into pointycastle's key so we can use its RSASigner.
  final src = credentials.privateRSAKey;
  final pcKey = RSAPrivateKey(src.n, src.d, src.p, src.q);
  // Hex digest identifier is the DER-encoded SHA-256 OID.
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
  signer.init(true, PrivateKeyParameter<RSAPrivateKey>(pcKey));
  final sig = signer.generateSignature(
    Uint8List.fromList(utf8.encode(stringToSign)),
  );
  return sig.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _yyyymmdd(DateTime dt) =>
    '${dt.year.toString().padLeft(4, '0')}'
    '${dt.month.toString().padLeft(2, '0')}'
    '${dt.day.toString().padLeft(2, '0')}';

String _hhmmss(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}'
    '${dt.minute.toString().padLeft(2, '0')}'
    '${dt.second.toString().padLeft(2, '0')}';

/// RFC 3986 unreserved-char URL encoding, matching AWS SigV4 / GCS V4 rules.
String _urlEncode(String input) {
  final buf = StringBuffer();
  for (final byte in utf8.encode(input)) {
    if ((byte >= 0x41 && byte <= 0x5A) || // A-Z
        (byte >= 0x61 && byte <= 0x7A) || // a-z
        (byte >= 0x30 && byte <= 0x39) || // 0-9
        byte == 0x2D || // -
        byte == 0x5F || // _
        byte == 0x2E || // .
        byte == 0x7E) {
      // ~
      buf.writeCharCode(byte);
    } else {
      buf.write('%');
      buf.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buf.toString();
}

/// Path encoding preserves `/` (each segment is [_urlEncode]d individually).
String _pathEncode(String path) => path.split('/').map(_urlEncode).join('/');

/// Collects chunked-conversion outputs so `sha256.startChunkedConversion`
/// can hand us a single `Digest` when closed.
class _AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];

  @override
  void add(T event) => events.add(event);

  @override
  void close() {}
}
