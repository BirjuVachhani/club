import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:club_core/club_core.dart';
import 'package:path/path.dart' as p;

/// Filesystem-backed [BlobStore] implementation.
///
/// Stores tarballs at `<rootPath>/<package>/<version>/artifacts/package.tar.gz`.
/// Per-version assets (screenshots, future bundles, etc.) live alongside
/// the artifact under `<rootPath>/<package>/<version>/<asset-subdir>/...`.
/// Uses atomic writes (write to temp file, then rename) to prevent corruption.
class FilesystemBlobStore implements BlobStore {
  FilesystemBlobStore({required this.rootPath});

  final String rootPath;

  /// Filename for the primary archive artifact. Parent directory
  /// (`<root>/<pkg>/<version>/artifacts/`) already encodes pkg + version
  /// so the file itself uses a fixed, generic name. Leaves room for
  /// additional artifacts (pana report bundles, etc.) in the same
  /// directory in future without naming collisions.
  static const _archiveFilename = 'package.tar.gz';

  String _versionDir(String package, String version) =>
      p.join(rootPath, package, version);

  String _path(String package, String version) =>
      p.join(_versionDir(package, version), 'artifacts', _archiveFilename);

  @override
  Future<void> open() async {
    await Directory(rootPath).create(recursive: true);
    // Clean up orphaned temp files from previous crashes
    await _cleanupOrphanedTempFiles();
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
    final filePath = _path(package, version);
    final file = File(filePath);

    if (!overwrite && await file.exists()) {
      throw ConflictException('Archive for $package $version already exists.');
    }

    await file.parent.create(recursive: true);

    // Write to temp file first for atomicity
    final tmpPath = '$filePath.tmp.${DateTime.now().microsecondsSinceEpoch}';
    final tmpFile = File(tmpPath);
    final sink = tmpFile.openWrite();
    final digestSink = AccumulatorSink<Digest>();
    final hashSink = sha256.startChunkedConversion(digestSink);
    var size = 0;

    try {
      await for (final chunk in bytes) {
        hashSink.add(chunk);
        sink.add(chunk);
        size += chunk.length;
      }
      hashSink.close();
      await sink.flush();
      await sink.close();

      // Atomic rename
      await tmpFile.rename(filePath);
    } catch (e) {
      await sink.close();
      try {
        await tmpFile.delete();
      } catch (_) {}
      rethrow;
    }

    final sha256Hex = digestSink.events.single.toString();

    return BlobInfo(
      package: package,
      version: version,
      sizeBytes: size,
      sha256Hex: sha256Hex,
      createdAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<Stream<List<int>>> get(String package, String version) async {
    final file = File(_path(package, version));
    if (!await file.exists()) {
      throw NotFoundException('Archive for $package $version not found.');
    }
    return file.openRead();
  }

  @override
  Future<BlobInfo?> info(String package, String version) async {
    final file = File(_path(package, version));
    if (!await file.exists()) return null;

    final stat = await file.stat();
    final bytes = await file.readAsBytes();
    final sha256Hex = sha256.convert(bytes).toString();

    return BlobInfo(
      package: package,
      version: version,
      sizeBytes: stat.size,
      sha256Hex: sha256Hex,
      createdAt: stat.modified.toUtc(),
    );
  }

  @override
  Future<bool> exists(String package, String version) =>
      File(_path(package, version)).exists();

  @override
  Future<void> delete(String package, String version) async {
    // Remove the whole per-version directory — artifact + screenshots +
    // any future per-version assets all come down together. Matches the
    // expectation that "delete version" evicts all state tied to that
    // version, not just the tarball.
    final versionDir = Directory(_versionDir(package, version));
    if (await versionDir.exists()) {
      await versionDir.delete(recursive: true);
    }
    // Clean up the package directory when it's left empty (last version
    // gone). Anything not tied to a specific version (e.g. future
    // package-wide metadata) would keep the dir alive.
    final pkgDir = Directory(p.join(rootPath, package));
    if (await pkgDir.exists()) {
      final entries = await pkgDir.list().toList();
      if (entries.isEmpty) {
        await pkgDir.delete();
      }
    }
  }

  @override
  Future<List<String>> listVersions(String package) async {
    final dir = Directory(p.join(rootPath, package));
    if (!await dir.exists()) return [];

    final versions = <String>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      // A subdir qualifies as a version only when its archive artifact
      // is present. Rules out partially-provisioned directories and any
      // future per-package subdirs that aren't version-scoped.
      final archive = File(
        p.join(entity.path, 'artifacts', _archiveFilename),
      );
      if (await archive.exists()) {
        versions.add(p.basename(entity.path));
      }
    }
    return versions;
  }

  @override
  Future<List<String>> listPackages() async {
    final dir = Directory(rootPath);
    if (!await dir.exists()) return [];

    final entries = await dir.list().toList();
    return entries
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .toList();
  }

  @override
  Future<Uri?> signedDownloadUrl(
    String package,
    String version, {
    Duration expiry = const Duration(hours: 1),
  }) async {
    // Filesystem backend doesn't support signed URLs.
    // The server will proxy the file bytes directly.
    return null;
  }

  // ── Per-package assets ─────────────────────────────────────────
  //
  // Assets live at `<rootPath>/<pkg>/<assetKey>`. Keys are validated to
  // prevent escaping the package directory via `..` or absolute paths.

  String _assetPath(String package, String assetKey) {
    _validateAssetKey(assetKey);
    return p.join(rootPath, package, assetKey);
  }

  static void _validateAssetKey(String key) {
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'assetKey', 'must not be empty');
    }
    if (key.startsWith('/') || key.startsWith(r'\')) {
      throw ArgumentError.value(key, 'assetKey', 'must be relative');
    }
    for (final segment in p.posix.split(key)) {
      if (segment == '..' || segment.isEmpty) {
        throw ArgumentError.value(
          key,
          'assetKey',
          'must not contain empty or `..` segments',
        );
      }
    }
  }

  @override
  Future<BlobInfo> putAsset(
    String package,
    String assetKey,
    Stream<List<int>> bytes,
  ) async {
    final filePath = _assetPath(package, assetKey);
    final file = File(filePath);
    await file.parent.create(recursive: true);

    final tmpPath = '$filePath.tmp.${DateTime.now().microsecondsSinceEpoch}';
    final tmpFile = File(tmpPath);
    final sink = tmpFile.openWrite();
    final digestSink = AccumulatorSink<Digest>();
    final hashSink = sha256.startChunkedConversion(digestSink);
    var size = 0;

    try {
      await for (final chunk in bytes) {
        hashSink.add(chunk);
        sink.add(chunk);
        size += chunk.length;
      }
      hashSink.close();
      await sink.flush();
      await sink.close();
      await tmpFile.rename(filePath);
    } catch (e) {
      await sink.close();
      try {
        await tmpFile.delete();
      } catch (_) {}
      rethrow;
    }

    return BlobInfo(
      package: package,
      version: assetKey,
      sizeBytes: size,
      sha256Hex: digestSink.events.single.toString(),
      createdAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<Stream<List<int>>> getAsset(String package, String assetKey) async {
    final file = File(_assetPath(package, assetKey));
    if (!await file.exists()) {
      throw NotFoundException('Asset $assetKey for $package not found.');
    }
    return file.openRead();
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
    final file = File(_assetPath(package, assetKey));
    if (!await file.exists()) {
      throw NotFoundException('Asset $assetKey for $package not found.');
    }
    // `openRead(start, end)` handles over-reads gracefully — the returned
    // stream is clipped to the file's actual size. End is exclusive.
    return file.openRead(offset, offset + length);
  }

  @override
  Future<BlobInfo?> assetInfo(String package, String assetKey) async {
    final file = File(_assetPath(package, assetKey));
    if (!await file.exists()) return null;
    final stat = await file.stat();
    return BlobInfo(
      package: package,
      version: assetKey,
      sizeBytes: stat.size,
      sha256Hex: '', // Not computed on stat; caller that needs it reads bytes.
      createdAt: stat.modified.toUtc(),
    );
  }

  @override
  Future<void> deleteAssetsUnder(String package, String prefix) async {
    _validateAssetKey(prefix);
    final dir = Directory(p.join(rootPath, package, prefix));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  @override
  Future<void> deleteAsset(String package, String assetKey) async {
    final file = File(_assetPath(package, assetKey));
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _cleanupOrphanedTempFiles() async {
    final dir = Directory(rootPath);
    if (!await dir.exists()) return;

    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.contains('.tmp.')) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }
}

/// Helper to accumulate digest results from chunked conversion.
class AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];

  @override
  void add(T event) => events.add(event);

  @override
  void close() {}
}
