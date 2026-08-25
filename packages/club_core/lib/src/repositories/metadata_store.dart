import '../models/api/database_stats.dart';
import '../models/api/package_download_history.dart';
import '../models/api_token.dart';
import '../models/audit_log.dart';
import '../models/dartdoc_status.dart';
import '../models/package.dart';
import '../models/package_group.dart';
import '../models/package_score.dart';
import '../models/package_version.dart';
import '../models/publisher.dart';
import '../models/publisher_member.dart';
import '../models/publisher_verification.dart';
import '../models/upload_session.dart';
import '../models/user.dart';
import '../models/user_invite.dart';
import '../models/version_dependency.dart';
import 'visibility_scope.dart';

/// Page of results from list queries.
class Page<T> {
  const Page({required this.items, this.nextPageToken, this.totalCount = -1});

  final List<T> items;
  final String? nextPageToken;
  final int totalCount;
}

/// Abstract interface for all relational metadata operations.
///
/// Implementations: SqliteMetadataStore, PostgresMetadataStore.
abstract interface class MetadataStore {
  // ── Lifecycle ──────────────────────────────────────────────

  Future<void> open();
  Future<void> close();
  Future<void> runMigrations();

  // ── Packages ───────────────────────────────────────────────

  /// Single-package lookup, deliberately unscoped.
  ///
  /// The anonymous gate itself calls this to find out whether a package is
  /// public, so a filtered version would be circular. Reads of a named
  /// package are protected by `PublicPackageAccess` in the auth
  /// middleware, not here. See [VisibilityScope] for the split.
  Future<Package?> lookupPackage(String name);
  Future<Package> createPackage(PackageCompanion companion);
  Future<Package> updatePackage(String name, PackageCompanion companion);
  Future<void> deletePackage(String name);

  /// [scope] is required because no path-level check can protect a
  /// collection: the caller is asking for rows it has not named, and
  /// nothing in the request says which of them it may know exist.
  ///
  /// [includeUnlisted] defaults to true, which is the "give me everything"
  /// answer wanted by admin views and background jobs. Pass false on any
  /// **discovery** surface (autocomplete, browse listings): an unlisted
  /// package is meant to be reachable by URL only, so suggesting its name
  /// defeats the point. Note this is a listing hint, not access control:
  /// [scope] is what decides who may see a package at all.
  Future<Page<Package>> listPackages({
    required VisibilityScope scope,
    int limit = 50,
    String? pageToken,
    String? query,
    bool includeUnlisted = true,
  });

  /// Whether at least one package on this server is public.
  ///
  /// Drives the SPA's decision between a browsable landing page and a
  /// login wall, so it runs on every cold load. Backed by
  /// `idx_packages_visibility` and returns on the first row rather than
  /// counting.
  Future<bool> hasAnyPublicPackage();

  /// List packages where [userId] is an uploader or a member of the owning
  /// publisher. Used by the "My packages" page. Results are sorted by
  /// [Package.updatedAt] descending.
  ///
  /// No scope: the query is already restricted to packages [userId] owns,
  /// and an anonymous caller has no user id to pass.
  Future<Page<Package>> listPackagesForUser(
    String userId, {
    int limit = 50,
    String? pageToken,
    String? query,
  });

  /// List packages owned by [publisherId]. Set [includeUnlisted] to include
  /// packages marked unlisted. Used by publisher detail pages.
  Future<Page<Package>> listPackagesForPublisher(
    String publisherId, {
    required VisibilityScope scope,
    int limit = 50,
    String? pageToken,
    bool includeUnlisted = true,
  });

  // ── Package Groups ─────────────────────────────────────────

  Future<PackageGroup?> lookupPackageGroup(String id);
  Future<PackageGroup?> lookupPackageGroupBySlug(String slug);
  Future<PackageGroup> createPackageGroup(PackageGroupCompanion companion);
  Future<PackageGroup> updatePackageGroup(
    String id, {
    required String name,
    String? description,
  });
  Future<void> deletePackageGroup(String id);
  Future<Page<PackageGroup>> listPackageGroups({
    required VisibilityScope scope,
    int limit = 50,
    String? pageToken,
    String? query,
    bool includeEmpty = false,
  });
  Future<List<PackageGroup>> listPackageGroupsForUser(String userId);
  Future<List<PackageGroup>> listPackageGroupsForPackage(String packageName);
  Future<Page<Package>> listPackagesForGroup(
    String groupId, {
    required VisibilityScope scope,
    int limit = 50,
    String? pageToken,
    bool includeUnlisted = false,
  });
  Future<List<PackageGroupPackage>> listPackageGroupMemberships(String groupId);
  Future<void> addPackageToGroup(
    String groupId,
    String packageName, {
    required String addedBy,
  });
  Future<void> removePackageFromGroup(String groupId, String packageName);
  Future<void> normalizePackageGroupPositions(String groupId);
  Future<void> movePackageBetweenGroups(
    String packageName, {
    required String fromGroupId,
    required String toGroupId,
    required String addedBy,
  });
  Future<void> reorderPackageGroup(String groupId, List<String> packageNames);
  Future<void> replacePackageGroupPackages(
    String groupId,
    List<String> packageNames, {
    required String addedBy,
  });

  // ── Package Versions ───────────────────────────────────────

  /// Unscoped for the same reason as [lookupPackage]: the request names
  /// its subject, so the middleware gate covers it.
  Future<PackageVersion?> lookupVersion(String package, String version);
  Future<PackageVersion> createVersion(PackageVersionCompanion companion);
  Future<PackageVersion> updateVersion(
    String package,
    String version,
    PackageVersionCompanion companion,
  );
  Future<void> deleteVersion(String package, String version);

  /// Versions of [package].
  ///
  /// [scope] is required even though the package is named, because this
  /// list is the input to a `pub` version solve. Under
  /// [VisibilityScope.anonymous] it returns only versions flagged
  /// `public_resolvable`, so a solver never selects a version whose
  /// club-hosted dependency would 401.
  Future<List<PackageVersion>> listVersions(
    String package, {
    required VisibilityScope scope,
  });

  // ── Version Dependencies ───────────────────────────────────
  //
  // A queryable index over what each version declares, derived from its
  // pubspec at publish time. The pubspec stays authoritative; these rows
  // exist so the graph can be walked in both directions.

  /// Replace every recorded dependency edge for one version.
  ///
  /// Delete-then-insert, because a forced republish overwrites a version
  /// in place and its dependency set may have changed. Must be called
  /// inside the same transaction as the version write, and must not open
  /// a transaction of its own: [transaction] hands back the same store,
  /// so a nested call would nest the underlying transaction.
  Future<void> replaceVersionDependencies(
    String package,
    String version,
    List<VersionDependency> dependencies,
  );

  /// Every edge recorded for one version, all kinds included.
  Future<List<VersionDependency>> listVersionDependencies(
    String package,
    String version,
  );

  /// Names of packages hosted on this server that [roots] need, directly
  /// or transitively, in order to resolve.
  ///
  /// The union over **all** versions of each package, not just the latest:
  /// a consumer's constraint may select any version, and `pub` aborts
  /// rather than backtracking when a version's dependency returns 401, so
  /// a closure that covered only the newest version would still break
  /// resolution the moment the solver probed an older one.
  ///
  /// Walks only [DependencyKind.direct] edges flagged [VersionDependency
  /// .isLocal]: dev dependencies and overrides are honoured solely for the
  /// root package of a solve and never affect a consumer.
  ///
  /// The visited set is keyed on package name, so the cycles that `pub`
  /// permits between packages converge. [roots] are included in the
  /// result.
  Future<Set<String>> localDependencyClosure(
    Set<String> roots, {
    bool includeDev = false,
  });

  /// The reverse of [localDependencyClosure]: names of packages hosted
  /// here that would fail to resolve if every package in [roots] became
  /// unreachable. [roots] are included in the result.
  Future<Set<String>> localDependentsClosure(Set<String> roots);

  /// Public packages that transitively depend on [package], each with one
  /// example path showing how (`['app', 'core_ui', package]`).
  ///
  /// This is the guard on making a package private, on deleting it, and on
  /// deleting its last usable version. An empty list means the transition
  /// breaks nothing.
  Future<List<DependentPath>> findPublicDependents(String package);

  /// [findPublicDependents] for a whole set at once: public packages that
  /// transitively depend on **any** member of [packages].
  ///
  /// Members of [packages] are excluded from the result. They are being
  /// made unreachable together, so one depending on another is not
  /// breakage, and reporting it would read as a warning about a change the
  /// operator already chose.
  ///
  /// A visibility flip applies to a whole selected set, so the guard has to
  /// analyse that set. Calling the single-package version once per member
  /// would both cost N reverse walks and miss nothing only by accident:
  /// this runs one walk seeded with every root, so a dependent reachable
  /// from a non-root member is found with a path that explains which member
  /// it hangs off.
  Future<List<DependentPath>> findPublicDependentsOfAny(Set<String> packages);

  /// Recompute `public_resolvable` for [versions], or for every version of
  /// [packages] when no explicit version list is given.
  ///
  /// A version is resolvable when its package is public and every direct
  /// club-hosted dependency it declares belongs to a public package.
  /// Returns the number of rows whose value actually changed.
  Future<int> recomputePublicResolvable(Set<String> packages);

  /// Package names that declare a direct club-hosted dependency on any of
  /// [names]. Used to scope a `public_resolvable` recompute after a
  /// visibility flip instead of rebuilding the whole table.
  Future<Set<String>> packagesDependingOn(Set<String> names);

  // ── Users ──────────────────────────────────────────────────

  Future<User?> lookupUserById(String userId);
  Future<User?> lookupUserByEmail(String email);
  Future<User> createUser(UserCompanion companion);
  Future<User> updateUser(String userId, UserCompanion companion);
  Future<void> deleteUser(String userId);
  Future<Page<User>> listUsers({
    int limit = 50,
    String? pageToken,
    String? emailFilter,
  });

  /// Lookup a user's password hash. Separate from lookupUser to avoid
  /// accidentally leaking the hash through the User model.
  Future<String?> lookupPasswordHash(String userId);

  /// Get the base64-encoded PNG avatar for a user, or null if none set.
  Future<String?> getAvatar(String userId);

  /// Store a base64-encoded PNG avatar and set has_avatar = 1.
  Future<void> setAvatar(String userId, String base64Png);

  /// Remove the avatar and set has_avatar = 0.
  Future<void> deleteAvatar(String userId);

  // ── User Invites ───────────────────────────────────────────
  // Backs the "admin creates a user with a one-time invite link" flow.

  Future<UserInvite> createInvite(UserInviteCompanion companion);
  Future<UserInvite?> lookupInviteByHash(String tokenHash);
  Future<void> markInviteUsed(String inviteId);

  // ── Auth Tokens ────────────────────────────────────────────

  Future<ApiToken?> lookupTokenByHash(String tokenHash);
  Future<ApiToken> createToken(ApiTokenCompanion companion);
  Future<void> revokeToken(String tokenId);

  /// Revoke every non-revoked token for [userId]. If [kind] is given, only
  /// tokens of that kind are revoked. Used for "sign out everywhere" and
  /// for invalidating all sessions after a password change.
  Future<void> revokeAllTokensForUser(String userId, {ApiTokenKind? kind});

  Future<void> updateTokenLastUsed(String tokenId, DateTime at);

  /// For session tokens: extend [expiresAt] on active use, clamped by
  /// [absoluteExpiresAt]. No-op for PATs.
  Future<void> slideSessionExpiry(String tokenId, DateTime newExpiresAt);

  Future<List<ApiToken>> listTokensForUser(String userId, {ApiTokenKind? kind});

  // ── Publishers ─────────────────────────────────────────────

  Future<Publisher?> lookupPublisher(String publisherId);
  Future<Publisher> createPublisher(PublisherCompanion companion);
  Future<Publisher> updatePublisher(
    String publisherId,
    PublisherCompanion companion,
  );
  Future<void> deletePublisher(String publisherId);
  Future<List<Publisher>> listPublishers();

  /// Publishers where [userId] is a member (any role).
  Future<List<Publisher>> listPublishersForUser(String userId);

  /// Count of verified publishers the user is a member of. Used to
  /// enforce per-user verified-publisher quota at creation time.
  Future<int> countVerifiedPublishersForUser(String userId);

  // ── Publisher Verifications ────────────────────────────────
  // Pending DNS proofs. Pairs (user_id, domain) are unique — a user
  // can only have one in-flight verification per domain.

  Future<PublisherVerification> upsertVerification(
    PublisherVerificationCompanion companion,
  );
  Future<PublisherVerification?> lookupVerification(
    String userId,
    String domain,
  );
  Future<void> deleteVerification(String id);
  Future<int> deleteExpiredVerifications();

  // ── Publisher Members ──────────────────────────────────────

  Future<List<PublisherMember>> listPublisherMembers(String publisherId);
  Future<void> addPublisherMember(PublisherMemberCompanion companion);
  Future<void> removePublisherMember(String publisherId, String userId);
  Future<bool> isPublisherAdmin(String publisherId, String userId);
  Future<bool> isPublisherMember(String publisherId, String userId);

  // ── Uploaders ──────────────────────────────────────────────

  Future<List<String>> listUploaders(String packageName);
  Future<void> addUploader(String packageName, String userId);
  Future<void> removeUploader(String packageName, String userId);
  Future<bool> isUploader(String packageName, String userId);

  // ── Likes ──────────────────────────────────────────────────

  Future<bool> hasLike(String userId, String packageName);
  Future<void> likePackage(String userId, String packageName);
  Future<void> unlikePackage(String userId, String packageName);
  Future<int> likeCount(String packageName);
  Future<List<String>> likedPackages(String userId);

  // ── Upload Sessions ────────────────────────────────────────

  Future<UploadSession?> lookupUploadSession(String id);
  Future<void> createUploadSession(UploadSessionCompanion companion);
  Future<void> updateUploadSessionState(String id, UploadState state);
  Future<void> deleteExpiredUploadSessions();
  Future<int> countPendingUploads(String userId);

  // ── Audit Log ──────────────────────────────────────────────

  Future<void> appendAuditLog(AuditLogCompanion companion);
  Future<List<AuditLogRecord>> queryAuditLog({
    String? packageName,
    String? agentId,
    String? publisherId,
    int limit = 50,
    DateTime? before,
  });

  // ── Package Scores ─────────────────────────────────────────

  Future<PackageScore?> lookupScore(String packageName, String version);
  Future<void> saveScore(PackageScoreCompanion companion);
  Future<List<PackageScore>> listPendingScores();
  Future<void> resetStaleRunningScores();

  /// Count packages whose latest version has no completed score.
  Future<({int total, int scored})> countScoringCoverage();

  /// List (package, version) pairs that have no completed score.
  Future<List<({String packageName, String version})>> listUnscoredVersions();

  /// List (package, version) pairs for a rescan.
  ///
  /// When [latestOnly] is true, returns one entry per package (the latest
  /// stable, falling back to prerelease). When false, returns every version
  /// of every package.
  Future<List<({String packageName, String version})>> listVersionsForRescan({
    required bool latestOnly,
  });

  // ── Dartdoc ────────────────────────────────────────────

  Future<DartdocRecord?> lookupDartdoc(String packageName);
  Future<void> saveDartdoc(DartdocRecordCompanion companion);
  Future<List<DartdocRecord>> listPendingDartdocs();
  Future<void> resetStaleRunningDartdocs();

  // ── Download Counts ─────────────────────────────────────────

  /// Atomically increment the daily download counter for [package]/[version].
  /// [dateUtc] must be an ISO-8601 date string (e.g. '2025-04-17').
  Future<void> recordDownload(String package, String version, String dateUtc);

  /// Return the total download count for [package] (all versions) over the
  /// last [days] calendar days, inclusive of today.
  Future<int> totalDownloads(String package, {int days = 30});

  /// Return weekly download buckets for the last [weeks] weeks (including
  /// the current partial week), broken down by version. Ordered oldest-to-newest.
  Future<List<DownloadWeek>> weeklyDownloads(String package, {int weeks = 53});

  // ── Aggregate Counts ────────────────────────────────────────

  /// Return total counts for packages, versions, and users.
  Future<({int packages, int versions, int users})> counts();

  /// Storage stats reported by the database engine itself: total size,
  /// reclaimable space, and the [topTables] largest relations.
  ///
  /// Returns null when the backend cannot report them, so callers degrade to
  /// "unavailable" rather than failing. Prefer that over throwing: this feeds
  /// an admin dashboard where every other panel should still render.
  Future<DatabaseStats?> databaseStats({int topTables = 8});

  // ── Transactions ───────────────────────────────────────────

  Future<T> transaction<T>(Future<T> Function(MetadataStore tx) action);
}
