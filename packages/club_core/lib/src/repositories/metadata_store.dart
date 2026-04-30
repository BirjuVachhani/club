import '../models/api/package_download_history.dart';
import '../models/api_token.dart';
import '../models/audit_log.dart';
import '../models/dartdoc_status.dart';
import '../models/package.dart';
import '../models/package_score.dart';
import '../models/package_version.dart';
import '../models/publisher.dart';
import '../models/publisher_member.dart';
import '../models/publisher_verification.dart';
import '../models/upload_session.dart';
import '../models/user.dart';
import '../models/user_invite.dart';

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

  Future<Package?> lookupPackage(String name);
  Future<Package> createPackage(PackageCompanion companion);
  Future<Package> updatePackage(String name, PackageCompanion companion);
  Future<void> deletePackage(String name);
  Future<Page<Package>> listPackages({
    int limit = 50,
    String? pageToken,
    String? query,
  });

  /// List packages where [userId] is an uploader or a member of the owning
  /// publisher. Used by the "My packages" page. Results are sorted by
  /// [Package.updatedAt] descending.
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
    int limit = 50,
    String? pageToken,
    bool includeUnlisted = true,
  });

  // ── Package Versions ───────────────────────────────────────

  Future<PackageVersion?> lookupVersion(String package, String version);
  Future<PackageVersion> createVersion(PackageVersionCompanion companion);
  Future<PackageVersion> updateVersion(
    String package,
    String version,
    PackageVersionCompanion companion,
  );
  Future<void> deleteVersion(String package, String version);
  Future<List<PackageVersion>> listVersions(String package);

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

  // ── Transactions ───────────────────────────────────────────

  Future<T> transaction<T>(Future<T> Function(MetadataStore tx) action);
}
