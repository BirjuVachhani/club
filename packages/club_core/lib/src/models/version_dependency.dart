import 'package:equatable/equatable.dart';

/// Which pubspec section a dependency was declared in.
///
/// Only [direct] matters for whether a *consumer* can resolve a package,
/// and that is the whole reason this distinction is modelled rather than
/// flattened away:
///
/// - [direct] (`dependencies`) is resolved transitively by every consumer,
///   so a private club-hosted entry here breaks anonymous resolution.
/// - [dev] (`dev_dependencies`) is resolved only for the *root* package of
///   a solve. A dependency's dev dependencies are ignored entirely, so a
///   private one here breaks nobody downstream. It still matters to a
///   human cloning the repo, which is why it is recorded and surfaced
///   rather than dropped.
/// - [override] (`dependency_overrides`) is honoured only for the root
///   package, so it never affects a consumer either. Recorded for
///   completeness; walking it would over-expose packages that no consumer
///   ever fetches.
enum DependencyKind {
  direct('direct'),
  dev('dev'),
  override('override');

  const DependencyKind(this.wireName);

  final String wireName;

  static DependencyKind? tryParse(String? value) {
    if (value == null) return null;
    for (final k in DependencyKind.values) {
      if (k.wireName == value) return k;
    }
    return null;
  }
}

/// How a dependency names its source, which decides whether it can
/// participate in the public-visibility closure.
enum DependencySource {
  /// An explicit `hosted:` block. Participates in the closure only when
  /// its origin matches this server (`VersionDependency.isLocal`).
  hosted('hosted'),

  /// Plain `foo: ^1.0.0` with no `hosted:` key. Publish validation reads
  /// this as pub.dev, but `dart pub` actually resolves it against the
  /// *consumer's* `PUB_HOSTED_URL`. See [VersionDependency.isAmbiguous].
  bare('bare'),

  /// `sdk: flutter` and friends. Never club-hosted.
  sdk('sdk'),

  /// `path:`. Rejected at publish time, but modelled so that a pubspec
  /// that somehow carries one is recorded rather than silently dropped.
  path('path'),

  /// `git:`. Rejected at publish time; same reasoning as [path].
  git('git');

  const DependencySource(this.wireName);

  final String wireName;

  static DependencySource? tryParse(String? value) {
    if (value == null) return null;
    for (final s in DependencySource.values) {
      if (s.wireName == value) return s;
    }
    return null;
  }
}

/// One edge of the dependency graph, flattened out of a version's pubspec.
///
/// The pubspec stays the source of truth. These rows exist so the graph is
/// queryable in both directions, which the visibility closure needs and
/// `json_extract` over `pubspec_json` cannot do without a full scan.
class VersionDependency extends Equatable {
  const VersionDependency({
    required this.name,
    required this.kind,
    required this.source,
    this.hostedOrigin,
    this.isLocal = false,
    this.isAmbiguous = false,
    this.constraintText,
  });

  /// The depended-on package name (the pubspec key).
  final String name;

  final DependencyKind kind;
  final DependencySource source;

  /// Normalised origin (`scheme://host[:port]`) of an explicit `hosted:`
  /// URL, or null for every other source.
  final String? hostedOrigin;

  /// This dependency definitively resolves to a package on *this* server.
  /// Only these participate in the visibility closure.
  final bool isLocal;

  /// A bare dependency whose name also exists as a package on this server.
  ///
  /// Genuinely undecidable from the pubspec alone: a consumer with
  /// `PUB_HOSTED_URL` pointing here gets the local package, and a consumer
  /// without it gets whatever pub.dev serves under that name. Never
  /// treated as local, because making the local package public would not
  /// help the anonymous consumer (who still reaches pub.dev) while
  /// exposing source for nothing. Surfaced so a human can fix the pubspec
  /// to say `hosted:` explicitly.
  final bool isAmbiguous;

  /// The raw version constraint as written, e.g. `^1.2.0`. Null when the
  /// dependency declared none (`foo:` with an empty value, meaning `any`).
  final String? constraintText;

  /// True when this edge must be followed to decide whether a consumer can
  /// resolve the depending version anonymously.
  bool get participatesInClosure =>
      isLocal && kind == DependencyKind.direct;

  @override
  List<Object?> get props => [
    name,
    kind,
    source,
    hostedOrigin,
    isLocal,
    isAmbiguous,
    constraintText,
  ];
}

/// One public package that would stop resolving if some other package
/// became unreachable, together with a path explaining why.
///
/// Exists because "making `b` private will break 3 packages" is not
/// actionable on its own. The person deciding needs to see *how* the
/// breakage reaches them, since the connection is usually indirect and
/// often through a package they did not know depended on anything.
class DependentPath extends Equatable {
  const DependentPath({required this.package, required this.path});

  /// The public package that breaks.
  final String package;

  /// A dependency chain from [package] down to the package being made
  /// unreachable, inclusive at both ends: `['app', 'core_ui', 'icons']`
  /// reads as "app depends on core_ui, which depends on icons".
  ///
  /// One example path, not all of them. Enumerating every path through a
  /// dense graph is exponential and no more persuasive than one concrete
  /// chain.
  final List<String> path;

  /// Renders the chain the way it is shown in confirmations and logs.
  String get pathDescription => path.join(' -> ');

  @override
  List<Object?> get props => [package, path];

  @override
  String toString() => 'DependentPath($pathDescription)';
}
