/// Queries the target club server to discover which packages in the
/// publish closure already have their local version published.
///
/// One concurrent request per package via `client.listVersions`. A 404 / network
/// error is treated as "package does not exist on server" (no conflict),
/// matching the existing behaviour in publish_runner.dart's
/// `_fetchPublishedVersions`.
library;

import 'package:club_api/club_api.dart';

import 'package_discovery.dart';

/// One package whose local version is already published.
class VersionConflict {
  VersionConflict({
    required this.packageName,
    required this.localVersion,
    required this.serverUrl,
  });

  final String packageName;
  final String localVersion;
  final String serverUrl;
}

/// Concurrently fetch published-version sets and return the conflict list
/// in the same order as [order]. Packages with no `version:` field are
/// skipped (the planner surfaces them as a separate error earlier).
Future<List<VersionConflict>> findVersionConflicts({
  required ClubClient client,
  required Map<String, DiscoveredPackage> packages,
  required List<String> order,
  required String serverUrl,
}) async {
  final results = await Future.wait([
    for (final name in order)
      _checkOne(client, packages[name]!, serverUrl: serverUrl),
  ]);
  return [for (final r in results) ?r];
}

Future<VersionConflict?> _checkOne(
  ClubClient client,
  DiscoveredPackage pkg, {
  required String serverUrl,
}) async {
  final localVersion = pkg.version;
  if (localVersion == null) return null;

  try {
    final data = await client.listVersions(pkg.name);
    final exists = data.versions.any((v) => v.version == localVersion);
    if (!exists) return null;
    return VersionConflict(
      packageName: pkg.name,
      localVersion: localVersion,
      serverUrl: serverUrl,
    );
  } catch (_) {
    // Package not found on server (404) or network hiccup. Mirrors the
    // pre-publish check in publish_runner — treat as "no conflict" so the
    // publish path can attempt the upload and surface the real error.
    return null;
  }
}
