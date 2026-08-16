/// Proof that the caller decided what this request is allowed to see.
///
/// ## Why a type rather than a boolean
///
/// Club has two kinds of read. A *single-resource* read (`GET
/// /api/packages/foo`) names its subject in the path, so one gate ahead of
/// the handlers can resolve that name, check its visibility, and deny
/// before any handler runs. A *collection* read (`/api/search`,
/// `/api/discover`, `/api/packages`) does not: the response is assembled
/// from rows the gate never saw, and nothing about the request says which
/// of them the caller may know exists.
///
/// Collections are therefore the half that a path-level gate cannot
/// protect, and they are the half this type exists for. Every collection
/// method on [MetadataStore] and [SearchIndex] takes a [VisibilityScope]
/// as a **required named parameter** of a type with no public
/// constructor. A new call site does not compile until someone writes
/// down which answer they want, including call sites in code that does
/// not exist yet.
///
/// Single-resource lookups (`lookupPackage`, `lookupVersion`)
/// deliberately do *not* take a scope. The gate itself has to call
/// `lookupPackage` to find out whether a package is public, so a filtered
/// lookup would be circular. Those reads are protected by
/// `PublicPackageAccess` in the auth middleware instead, which is a
/// single enumerated choke point with its own snapshot test.
///
/// ## What this does not do
///
/// It is a compile error exactly once. Afterwards a contributor can write
/// [trustedInternal] and be back where they started. The type raises the
/// cost of the mistake and makes it visible in review; it does not make it
/// impossible. What holds the line is
/// `club_server/test/unit/visibility_scope_callers_test.dart`, which pins
/// the set of files permitted to name [trustedInternal] at all. Adding a
/// file to that list is the deliberate act; forgetting to filter is not.
final class VisibilityScope {
  const VisibilityScope._({required this.publicOnly, this.viewerUserId});

  /// No credentials, or credentials that grant nothing beyond anonymous
  /// access. Only rows with `visibility = 'public'` may be returned, and
  /// only versions flagged `public_resolvable`.
  static const anonymous = VisibilityScope._(publicOnly: true);

  /// Everything, unfiltered.
  ///
  /// Correct for background work (scoring, dartdoc, the dependency
  /// backfill), for write paths, and for the authenticated read paths
  /// where club's model already says any signed-in user may browse the
  /// whole registry. Never correct for a response that an unauthenticated
  /// request could receive.
  static const trustedInternal = VisibilityScope._(publicOnly: false);

  /// A signed-in user. Today this is equivalent to [trustedInternal] for
  /// reads, because club has no per-user package ACL: authentication is
  /// the only boundary, and every authenticated user may browse
  /// everything. The user id is carried anyway so that adding a
  /// per-package ACL later is a change inside the store rather than a
  /// change to every call site.
  factory VisibilityScope.authenticated(String userId) =>
      VisibilityScope._(publicOnly: false, viewerUserId: userId);

  /// True when this scope may only see public rows.
  final bool publicOnly;

  /// The signed-in user, when there is one.
  final String? viewerUserId;

  @override
  String toString() => publicOnly
      ? 'VisibilityScope.anonymous'
      : 'VisibilityScope(user: ${viewerUserId ?? 'internal'})';
}
