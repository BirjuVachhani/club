import '../models/version_dependency.dart';

/// Flatten a decoded pubspec into dependency edges.
///
/// Pure and I/O-free: it is called at publish time with the pubspec that was
/// just parsed out of the archive, and again during backfill with the JSON
/// already stored in `package_versions.pubspec_json`. Both paths must
/// produce identical rows for the same input, so all the environment-
/// dependent knowledge arrives as parameters.
///
/// [selfOrigin] is this server's own origin, already normalised by
/// `normaliseHostedOrigin` (scheme + host + non-default port). A dependency
/// with an explicit `hosted:` URL matching it is the *only* thing that gets
/// [VersionDependency.isLocal], because it is the only form that
/// unambiguously resolves back here for every consumer.
///
/// [isLocallyHosted] answers "does a package with this name exist on this
/// server". It is used **only** to flag a bare dependency as ambiguous, never
/// to promote one to local. Promoting would mean that publishing an internal
/// package named `http` retroactively reclassified every bare `http:` in the
/// registry as club-hosted, which is both wrong and unstable.
///
/// Pass [pubspec] as the decoded YAML/JSON map. Anything malformed is skipped
/// rather than thrown on: this runs during backfill over historical rows that
/// predate current validation, and one weird pubspec must not stop the batch.
List<VersionDependency> extractDependencies(
  Map<String, dynamic> pubspec, {
  required String? selfOrigin,
  required bool Function(String name) isLocallyHosted,
}) {
  final result = <VersionDependency>[];

  for (final (section, kind) in const [
    ('dependencies', DependencyKind.direct),
    ('dev_dependencies', DependencyKind.dev),
    ('dependency_overrides', DependencyKind.override),
  ]) {
    final raw = pubspec[section];
    if (raw is! Map) continue;

    for (final entry in raw.entries) {
      final name = entry.key;
      if (name is! String || name.isEmpty) continue;

      final dep = _classify(
        name: name,
        kind: kind,
        spec: entry.value,
        selfOrigin: selfOrigin,
        isLocallyHosted: isLocallyHosted,
      );
      if (dep != null) result.add(dep);
    }
  }

  return result;
}

VersionDependency? _classify({
  required String name,
  required DependencyKind kind,
  required Object? spec,
  required String? selfOrigin,
  required bool Function(String name) isLocallyHosted,
}) {
  // `foo: ^1.0.0`, or `foo:` with no value at all (meaning `any`).
  if (spec == null || spec is String) {
    return _bare(
      name: name,
      kind: kind,
      constraintText: spec as String?,
      isLocallyHosted: isLocallyHosted,
    );
  }

  if (spec is! Map) {
    // A number, a list, something else entirely. Not resolvable and not
    // classifiable; record it as bare with no constraint so the row still
    // exists and a human can see something is off.
    return _bare(name: name, kind: kind, isLocallyHosted: isLocallyHosted);
  }

  final constraintText = spec['version'] is String
      ? spec['version'] as String
      : null;

  if (spec.containsKey('sdk')) {
    return VersionDependency(
      name: name,
      kind: kind,
      source: DependencySource.sdk,
      constraintText: constraintText,
    );
  }
  if (spec.containsKey('git')) {
    return VersionDependency(
      name: name,
      kind: kind,
      source: DependencySource.git,
      constraintText: constraintText,
    );
  }
  if (spec.containsKey('path')) {
    return VersionDependency(
      name: name,
      kind: kind,
      source: DependencySource.path,
      constraintText: constraintText,
    );
  }

  if (spec.containsKey('hosted')) {
    final hostedUrl = _hostedUrlOf(spec['hosted']);
    // `hosted:` present but with no usable URL (e.g. `hosted: {name: foo}`,
    // the legacy long form without `url`). pub treats a missing url as the
    // default host, so this behaves exactly like a bare dependency.
    if (hostedUrl == null) {
      return _bare(
        name: name,
        kind: kind,
        constraintText: constraintText,
        isLocallyHosted: isLocallyHosted,
      );
    }
    final origin = _normaliseOrigin(hostedUrl);
    return VersionDependency(
      name: name,
      kind: kind,
      source: DependencySource.hosted,
      hostedOrigin: origin,
      // Null selfOrigin means the server URL could not be normalised,
      // which should be impossible in practice, but if it happens, `null
      // == null` would mark every hosted dependency as local and drag the
      // entire registry into every closure. Guard explicitly.
      isLocal: origin != null && selfOrigin != null && origin == selfOrigin,
      constraintText: constraintText,
    );
  }

  // A map with none of the recognised source keys: `foo: {version: ^1.0.0}`
  // is the long form of a default-hosted dependency.
  return _bare(
    name: name,
    kind: kind,
    constraintText: constraintText,
    isLocallyHosted: isLocallyHosted,
  );
}

VersionDependency _bare({
  required String name,
  required DependencyKind kind,
  required bool Function(String name) isLocallyHosted,
  String? constraintText,
}) {
  return VersionDependency(
    name: name,
    kind: kind,
    source: DependencySource.bare,
    isAmbiguous: isLocallyHosted(name),
    constraintText: constraintText,
  );
}

/// Pull the URL out of either `hosted:` form.
///
/// Short form (Dart 2.19+): `hosted: https://club.example.com`
/// Long form:               `hosted: {name: foo, url: https://...}`
String? _hostedUrlOf(Object? hosted) {
  if (hosted is String) return hosted;
  if (hosted is Map) {
    final url = hosted['url'];
    if (url is String) return url;
  }
  return null;
}

/// Local copy of the origin normaliser.
///
/// `club_package_reader` exports `normaliseHostedOrigin` with identical
/// semantics, but `club_core` deliberately has no I/O or archive
/// dependencies and does not depend on that package.
///
/// The two must agree exactly. A drift is a visibility bypass: a dependency
/// that publish validation accepted as "hosted here" but that the closure
/// walk read as external would let a package go public while a club-hosted
/// dependency it needs stayed private. `club_server`'s
/// `test/unit/origin_normalisation_parity_test.dart` pins them against a
/// shared table of cases, because that is the one package depending on
/// both. Change either implementation and that test fails.
String? _normaliseOrigin(String url) {
  Uri u;
  try {
    u = Uri.parse(url.trim());
  } catch (_) {
    return null;
  }
  if (u.scheme.isEmpty || u.host.isEmpty) return null;
  final scheme = u.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  final host = u.host.toLowerCase();
  final defaultPort = scheme == 'https' ? 443 : 80;
  final port = u.hasPort && u.port != defaultPort ? ':${u.port}' : '';
  return '$scheme://$host$port';
}

/// Normalise [url] to a comparable origin, or null when it is not an
/// absolute http/https URL. Exposed so callers (bootstrap normalising
/// `SERVER_URL`, the visibility service) use the same rule as extraction.
String? normaliseDependencyOrigin(String url) => _normaliseOrigin(url);
