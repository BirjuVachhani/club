import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../exceptions.dart';
import '../models/audit_log.dart';
import '../models/publisher.dart';
import '../models/publisher_member.dart';
import '../models/publisher_verification.dart';
import '../repositories/metadata_store.dart';

/// Abstract DNS TXT resolver the verification flow calls out to. Lives
/// in core (not server) so the service can be unit-tested with a fake
/// and the real DoH implementation lives next to the shelf plumbing.
abstract class PublisherDnsResolver {
  Future<List<String>> lookupTxt(String name);
}

/// Handles publisher (organization) management.
class PublisherService {
  PublisherService({
    required MetadataStore store,
    required this.generateId,
    PublisherDnsResolver? dnsResolver,
    Duration verificationTtl = const Duration(hours: 24),
    int maxVerifiedPublishersPerUser = 10,
  }) : _store = store,
       _dns = dnsResolver,
       _verificationTtl = verificationTtl,
       _maxVerifiedPerUser = maxVerifiedPublishersPerUser;

  final MetadataStore _store;
  final String Function() generateId;
  final PublisherDnsResolver? _dns;
  final Duration _verificationTtl;
  final int _maxVerifiedPerUser;

  // ── Regex gatekeepers ────────────────────────────────────────

  /// Internal (unverified) publisher IDs: lowercase alphanumerics +
  /// single hyphens, 2-64 chars, never contains a dot. The absence of a
  /// dot is what keeps internal IDs from colliding with verified domain
  /// IDs — a clean partition of the namespace.
  static final _internalIdPattern = RegExp(
    r'^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$',
  );

  /// Loose domain-shape check: two or more labels separated by dots.
  /// Each label is alphanumeric + hyphens. We don't try to validate
  /// TLDs — if the DNS resolver can find a TXT record under it, it's
  /// good enough to call a domain.
  static final _domainPattern = RegExp(
    r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$',
  );

  /// TXT records are probed at this subdomain so we don't collide with
  /// SPF / DKIM / DMARC at the apex.
  static String verificationHost(String domain) => '_club-verify.$domain';
  static String verificationValue(String token) => 'club-verify=$token';

  // ── Internal publishers (admin-only, arbitrary slug) ─────────

  /// Create an unverified, admin-provisioned publisher. The ID must be a
  /// slug without dots — domain-shaped IDs are reserved for verified
  /// publishers so they can never collide. The acting admin is assumed
  /// to have already passed their own role check at the API boundary.
  ///
  /// If [initialAdminUserId] is given, that user becomes the publisher
  /// admin. Otherwise the creating admin is added.
  Future<Publisher> createInternalPublisher({
    required String id,
    required String displayName,
    String? description,
    String? websiteUrl,
    String? contactEmail,
    required String createdByUserId,
    String? initialAdminUserId,
  }) async {
    final normalizedId = id.trim().toLowerCase();
    if (!_internalIdPattern.hasMatch(normalizedId)) {
      throw const InvalidInputException(
        'Internal publisher IDs must be 2-64 lowercase letters, digits, '
        'and hyphens. Dots are reserved for verified publishers.',
      );
    }
    if (displayName.trim().isEmpty) {
      throw const InvalidInputException('Display name is required.');
    }

    final existing = await _store.lookupPublisher(normalizedId);
    if (existing != null) {
      throw ConflictException('Publisher \'$normalizedId\' already exists.');
    }

    final adminUserId = initialAdminUserId ?? createdByUserId;
    final adminUser = await _store.lookupUserById(adminUserId);
    if (adminUser == null) throw NotFoundException.user(adminUserId);

    final pub = await _store.createPublisher(
      PublisherCompanion(
        id: normalizedId,
        displayName: displayName.trim(),
        description: description,
        websiteUrl: websiteUrl,
        contactEmail: contactEmail,
        verified: false,
        createdBy: createdByUserId,
      ),
    );

    await _store.addPublisherMember(
      PublisherMemberCompanion(
        publisherId: normalizedId,
        userId: adminUserId,
        role: PublisherRole.admin,
      ),
    );

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.publisherCreated,
        agentId: createdByUserId,
        publisherId: normalizedId,
        summary:
            'Internal publisher "$displayName" ($normalizedId) created. '
            'First admin: ${adminUser.email}.',
      ),
    );

    return pub;
  }

  // ── Verified publishers (DNS-proven) ─────────────────────────

  /// Start a DNS-based verification. Returns the raw token (shown to
  /// the user once, so they can put it in DNS) and the expiry. Idempotent
  /// on (user, domain): reissuing overwrites the previous pending token.
  Future<({String token, DateTime expiresAt, String host, String value})>
  startVerification({
    required String userId,
    required String domain,
    required String displayName,
  }) async {
    final normalizedDomain = domain.trim().toLowerCase();
    if (!_domainPattern.hasMatch(normalizedDomain)) {
      throw const InvalidInputException(
        'Enter a valid domain like "example.com" — '
        'no scheme, path, or port.',
      );
    }
    if (displayName.trim().isEmpty) {
      throw const InvalidInputException('Display name is required.');
    }

    // If a publisher with this id already exists (either verified or a
    // previously-claimed internal slug with this name, which shouldn't
    // happen because of the no-dot rule but be paranoid) — 409.
    final existing = await _store.lookupPublisher(normalizedDomain);
    if (existing != null) {
      throw ConflictException(
        'A publisher with id "$normalizedDomain" already exists.',
      );
    }

    // Per-user verified quota: don't let a single compromised account
    // flood the publishers list. Applies across *their* verified
    // publishers — admin-created internal ones don't count.
    final currentCount = await _store.countVerifiedPublishersForUser(userId);
    if (currentCount >= _maxVerifiedPerUser) {
      throw InvalidInputException(
        'You\'ve reached the maximum of $_maxVerifiedPerUser verified '
        'publishers. Remove one or contact an admin to raise the limit.',
      );
    }

    final token = _generateToken();
    final tokenHash = _hashToken(token);
    final expiresAt = DateTime.now().toUtc().add(_verificationTtl);

    await _store.upsertVerification(
      PublisherVerificationCompanion(
        id: generateId(),
        userId: userId,
        domain: normalizedDomain,
        tokenHash: tokenHash,
        expiresAt: expiresAt,
      ),
    );

    return (
      token: token,
      expiresAt: expiresAt,
      host: verificationHost(normalizedDomain),
      value: verificationValue(token),
    );
  }

  /// Complete a pending verification. Looks up the pending token, probes
  /// DNS TXT, and on success creates a verified publisher with the user
  /// as its first admin. The pending row is consumed on success.
  Future<Publisher> completeVerification({
    required String userId,
    required String domain,
    required String displayName,
    String? description,
    String? websiteUrl,
    String? contactEmail,
  }) async {
    if (_dns == null) {
      throw const VerificationTemporaryFailure(
        'DNS verification is not configured on this server.',
      );
    }

    final normalizedDomain = domain.trim().toLowerCase();
    final pending = await _store.lookupVerification(userId, normalizedDomain);
    if (pending == null) {
      throw const InvalidInputException(
        'No pending verification — start a new one.',
      );
    }
    if (pending.isExpired) {
      await _store.deleteVerification(pending.id);
      throw const InvalidInputException(
        'Verification expired. Start a new one.',
      );
    }

    // Another user might have completed a verification for the same
    // domain in the meantime — re-check right before we try to create.
    final existing = await _store.lookupPublisher(normalizedDomain);
    if (existing != null) {
      await _store.deleteVerification(pending.id);
      throw ConflictException(
        'A publisher with id "$normalizedDomain" already exists.',
      );
    }

    final host = verificationHost(normalizedDomain);
    final List<String> records;
    try {
      records = await _dns.lookupTxt(host);
    } on VerificationTemporaryFailure {
      rethrow;
    } catch (e) {
      throw VerificationTemporaryFailure('DNS lookup failed: $e');
    }

    // Any TXT record whose value contains the expected `club-verify=<token>`
    // is a match. We don't require an exact equality because operators
    // sometimes wrap values in quotes, add spaces, or concatenate.
    final match = records.any((r) {
      final trimmed = r.trim();
      if (_hashToken(_extractToken(trimmed)) == pending.tokenHash) return true;
      return false;
    });
    if (!match) {
      throw VerificationNotFoundException(host);
    }

    final user = await _store.lookupUserById(userId);
    if (user == null) throw NotFoundException.user(userId);

    final pub = await _store.createPublisher(
      PublisherCompanion(
        id: normalizedDomain,
        displayName: displayName.trim(),
        description: description,
        websiteUrl: websiteUrl,
        contactEmail: contactEmail,
        verified: true,
        createdBy: userId,
      ),
    );

    await _store.addPublisherMember(
      PublisherMemberCompanion(
        publisherId: normalizedDomain,
        userId: userId,
        role: PublisherRole.admin,
      ),
    );

    await _store.deleteVerification(pending.id);

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.publisherVerified,
        agentId: userId,
        publisherId: normalizedDomain,
        summary:
            'Verified publisher "$displayName" ($normalizedDomain) created '
            'via DNS by ${user.email}.',
      ),
    );

    return pub;
  }

  // ── Queries ──────────────────────────────────────────────────

  Future<Publisher> getPublisher(String id) async {
    final pub = await _store.lookupPublisher(id);
    if (pub == null) throw NotFoundException.publisher(id);
    return pub;
  }

  Future<Publisher> updatePublisher(
    String id, {
    String? displayName,
    String? description,
    String? websiteUrl,
    String? contactEmail,
    required String actingUserId,
  }) async {
    await _requirePublisherAdmin(id, actingUserId);

    final existing = await _store.lookupPublisher(id);
    if (existing == null) throw NotFoundException.publisher(id);

    return _store.updatePublisher(
      id,
      PublisherCompanion(
        id: id,
        displayName: displayName ?? existing.displayName,
        description: description ?? existing.description,
        websiteUrl: websiteUrl ?? existing.websiteUrl,
        contactEmail: contactEmail ?? existing.contactEmail,
        verified: existing.verified,
        createdBy: existing.createdBy,
      ),
    );
  }

  Future<List<PublisherMember>> listMembers(String publisherId) async {
    final pub = await _store.lookupPublisher(publisherId);
    if (pub == null) throw NotFoundException.publisher(publisherId);
    return _store.listPublisherMembers(publisherId);
  }

  Future<void> addMember(
    String publisherId,
    String userId, {
    String role = PublisherRole.member,
    required String actingUserId,
  }) async {
    await _requirePublisherAdmin(publisherId, actingUserId);

    final user = await _store.lookupUserById(userId);
    if (user == null) throw NotFoundException.user(userId);

    await _store.addPublisherMember(
      PublisherMemberCompanion(
        publisherId: publisherId,
        userId: userId,
        role: role,
      ),
    );

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.memberAdded,
        agentId: actingUserId,
        publisherId: publisherId,
        summary: 'User ${user.email} added to publisher $publisherId as $role.',
      ),
    );
  }

  Future<void> removeMember(
    String publisherId,
    String userId, {
    required String actingUserId,
  }) async {
    await _requirePublisherAdmin(publisherId, actingUserId);

    // A publisher must always have at least one admin, otherwise nobody
    // can manage it. Block the removal if this would leave the publisher
    // admin-less.
    final members = await _store.listPublisherMembers(publisherId);
    final target = members.firstWhere(
      (m) => m.userId == userId,
      orElse: () => throw const InvalidInputException('User is not a member.'),
    );
    if (target.role == PublisherRole.admin) {
      final adminCount = members
          .where((m) => m.role == PublisherRole.admin)
          .length;
      if (adminCount <= 1) {
        throw const InvalidInputException(
          'Cannot remove the last admin from a publisher. '
          'Promote another member first.',
        );
      }
    }

    await _store.removePublisherMember(publisherId, userId);

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.memberRemoved,
        agentId: actingUserId,
        publisherId: publisherId,
        summary: 'User $userId removed from publisher $publisherId.',
      ),
    );
  }

  Future<List<Publisher>> listAll() => _store.listPublishers();

  // ── Deletion ─────────────────────────────────────────────────

  /// Delete a publisher. Fails with a clear error if it still owns any
  /// packages — callers must transfer or clear those packages first.
  /// The acting user must be a publisher admin OR a server admin.
  Future<void> deletePublisher({
    required String publisherId,
    required String actingUserId,
    required bool actorIsServerAdmin,
  }) async {
    final pub = await _store.lookupPublisher(publisherId);
    if (pub == null) throw NotFoundException.publisher(publisherId);

    if (!actorIsServerAdmin) {
      final isAdmin = await _store.isPublisherAdmin(publisherId, actingUserId);
      if (!isAdmin) {
        throw const ForbiddenException('Publisher admin privileges required.');
      }
    }

    // Refuse while packages are still owned by this publisher. Even one
    // is enough — the caller must transfer or clear them first. We use
    // the paged endpoint with a tiny limit to keep this cheap.
    final page = await _store.listPackagesForPublisher(
      publisherId,
      limit: 1,
    );
    if (page.items.isNotEmpty) {
      throw ConflictException(
        'Publisher "$publisherId" still owns ${page.totalCount} package'
        '${page.totalCount == 1 ? '' : 's'}. Transfer or clear them before '
        'deleting the publisher.',
      );
    }

    await _store.deletePublisher(publisherId);

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.publisherDeleted,
        agentId: actingUserId,
        publisherId: publisherId,
        summary: 'Publisher "${pub.displayName}" ($publisherId) deleted.',
      ),
    );
  }

  // ── Internal helpers ─────────────────────────────────────────

  Future<void> _requirePublisherAdmin(String publisherId, String userId) async {
    final user = await _store.lookupUserById(userId);
    if (user != null && user.isAdmin) return;

    final isAdmin = await _store.isPublisherAdmin(publisherId, userId);
    if (!isAdmin) {
      throw const ForbiddenException('Publisher admin privileges required.');
    }
  }

  // ── Token helpers ────────────────────────────────────────────

  /// 32 bytes of random base64url ≈ 43 chars, plenty for a short-lived
  /// TXT challenge. We hash before storing so a leaked DB row can't
  /// impersonate in-flight verifications.
  String _generateToken() {
    final rng = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  /// Given a TXT value like `club-verify=<tok>` (or quoted variants),
  /// pull out the token portion. Returns empty string if the prefix
  /// doesn't match — callers should compare hashes against the pending
  /// row's hash to confirm.
  String _extractToken(String raw) {
    const prefix = 'club-verify=';
    final idx = raw.indexOf(prefix);
    if (idx < 0) return '';
    return raw.substring(idx + prefix.length).trim();
  }
}
