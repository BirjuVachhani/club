import 'dart:convert';

import '../exceptions.dart';
import '../models/api/package_data.dart';
import '../models/api/version_info.dart';
import '../models/api/version_score.dart';
import '../models/audit_log.dart';
import '../models/package.dart';
import '../models/package_score.dart';
import '../models/package_version.dart';
import '../repositories/metadata_store.dart';
import '../validation/version_validator.dart';
import 'download_service.dart';

/// Handles package queries, options, and uploader management.
class PackageService {
  PackageService({
    required MetadataStore store,
    required DownloadService downloadService,
    required this.generateId,
    this.enforceRetractionWindow = true,
    DateTime Function()? clock,
  }) : _store = store,
       _downloadService = downloadService,
       _clock = clock ?? (() => DateTime.now().toUtc());

  final MetadataStore _store;
  final DownloadService _downloadService;
  final String Function() generateId;

  /// When true, `setVersionRetracted` rejects retract/restore requests
  /// outside the pub spec's 7-day windows. See the Dart docs:
  /// https://dart.dev/tools/pub/publishing#retract.
  final bool enforceRetractionWindow;

  final DateTime Function() _clock;

  /// Maximum age of a published version that can still be retracted, and
  /// maximum age of a retraction that can still be restored. Matches the
  /// pub.dev policy. Only checked when [enforceRetractionWindow] is true.
  static const retractionWindow = Duration(days: 7);

  /// Build a [PackageData] response (pub spec v2 format).
  ///
  /// [baseUrl] is the public-facing server URL, resolved per-request
  /// from headers (X-Forwarded-Host, Host) or config override.
  Future<PackageData> listVersions(String name, {required Uri baseUrl}) async {
    final pkg = await _store.lookupPackage(name);
    if (pkg == null) throw NotFoundException.package(name);

    final versions = await _store.listVersions(name);
    if (versions.isEmpty) throw NotFoundException.package(name);

    final versionInfos = versions
        .map((v) => _toVersionInfo(v, baseUrl))
        .toList();

    // The "latest" version returned in the API response should match the
    // latestVersion column we maintain on the package row — that column is
    // recomputed on every publish/retract via
    // [VersionValidator.latestStable] / [latestAny] (semver ordering), so
    // it's the single source of truth. Fall back to latestPrerelease (for
    // packages that only have prereleases) and finally the most recently
    // published row if neither is set.
    VersionInfo latest;
    final preferred = pkg.latestVersion ?? pkg.latestPrerelease;
    if (preferred != null) {
      latest = versionInfos.firstWhere(
        (v) => v.version == preferred,
        // versions is ORDER BY published_at DESC, so .first is the most
        // recent upload — a reasonable fallback if the package row is
        // somehow stale.
        orElse: () => versionInfos.first,
      );
    } else {
      latest = versionInfos.first;
    }

    // Only populated when a prerelease strictly beats the latest stable
    // (the Package row's `latestPrerelease` column is maintained via
    // `VersionValidator.latestStable`/`latestAny`, both of which use
    // pub_semver's `>` operator, and is set to null when the stable is ahead).
    VersionInfo? latestPrerelease;
    if (pkg.latestPrerelease != null) {
      for (final v in versionInfos) {
        if (v.version == pkg.latestPrerelease) {
          latestPrerelease = v;
          break;
        }
      }
    }

    return PackageData(
      name: name,
      isDiscontinued: pkg.isDiscontinued ? true : null,
      replacedBy: pkg.replacedBy,
      isUnlisted: pkg.isUnlisted ? true : null,
      latest: latest,
      latestPrerelease: latestPrerelease,
      versions: versionInfos,
    );
  }

  /// Get info for a specific version (pub spec v2).
  Future<VersionInfo> getVersion(
    String name,
    String version, {
    required Uri baseUrl,
  }) async {
    final pv = await _store.lookupVersion(name, version);
    if (pv == null) throw NotFoundException.version(name, version);
    return _toVersionInfo(pv, baseUrl);
  }

  /// Get the download URL for an archive.
  Uri archiveUrl(String name, String version, Uri baseUrl) =>
      baseUrl.resolve('/api/archives/$name-$version.tar.gz');

  /// Get package options.
  Future<Package> getPackage(String name) async {
    final pkg = await _store.lookupPackage(name);
    if (pkg == null) throw NotFoundException.package(name);
    return pkg;
  }

  /// Set package options (discontinued, unlisted).
  Future<Package> setOptions(
    String name, {
    bool? isDiscontinued,
    String? replacedBy,
    bool? isUnlisted,
    required String actingUserId,
  }) async {
    await _requirePackageAdmin(name, actingUserId);

    final companion = PackageCompanion(
      name: name,
      isDiscontinued: isDiscontinued,
      replacedBy: replacedBy,
      isUnlisted: isUnlisted,
    );

    final updated = await _store.updatePackage(name, companion);

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.packageOptionsUpdated,
        agentId: actingUserId,
        packageName: name,
        summary: 'Package options updated for $name.',
      ),
    );

    return updated;
  }

  /// Retract or unretract a version.
  ///
  /// When [enforceRetractionWindow] is true (the default) this enforces
  /// the pub.dev policy: retraction is only allowed within 7 days of
  /// `publishedAt`, and restoration is only allowed within 7 days of
  /// `retractedAt`. A [ConflictException] is thrown when the request
  /// falls outside the applicable window.
  ///
  /// Also rejects no-op requests (retract an already-retracted version,
  /// or restore a non-retracted one) with [ConflictException] so callers
  /// get a clear error instead of a silently idempotent write.
  Future<void> setVersionRetracted(
    String name,
    String version, {
    required bool isRetracted,
    required String actingUserId,
  }) async {
    await _requirePackageAdmin(name, actingUserId);

    final existing = await _store.lookupVersion(name, version);
    if (existing == null) throw NotFoundException.version(name, version);

    if (isRetracted && existing.isRetracted) {
      throw const ConflictException('Version is already retracted.');
    }
    if (!isRetracted && !existing.isRetracted) {
      throw const ConflictException('Version is not retracted.');
    }

    if (enforceRetractionWindow) {
      final now = _clock();
      if (isRetracted) {
        final deadline = existing.publishedAt.add(retractionWindow);
        if (now.isAfter(deadline)) {
          throw ConflictException(
            'Version $version of $name was published on '
            '${existing.publishedAt.toIso8601String()} and can no longer '
            'be retracted. Retraction is only allowed within 7 days of '
            'publishing. Publish a new version with a fix instead, or '
            'set ENFORCE_RETRACTION_WINDOW=false on the server to relax '
            'this policy on a private registry.',
          );
        }
      } else {
        final retractedAt = existing.retractedAt;
        if (retractedAt == null) {
          throw const ConflictException('Version is not retracted.');
        }
        final deadline = retractedAt.add(retractionWindow);
        if (now.isAfter(deadline)) {
          throw ConflictException(
            'Version $version of $name was retracted on '
            '${retractedAt.toIso8601String()} and can no longer be '
            'restored. Restoration is only allowed within 7 days of '
            'retraction. Publish a new version instead, or set '
            'ENFORCE_RETRACTION_WINDOW=false on the server to relax '
            'this policy on a private registry.',
          );
        }
      }
    }

    await _store.transaction((tx) async {
      await tx.updateVersion(
        name,
        version,
        PackageVersionCompanion(
          packageName: name,
          version: version,
          pubspecJson: existing.pubspecJson,
          libraries: existing.libraries,
          binExecutables: existing.binExecutables,
          archiveSizeBytes: existing.archiveSizeBytes,
          archiveSha256: existing.archiveSha256,
          isRetracted: isRetracted,
          retractedAt: isRetracted ? _clock() : null,
        ),
      );

      // Recompute latest_version / latest_prerelease excluding retracted
      // versions so downstream consumers (pub_api latest content, scoring,
      // list APIs, web UI) never surface a retracted version as "latest".
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
          kind: isRetracted
              ? AuditKind.versionRetracted
              : AuditKind.versionUnretracted,
          agentId: actingUserId,
          packageName: name,
          version: version,
          summary: isRetracted
              ? 'Version $version of $name retracted.'
              : 'Version $version of $name unretracted.',
        ),
      );
    });
  }

  /// Get score and tags for a package version.
  ///
  /// When [version] is null, resolves to the latest stable (or prerelease).
  Future<VersionScore> getScore(String name, {String? version}) async {
    final pkg = await _store.lookupPackage(name);
    if (pkg == null) throw NotFoundException.package(name);

    final resolvedVersion =
        version ?? pkg.latestVersion ?? pkg.latestPrerelease;
    List<String> tags = const [];
    int? granted;
    int? max;

    if (resolvedVersion != null) {
      final pv = await _store.lookupVersion(name, resolvedVersion);
      if (pv != null) tags = pv.tags;

      final score = await _store.lookupScore(name, resolvedVersion);
      if (score != null && score.status == ScoreStatus.completed) {
        granted = score.grantedPoints;
        max = score.maxPoints;
      }
    }

    return VersionScore(
      grantedPoints: granted ?? 0,
      maxPoints: max ?? 0,
      likeCount: pkg.likesCount,
      downloadCount30Days: await _downloadService.total30Days(name),
      tags: tags,
    );
  }

  /// List uploaders for a package.
  Future<List<String>> getUploaders(String name) async {
    final pkg = await _store.lookupPackage(name);
    if (pkg == null) throw NotFoundException.package(name);
    return _store.listUploaders(name);
  }

  /// Check if a user can admin a package (uploader, publisher admin, or server admin).
  /// Returns true if the user has admin access, false otherwise.
  Future<bool> isPackageAdmin(String name, String userId) async {
    final user = await _store.lookupUserById(userId);
    if (user != null && user.isAdmin) return true;

    final pkg = await _store.lookupPackage(name);
    if (pkg == null) return false;

    if (pkg.isOwnedByPublisher) {
      return _store.isPublisherAdmin(pkg.publisherId!, userId);
    } else {
      return _store.isUploader(name, userId);
    }
  }

  /// Check if a user can admin a package; throws if not.
  Future<void> _requirePackageAdmin(String name, String userId) async {
    final canAdmin = await isPackageAdmin(name, userId);
    if (!canAdmin) throw ForbiddenException.notUploader(name);
  }

  VersionInfo _toVersionInfo(PackageVersion pv, Uri baseUrl) {
    final pubspec = _parsePubspec(pv.pubspecJson);
    return VersionInfo(
      version: pv.version,
      retracted: pv.isRetracted ? true : null,
      pubspec: pubspec,
      archiveUrl: archiveUrl(pv.packageName, pv.version, baseUrl).toString(),
      archiveSha256: pv.archiveSha256,
      published: pv.publishedAt,
    );
  }

  Map<String, dynamic> _parsePubspec(String json) {
    try {
      return Map<String, dynamic>.from(jsonDecode(json) as Map);
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}
