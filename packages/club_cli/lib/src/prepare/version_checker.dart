/// Queries the target club server for published local versions.
///
/// One concurrent request per package via `client.listVersions`. Only a 404
/// means the package is absent; other failures must not authorize publication
/// or be mistaken for an unavailable dependency.
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

/// A lookup failed without establishing whether the package is published.
class VersionCheckError implements Exception {
  VersionCheckError(this.packageName, this.cause);

  final String packageName;
  final Object cause;

  @override
  String toString() =>
      'Could not verify published versions of $packageName: $cause';
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
  } on ClubNotFoundException {
    return null;
  } catch (e) {
    throw VersionCheckError(pkg.name, e);
  }
}
