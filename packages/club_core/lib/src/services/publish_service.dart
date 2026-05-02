import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../exceptions.dart';
import '../models/audit_log.dart';
import '../models/package.dart';
import '../models/package_screenshot.dart';
import '../models/package_version.dart';
import '../models/search.dart';
import '../models/upload_session.dart';
import '../repositories/blob_store.dart';
import '../repositories/metadata_store.dart';
import '../repositories/search_index.dart';
import '../validation/package_name_validator.dart';
import '../validation/version_validator.dart';
import 'readme_asset_rewriter.dart';
import 'tag_derivation.dart';

/// Result of archive extraction.
class ArchiveContent {
  const ArchiveContent({
    required this.pubspecYaml,
    required this.pubspecMap,
    required this.readme,
    required this.changelog,
    required this.example,
    this.examplePath,
    this.license,
    this.licensePath,
    required this.libraries,
    this.binExecutables = const [],
    this.dartImports = const {},
    this.screenshots = const [],
    this.readmeAssets = const [],
    this.hasBuildHooks = false,
  });

  final String pubspecYaml;
  final Map<String, dynamic> pubspecMap;
  final String? readme;
  final String? changelog;
  final String? example;

  /// In-archive path of the extracted example (e.g. `example/main.dart`).
  /// Null if no example file matched the pub.dev priority list.
  final String? examplePath;

  /// Content of the root `LICENSE` file, if present. Null for unlicensed
  /// archives — club's policy allows publish without a license (unlike pub.dev).
  final String? license;

  /// In-archive path of the extracted license (always `LICENSE` when set).
  final String? licensePath;

  /// Public-API library entry points as relative paths under `lib/`, with
  /// the `lib/` prefix stripped and `lib/src/*` excluded. E.g. `club.dart`,
  /// `src/public.dart` (yes, but only top-level imports), etc. Matches
  /// pub.dev's semantics for what appears in the generated "Libraries"
  /// section.
  final List<String> libraries;

  /// Command names for Dart files found directly under `bin/` (filename with
  /// `.dart` stripped). Any such file is an implicit `pub global activate`
  /// executable even when `executables:` isn't declared in pubspec.yaml.
  final List<String> binExecutables;

  /// Set of `dart:xxx` library names found in source files (e.g. `io`, `html`,
  /// `ffi`). Used for platform tag derivation.
  final Set<String> dartImports;

  /// Screenshots listed in `pubspec.yaml` under the `screenshots:` key, paired
  /// with the raw bytes pulled from the tarball. The [PublishService] writes
  /// the bytes to the blob store and persists the metadata to the DB.
  final List<ExtractedScreenshot> screenshots;

  /// Files referenced from the README (Markdown or HTML) whose paths
  /// resolved to entries in the tarball. The README in [readme] has
  /// already been rewritten to point at the readme-asset URLs; the
  /// [PublishService] only needs to persist the bytes under the asset
  /// key `<version>/readme-assets/<index>.<extension>`.
  final List<ExtractedReadmeAsset> readmeAssets;

  /// True when the archive contains any `hook/*.dart` file (Dart Build
  /// hooks — e.g. `hook/build.dart`, `hook/link.dart`). Drives the
  /// `has:build-hooks` derived tag and the matching UI chip.
  final bool hasBuildHooks;
}

/// One screenshot entry pulled out of the tarball at publish time.
///
/// [path] is the pubspec-declared path (kept verbatim for display);
/// [bytes] is the raw image content from the archive. [mimeType] is
/// derived from the file extension.
class ExtractedScreenshot {
  const ExtractedScreenshot({
    required this.path,
    required this.description,
    required this.bytes,
    required this.mimeType,
  });

  final String path;
  final String? description;
  final List<int> bytes;
  final String mimeType;

  String get extension => screenshotExtOf(path);
}

/// Handles the package publish flow.
class PublishService {
  PublishService({
    required MetadataStore store,
    required BlobStore blobStore,
    required SearchIndex searchIndex,
    required this.generateId,
    required this.tempDir,
    required this.extractArchive,
    this.onVersionPublished,
    this.maxUploadBytes = 100 * 1024 * 1024,
    this.uploadSessionTtl = const Duration(minutes: 10),
    this.maxPendingUploads = 3,
  }) : _store = store,
       _blobStore = blobStore,
       _searchIndex = searchIndex;

  final MetadataStore _store;
  final BlobStore _blobStore;
  final SearchIndex _searchIndex;
  final String Function() generateId;
  final String tempDir;
  final int maxUploadBytes;
  final Duration uploadSessionTtl;
  final int maxPendingUploads;

  /// Extract and validate a tarball. Injected so club_core stays free of
  /// tar/archive dependencies.
  final Future<ArchiveContent> Function(File file) extractArchive;

  /// Optional callback invoked after a version is successfully published.
  /// Used to trigger scoring (pana analysis) without coupling club_core
  /// to the scoring implementation.
  final Future<void> Function(String packageName, String version)?
  onVersionPublished;

  /// Step 1: Create an upload session and return upload info.
  /// [baseUrl] is the public-facing server URL resolved from the request.
  Future<Map<String, dynamic>> startUpload(
    String userId, {
    required Uri baseUrl,
  }) async {
    final pending = await _store.countPendingUploads(userId);
    if (pending >= maxPendingUploads) {
      throw const RateLimitException(
        'Too many pending uploads. Complete or wait for existing uploads to expire.',
      );
    }

    final uploadId = generateId();
    final tempPath = '$tempDir/$uploadId.tar.gz';

    await _store.createUploadSession(
      UploadSessionCompanion(
        id: uploadId,
        userId: userId,
        tempPath: tempPath,
        expiresAt: DateTime.now().toUtc().add(uploadSessionTtl),
      ),
    );

    return {
      'url': baseUrl.resolve('/api/packages/versions/upload').toString(),
      'fields': {'upload_id': uploadId},
    };
  }

  /// Step 2: Mark the upload as received (called after the tarball is streamed to disk).
  Future<void> markReceived(String uploadId) async {
    await _store.updateUploadSessionState(uploadId, UploadState.received);
  }

  /// Step 3: Finalize — validate, store, and index the package.
  ///
  /// When [force] is true and a version with the same name+version already
  /// exists with different content, it is overwritten in place (new
  /// pubspec, readme, tarball, search index, audit log). Club extension
  /// over the pub protocol — the CLI sets this when the user passes `-f`.
  Future<String> finalize(
    String uploadId,
    String userId, {
    bool force = false,
  }) async {
    final session = await _store.lookupUploadSession(uploadId);
    if (session == null) {
      throw const InvalidInputException('Upload session not found or expired.');
    }
    if (session.userId != userId) {
      throw const ForbiddenException('Upload session belongs to another user.');
    }
    if (session.state != UploadState.received) {
      throw InvalidInputException(
        'Upload session is in state "${session.state.name}", expected "received".',
      );
    }

    await _store.updateUploadSessionState(uploadId, UploadState.processing);

    try {
      final tempFile = File(session.tempPath);
      if (!await tempFile.exists()) {
        throw const InvalidInputException('Upload file not found.');
      }

      // Check size
      final size = await tempFile.length();
      if (size > maxUploadBytes) {
        throw PackageRejectedException.tooLarge(maxUploadBytes);
      }

      // Compute SHA-256
      final bytes = await tempFile.readAsBytes();
      final sha256Hex = sha256.convert(bytes).toString();

      // Extract and validate archive
      final content = await extractArchive(tempFile);
      final pubspec = content.pubspecMap;
      final name = pubspec['name'] as String? ?? '';
      final version = pubspec['version'] as String? ?? '';

      // Validate package name
      final nameError = PackageNameValidator.validate(name);
      if (nameError != null) {
        throw PackageRejectedException.invalidName(name);
      }

      // Validate version
      if (!VersionValidator.isValid(version)) {
        throw PackageRejectedException.invalidVersion(version);
      }

      // Check authorization
      await _checkPublishAuth(name, userId);

      // Check for duplicate version
      final existing = await _store.lookupVersion(name, version);
      if (existing != null) {
        if (existing.archiveSha256 == sha256Hex && !force) {
          // Idempotent: same content + no force, treat as success.
          // Force bypasses this so an operator can re-run extraction
          // (e.g. to apply a server-side processing change like the
          // README asset rewriter) against an already-stored version
          // even when the tarball bytes haven't changed.
          await _store.updateUploadSessionState(uploadId, UploadState.complete);
          await tempFile.delete();
          return 'Successfully uploaded $name version $version (already existed).';
        }
        if (!force) {
          throw PackageRejectedException.versionExists(name, version);
        }
        // Fall through: force-mode overwrite proceeds below.
      }

      // Parse SDK constraints
      final env = pubspec['environment'] as Map<String, dynamic>? ?? {};
      final sdkConstraint = env['sdk'] as String?;
      final flutterConstraint = env['flutter'] as String?;

      // Derive SDK and platform tags
      final tags = TagDerivation.deriveTags(
        pubspec,
        dartImports: content.dartImports,
        hasBuildHooks: content.hasBuildHooks,
      );

      // Create package if new, or update existing
      final existingPkg = await _store.lookupPackage(name);
      final isNewPackage = existingPkg == null;

      final isRepublish = existing != null;

      // Build screenshot metadata up front so the DB row can reference the
      // canonical sha256 + size before any bytes hit disk. Mirrors the
      // tarball flow (transaction first, blob write after) — if the file
      // write later fails we'd rather have an orphan DB row pointing at
      // missing bytes than the reverse.
      final screenshotMetas = [
        for (var i = 0; i < content.screenshots.length; i++)
          _screenshotMeta(content.screenshots[i]),
      ];

      await _store.transaction((tx) async {
        if (isNewPackage) {
          await tx.createPackage(PackageCompanion(name: name));
          await tx.addUploader(name, userId);
        }

        final versionCompanion = PackageVersionCompanion(
          packageName: name,
          version: version,
          pubspecJson: jsonEncode(pubspec),
          readmeContent: content.readme,
          changelogContent: content.changelog,
          exampleContent: content.example,
          examplePath: content.examplePath,
          libraries: content.libraries,
          binExecutables: content.binExecutables,
          screenshots: screenshotMetas,
          archiveSizeBytes: size,
          archiveSha256: sha256Hex,
          uploaderId: userId,
          publisherId: existingPkg?.publisherId,
          isPrerelease: VersionValidator.isPrerelease(version),
          dartSdkMin: sdkConstraint,
          flutterSdkMin: flutterConstraint,
          tags: tags,
        );

        if (isRepublish) {
          await tx.updateVersion(name, version, versionCompanion);
        } else {
          await tx.createVersion(versionCompanion);
        }

        // Recompute latest versions
        final allVersions = await tx.listVersions(name);
        final nonRetracted = allVersions
            .where((v) => !v.isRetracted)
            .map((v) => v.version)
            .toList();

        final latestStable = VersionValidator.latestStable(nonRetracted);
        final latestAny = VersionValidator.latestAny(nonRetracted);

        await tx.updatePackage(
          name,
          PackageCompanion(
            name: name,
            latestVersion: latestStable ?? latestAny,
            latestPrerelease: latestAny != latestStable ? latestAny : null,
          ),
        );

        await tx.appendAuditLog(
          AuditLogCompanion(
            id: generateId(),
            kind: isNewPackage
                ? AuditKind.packageCreated
                : AuditKind.versionPublished,
            agentId: userId,
            packageName: name,
            version: version,
            summary: isNewPackage
                ? 'Package $name created with version $version.'
                : isRepublish
                ? 'Version $version of $name re-published (forced).'
                : 'Version $version of $name published.',
            dataJson: jsonEncode({
              'sha256': sha256Hex,
              'size': size,
              if (isRepublish) 'forced': true,
            }),
          ),
        );
      });

      // Store the tarball
      await _blobStore.put(
        name,
        version,
        tempFile.openRead(),
        overwrite: true,
      );

      // Persist screenshot bytes. Write-then-tail-delete so a crash or
      // write failure never leaves the DB pointing at missing files:
      //   1. Overwrite indexes 0..N-1 in place (putAsset is atomic per
      //      file via write-temp + rename, so mid-write failures don't
      //      corrupt an existing file).
      //   2. After all writes succeed, delete any stale indexes above
      //      the new count left over from a prior publish with more
      //      screenshots.
      //
      // On-disk keys are bare indexes (no extension) — the extension lives
      // in the DB's mimeType and in the public URL. Dropping it from the
      // filesystem keeps re-publishes simple when an author swaps
      // `hero.png` → `hero.jpg` at the same position: the single file at
      // index `i` is always authoritative.
      for (var i = 0; i < content.screenshots.length; i++) {
        final s = content.screenshots[i];
        await _blobStore.putAsset(
          name,
          '${_screenshotPrefix(version)}$i',
          Stream.value(s.bytes),
        );
      }
      if (isRepublish) {
        for (
          var i = content.screenshots.length;
          i < existing.screenshots.length;
          i++
        ) {
          await _blobStore.deleteAsset(
            name,
            '${_screenshotPrefix(version)}$i',
          );
        }
      }

      // Persist README-asset bytes. Unlike screenshots (whose pubspec
      // ordering is stable across publishes), readme-asset indices are
      // assigned in README-encounter order, which can shift when the
      // author edits the README. There is no per-index correspondence
      // to old assets, so we nuke the entire prefix on republish before
      // writing the new set rather than overwriting in place.
      if (isRepublish) {
        await _blobStore.deleteAssetsUnder(
          name,
          _readmeAssetPrefix(version),
        );
      }
      for (var i = 0; i < content.readmeAssets.length; i++) {
        final a = content.readmeAssets[i];
        await _blobStore.putAsset(
          name,
          '${_readmeAssetPrefix(version)}$i.${a.extension}',
          Stream.value(a.bytes),
        );
      }

      // Update search index
      final description = pubspec['description'] as String? ?? '';
      final rawTopics = pubspec['topics'];
      final topics = rawTopics is List
          ? rawTopics
                .whereType<String>()
                .map((t) => t.trim())
                .where((t) => t.isNotEmpty)
                .toList()
          : const <String>[];
      await _searchIndex.indexPackage(
        IndexDocument(
          package: name,
          latestVersion: version,
          description: description,
          readme: content.readme?.substring(
            0,
            content.readme!.length.clamp(0, 2048),
          ),
          topics: topics,
          publishedAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      // Notify listeners (e.g. scoring service) — fire-and-forget so a
      // scoring failure doesn't block the publish response.
      if (onVersionPublished != null) {
        // ignore: unawaited_futures
        onVersionPublished!(name, version).catchError((_) {});
      }

      // Cleanup
      await _store.updateUploadSessionState(uploadId, UploadState.complete);
      await tempFile.delete();

      // Distinct message on force-republish so the CLI user can tell
      // whether the overwrite path actually executed end-to-end. A plain
      // "Successfully uploaded" here would be indistinguishable from a
      // first-time publish and hide any plumbing regression.
      return isRepublish
          ? 'Re-published $name version $version (forced overwrite).'
          : 'Successfully uploaded $name version $version.';
    } catch (e) {
      await _store.updateUploadSessionState(uploadId, UploadState.failed);
      // Try to clean up temp file
      try {
        await File(session.tempPath).delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Look up an upload session by ID.
  Future<UploadSession?> lookupSession(String id) =>
      _store.lookupUploadSession(id);

  /// Clean up expired upload sessions and their temp files.
  Future<void> cleanupExpiredSessions() async {
    await _store.deleteExpiredUploadSessions();
    // Note: temp files for expired sessions should also be cleaned.
    // The MetadataStore implementation should handle deleting the files
    // or we scan the temp directory for orphaned files.
  }

  /// Blob-store key prefix for a given version's screenshots. Resolves to
  /// `<version>/screenshots/` so the filesystem layout ends up at
  /// `<BLOB_PATH>/<pkg>/<version>/screenshots/<index>` — the same
  /// version directory that also holds `artifacts/package.tar.gz`.
  static String _screenshotPrefix(String version) => '$version/screenshots/';

  /// Blob-store key prefix for a given version's README-referenced
  /// assets. The on-disk filename keeps the extension (unlike screenshots,
  /// which strip it) so the HTTP route can derive the Content-Type from
  /// the URL without an accompanying DB metadata table.
  static String _readmeAssetPrefix(String version) =>
      '$version/readme-assets/';

  static PackageScreenshot _screenshotMeta(ExtractedScreenshot s) =>
      PackageScreenshot(
        path: s.path,
        description: s.description,
        sizeBytes: s.bytes.length,
        sha256: sha256.convert(s.bytes).toString(),
        mimeType: s.mimeType,
      );

  Future<void> _checkPublishAuth(String name, String userId) async {
    final user = await _store.lookupUserById(userId);
    if (user != null && user.isAdmin) return;

    final pkg = await _store.lookupPackage(name);
    if (pkg == null) return; // New package, anyone can create

    if (pkg.isOwnedByPublisher) {
      final isMember = await _store.isPublisherMember(pkg.publisherId!, userId);
      if (!isMember) {
        throw ForbiddenException.notUploader(name);
      }
    } else {
      final isUp = await _store.isUploader(name, userId);
      if (!isUp) {
        throw ForbiddenException.notUploader(name);
      }
    }
  }
}
