import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:logging/logging.dart';

final _log = Logger('DependencyIndexBackfill');

/// Bumped when the extraction rules change in a way that makes previously
/// written rows wrong. Stored in `server_settings` so a rebuild happens
/// once per server, not once per boot.
const int dependencyIndexVersion = 1;

/// The `server_settings` key holding the [dependencyIndexVersion] that the
/// stored rows were built with.
const String dependencyIndexVersionKey = 'dependency_index_version';

/// The `server_settings` key holding the origin the stored rows were built
/// against. A changed `SERVER_URL` invalidates every `is_local` flag: the
/// same `hosted:` URL that used to point here now points elsewhere, or
/// vice versa.
const String dependencyIndexOriginKey = 'dependency_index_origin';

/// Stand-in dependency recorded when a version's stored pubspec cannot be
/// parsed, so its real dependencies are unknown.
///
/// Writing no edges at all would be **fail-open**, not fail-closed: an
/// empty closure tells the operator the package needs nothing, and
/// `recomputePublicResolvable` finds no blocker and advertises the version
/// to anonymous clients. If the real pubspec had a private club-hosted
/// dependency, `dart pub get` then fails for everyone with an opaque 401.
///
/// This name is deliberately illegal as a package name (`!` is outside
/// `^[a-z][a-z0-9_]*$`), so it can never collide with a real package. It
/// is marked local and direct, which makes it participate in the closure,
/// and because no `packages` row will ever match it the recompute's
/// missing-dependency branch treats it as blocking. The visibility preview
/// surfaces it as a closure member that does not exist on this server.
///
/// Cleared automatically the next time the version is republished or the
/// index is rebuilt with a readable pubspec.
const String unknownDependencySentinel = '!unindexed';

/// Populate `package_version_dependencies` for versions published before
/// the index existed, and rebuild it when the rules or the server origin
/// change.
///
/// Runs in Dart rather than as SQL in the migration for one decisive
/// reason: classifying a dependency as club-hosted needs the normalised
/// `SERVER_URL` origin, which a migration does not have. It also needs to
/// know which names exist locally, which is a query per batch rather than
/// something expressible in a single statement.
///
/// Idempotent, and safe to interrupt. Every version is processed
/// independently and `replaceVersionDependencies` deletes before
/// inserting, so a crash halfway leaves a partially-built index that the
/// next boot finishes. The completion marker is only written after the
/// whole pass succeeds, so a partial run never looks finished.
///
/// Returns the number of versions indexed, or null when nothing needed
/// doing.
Future<int?> backfillDependencyIndex({
  required MetadataStore store,
  required SettingsStore settings,
  required String? selfOrigin,
  int batchSize = 200,
}) async {
  final storedVersion = int.tryParse(
    await settings.getSetting(dependencyIndexVersionKey) ?? '',
  );
  final storedOrigin = await settings.getSetting(dependencyIndexOriginKey);
  final originKey = selfOrigin ?? '';

  if (storedVersion == dependencyIndexVersion && storedOrigin == originKey) {
    return null;
  }

  if (storedVersion != null && storedOrigin != originKey) {
    _log.warning(
      'Server origin changed from "${storedOrigin ?? '<unset>'}" to '
      '"${selfOrigin ?? '<unset>'}". Rebuilding the dependency index: '
      'every hosted-dependency classification depended on the old value.',
    );
  }

  final all = await store.listVersionsForRescan(latestOnly: false);
  if (all.isEmpty) {
    await _markComplete(settings, originKey);
    return 0;
  }

  _log.info('Building dependency index for ${all.length} versions.');

  // Resolving "does a package with this name exist here" per dependency
  // would be a query per edge. The set of package names is small relative
  // to the number of edges and changes only on publish, so it is read once
  // up front. The bound matches the ceiling used elsewhere for
  // name-completion; a registry past it loses only the ambiguity warning
  // on bare dependencies, never correctness of the closure itself.
  final localNames = <String>{};
  final packages = await store.listPackages(
    limit: 10000,
    scope: VisibilityScope.trustedInternal,
  );
  for (final p in packages.items) {
    localNames.add(p.name);
  }
  if (packages.nextPageToken != null) {
    _log.warning(
      'More than ${packages.items.length} packages; bare-dependency '
      'ambiguity flags may be incomplete for names beyond that point.',
    );
  }

  var indexed = 0;
  var skipped = 0;

  for (var start = 0; start < all.length; start += batchSize) {
    final end = (start + batchSize).clamp(0, all.length);
    final batch = all.sublist(start, end);

    await store.transaction((tx) async {
      for (final ref in batch) {
        final version = await tx.lookupVersion(ref.packageName, ref.version);
        if (version == null) continue;

        Map<String, dynamic> pubspec;
        try {
          final decoded = jsonDecode(version.pubspecJson);
          if (decoded is! Map) throw const FormatException('not a map');
          pubspec = Map<String, dynamic>.from(decoded);
        } catch (e) {
          // Historical rows predate current validation, and one unreadable
          // pubspec must not abort the pass. But "unreadable" is not the
          // same as "no dependencies": recording nothing would let this
          // version be advertised as publicly resolvable while its real
          // dependencies are unknown. Record the sentinel instead, which
          // blocks resolvability until someone republishes or reindexes.
          _log.warning(
            '${ref.packageName} ${ref.version}: pubspec_json is not '
            'decodable ($e). Recording it as having unknown dependencies, '
            'so it will not be treated as publicly resolvable.',
          );
          await tx.replaceVersionDependencies(ref.packageName, ref.version, [
            const VersionDependency(
              name: unknownDependencySentinel,
              kind: DependencyKind.direct,
              source: DependencySource.hosted,
              isLocal: true,
            ),
          ]);
          skipped++;
          continue;
        }

        await tx.replaceVersionDependencies(
          ref.packageName,
          ref.version,
          extractDependencies(
            pubspec,
            selfOrigin: selfOrigin,
            isLocallyHosted: localNames.contains,
          ),
        );
        indexed++;
      }
    });

    _log.fine('Dependency index: $end/${all.length}.');
  }

  await _markComplete(settings, originKey);
  _log.info(
    'Dependency index built: $indexed versions indexed'
    '${skipped > 0 ? ', $skipped skipped' : ''}.',
  );
  return indexed;
}

Future<void> _markComplete(SettingsStore settings, String originKey) async {
  // Origin first, then version. If the process dies between the two, the
  // version check still fails on the next boot and the pass repeats 
  // wasteful but correct. The reverse order could mark a stale-origin
  // index as current.
  await settings.setSetting(dependencyIndexOriginKey, originKey);
  await settings.setSetting(
    dependencyIndexVersionKey,
    '$dependencyIndexVersion',
  );
}
