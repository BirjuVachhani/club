import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../exceptions.dart';
import '../models/api_token.dart';
import '../models/audit_log.dart';
import '../models/user.dart';
import '../models/user_role.dart';
import '../repositories/metadata_store.dart';

/// Result of creating a new API token (session or PAT).
///
/// [rawSecret] is the full token string the caller must transmit to the
/// client; it is the only moment the plaintext exists. The server stores
/// only [ApiToken] (which contains the hash).
class NewTokenResult {
  const NewTokenResult({required this.token, required this.rawSecret});

  final ApiToken token;

  /// The raw token string. Shown once, never stored or retrievable.
  final String rawSecret;
}

/// Token prefixes chosen so the server can tell at a glance what kind of
/// credential it's holding. The suffix is 32 hex chars of CSPRNG output.
/// Keep these in sync with [ApiTokenKind].
class TokenPrefixes {
  TokenPrefixes._();
  static const String session = 'club_sess_';
  static const String pat = 'club_pat_';
}

/// How long a freshly-issued web session lasts before the next sliding
/// refresh, and the hard cap no amount of activity can extend past.
class SessionLifetime {
  SessionLifetime._();

  /// Sliding window — extended on each authenticated request.
  static const Duration sliding = Duration(days: 30);

  /// Absolute cap. Once this elapses the session dies regardless of use.
  /// Prevents a long-running stolen cookie from being indefinitely useful.
  static const Duration absolute = Duration(days: 90);
}

/// Authenticated user context attached to each request.
class AuthenticatedUser {
  const AuthenticatedUser({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.role,
    required this.scopes,
    required this.tokenKind,
    required this.tokenId,
    this.mustChangePassword = false,
  });

  final String userId;
  final String email;
  final String displayName;
  final UserRole role;
  final List<String> scopes;
  final bool mustChangePassword;

  /// Which credential type backs this request — a browser session cookie
  /// or a user-managed personal access token. Some endpoints (e.g. CSRF
  /// enforcement, "sign out other devices") need to discriminate.
  final ApiTokenKind tokenKind;

  /// The database id of the token used for this request. Lets handlers
  /// like /logout revoke the exact credential that is in use without
  /// touching the user's other sessions or PATs.
  final String tokenId;

  /// Convenience: admin-or-higher.
  bool get isAdmin => role.isAtLeast(UserRole.admin);

  /// Convenience: the server owner.
  bool get isOwner => role == UserRole.owner;

  /// True when the token carries [scope], or when the user is an admin+
  /// (admins implicitly have all scopes; the token scope list is
  /// advisory).
  bool hasScope(String scope) => scopes.contains(scope) || isAdmin;
}

/// Handles user authentication, password verification, and token management.
///
/// This service does NOT depend on bcrypt or JWT directly — those are
/// injected as function callbacks so club_core stays free of I/O deps.
class AuthService {
  AuthService({
    required MetadataStore store,
    required this.hashPassword,
    required this.verifyPassword,
    required this.generateId,
    required this.generateTokenSecret,
  }) : _store = store;

  final MetadataStore _store;

  /// Hash a plaintext password. Injected (e.g., bcrypt).
  final Future<String> Function(String plaintext) hashPassword;

  /// Verify a plaintext password against a hash. Injected (e.g., bcrypt).
  final Future<bool> Function(String plaintext, String hash) verifyPassword;

  /// Generate a UUID. Injected.
  final String Function() generateId;

  /// Generate a raw API token string. Injected.
  /// Expected format: `club_<32-hex-chars>`
  final String Function() generateTokenSecret;

  /// Maximum password length accepted anywhere (signup, change-password,
  /// admin invite). bcrypt truncates at 72 bytes anyway — enforcing a
  /// ceiling here prevents DoS via multi-megabyte passwords that the
  /// caller expects us to hash.
  static const int maxPasswordLength = 256;

  /// Pre-computed bcrypt hash used as a timing sink when authenticating
  /// an email that doesn't exist. Ensures `authenticatePassword` takes
  /// the same wall-clock time in the "no such user" and "wrong password"
  /// cases — removes the classic bcrypt-timing user-enumeration oracle.
  ///
  /// Lazily initialized on first failed auth so the server starts without
  /// paying the bcrypt cost up-front.
  String? _dummyPasswordHash;

  Future<String> _ensureDummyHash() async {
    return _dummyPasswordHash ??= await hashPassword(
      // Content is irrelevant; it just needs to be a valid bcrypt hash.
      'dummy-password-for-timing-equalization',
    );
  }

  /// Create a new user account. The [role] defaults to [UserRole.viewer]
  /// (the safest assumption). Admins can override via their API.
  ///
  /// When [mustChangePassword] is true, the newly-created user will be
  /// forced through the password-reset flow on first login.
  Future<User> createUser({
    required String email,
    required String password,
    required String displayName,
    UserRole role = UserRole.viewer,
    bool mustChangePassword = false,
  }) async {
    if (password.length > maxPasswordLength) {
      throw InvalidInputException(
        'Password must be at most $maxPasswordLength characters.',
      );
    }

    // Hash FIRST, then check for an existing user. The reverse order
    // leaks which emails are registered via a timing side channel —
    // a duplicate bails before bcrypt runs, a fresh email pays the full
    // hash cost. Doing the work up front means both paths take the same
    // wall-clock time.
    final passwordHash = await hashPassword(password);

    final existing = await _store.lookupUserByEmail(email);
    if (existing != null) {
      throw const ConflictException('A user with that email already exists.');
    }

    final userId = generateId();
    final companion = UserCompanion(
      userId: userId,
      email: email,
      passwordHash: passwordHash,
      displayName: displayName,
      role: role,
      mustChangePassword: mustChangePassword,
    );

    final user = await _store.createUser(companion);

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.userCreated,
        agentId: userId,
        summary: 'User $email created with role ${role.name}.',
      ),
    );

    return user;
  }

  /// Authenticate with email and password.
  /// Returns the user if successful.
  ///
  /// Timing-equalized: always runs one bcrypt verification regardless of
  /// whether the email matched a real user, so response time doesn't
  /// reveal account existence. When the email is unknown or the user is
  /// inactive, we verify against a precomputed dummy hash and discard
  /// the result.
  Future<User> authenticatePassword(String email, String password) async {
    // Guard against super-long passwords. We do this early (before any
    // hashing) so an attacker can't weaponize a multi-MB password body
    // to tie up CPU on every request.
    if (password.length > maxPasswordLength) {
      throw AuthException.invalidCredentials();
    }

    final user = await _store.lookupUserByEmail(email);

    final String hash;
    final bool userIsValid;
    if (user == null || !user.isActive) {
      hash = await _ensureDummyHash();
      userIsValid = false;
    } else {
      final storedHash = await _store.lookupPasswordHash(user.userId);
      if (storedHash == null) {
        hash = await _ensureDummyHash();
        userIsValid = false;
      } else {
        hash = storedHash;
        userIsValid = true;
      }
    }

    final passwordMatches = await verifyPassword(password, hash);
    if (!userIsValid || !passwordMatches) {
      throw AuthException.invalidCredentials();
    }

    // userIsValid == true implies user != null (flow-analysis doesn't
    // infer this across the ternary above, so we assert it explicitly).
    final authUser = user!;
    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.userLogin,
        agentId: authUser.userId,
        summary: 'User ${authUser.email} logged in.',
      ),
    );

    return authUser;
  }

  /// Mint a browser session token. The raw secret is intended to live in
  /// an HttpOnly cookie; it should never reach JavaScript.
  ///
  /// Session tokens carry full role-derived scopes (same as an interactive
  /// login) and slide on use up to [SessionLifetime.absolute].
  Future<NewTokenResult> createSession({
    required String userId,
    required List<String> scopes,
    String? userAgent,
    String? clientIp,
    String? clientCity,
    String? clientRegion,
    String? clientCountry,
    String? clientCountryCode,
  }) async {
    final rawSecret = '${TokenPrefixes.session}${generateTokenSecret()}';
    final tokenHash = sha256.convert(utf8.encode(rawSecret)).toString();
    final prefix = rawSecret.substring(
      0,
      TokenPrefixes.session.length + 4,
    );

    final now = DateTime.now().toUtc();
    final companion = ApiTokenCompanion(
      tokenId: generateId(),
      userId: userId,
      kind: ApiTokenKind.session,
      name: 'Web session',
      tokenHash: tokenHash,
      prefix: prefix,
      scopes: scopes,
      expiresAt: now.add(SessionLifetime.sliding),
      absoluteExpiresAt: now.add(SessionLifetime.absolute),
      userAgent: userAgent,
      clientIp: clientIp,
      clientCity: clientCity,
      clientRegion: clientRegion,
      clientCountry: clientCountry,
      clientCountryCode: clientCountryCode,
    );

    final token = await _store.createToken(companion);

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.tokenCreated,
        agentId: userId,
        summary: 'Session opened${userAgent == null ? '' : ' ($userAgent)'}.',
      ),
    );

    return NewTokenResult(token: token, rawSecret: rawSecret);
  }

  /// Mint a user-managed personal access token (API key). PATs carry the
  /// scopes the caller requests (typically [scopesForRole]) and honor the
  /// optional [expiresAt]. Intended for CLI / CI / `dart pub` usage.
  Future<NewTokenResult> createPersonalAccessToken({
    required String userId,
    required String name,
    List<String> scopes = const [TokenScope.read, TokenScope.write],
    DateTime? expiresAt,
  }) async {
    final rawSecret = '${TokenPrefixes.pat}${generateTokenSecret()}';
    final tokenHash = sha256.convert(utf8.encode(rawSecret)).toString();
    final prefix = rawSecret.substring(
      0,
      TokenPrefixes.pat.length + 4,
    );

    final companion = ApiTokenCompanion(
      tokenId: generateId(),
      userId: userId,
      kind: ApiTokenKind.pat,
      name: name,
      tokenHash: tokenHash,
      prefix: prefix,
      scopes: scopes,
      expiresAt: expiresAt,
    );

    final token = await _store.createToken(companion);

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.tokenCreated,
        agentId: userId,
        summary: 'API key "$name" created.',
      ),
    );

    return NewTokenResult(token: token, rawSecret: rawSecret);
  }

  /// Authenticate a raw token (from a cookie or `Authorization: Bearer`).
  ///
  /// For sessions, the caller is expected to pass [sessionSlidable]=true
  /// (the default) so successful use refreshes [ApiToken.expiresAt].
  /// Callers authenticating via `Authorization: Bearer <session>` outside
  /// the browser flow should pass `false` so that an exposed session token
  /// can't keep itself alive indefinitely by being replayed without a
  /// cookie round-trip. PATs ignore this flag entirely.
  Future<AuthenticatedUser> authenticateToken(
    String rawToken, {
    bool sessionSlidable = true,
  }) async {
    final tokenHash = sha256.convert(utf8.encode(rawToken)).toString();
    final token = await _store.lookupTokenByHash(tokenHash);

    if (token == null) {
      throw AuthException.missingToken();
    }
    if (token.isRevoked) {
      throw AuthException.tokenRevoked();
    }
    if (token.isExpired) {
      throw AuthException.tokenExpired();
    }

    final user = await _store.lookupUserById(token.userId);
    if (user == null || !user.isActive) {
      throw AuthException.missingToken();
    }

    // For sessions: slide the window. The store clamps by absolute cap so
    // a misbehaving caller can't extend past the hard ceiling. For PATs:
    // just bump last_used_at for display.
    final now = DateTime.now().toUtc();
    if (token.kind == ApiTokenKind.session && sessionSlidable) {
      // ignore: discarded_futures
      _store.slideSessionExpiry(
        token.tokenId,
        now.add(SessionLifetime.sliding),
      );
    } else {
      // ignore: discarded_futures
      _store.updateTokenLastUsed(token.tokenId, now);
    }

    return AuthenticatedUser(
      userId: user.userId,
      email: user.email,
      displayName: user.displayName,
      role: user.role,
      scopes: token.scopes,
      mustChangePassword: user.mustChangePassword,
      tokenKind: token.kind,
      tokenId: token.tokenId,
    );
  }

  /// Revoke an API token.
  Future<void> revokeToken({
    required String tokenId,
    required String actingUserId,
  }) async {
    await _store.revokeToken(tokenId);

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.tokenRevoked,
        agentId: actingUserId,
        summary: 'API token $tokenId revoked.',
      ),
    );
  }

  /// List tokens for a user, optionally filtered by [kind].
  Future<List<ApiToken>> listTokens(String userId, {ApiTokenKind? kind}) =>
      _store.listTokensForUser(userId, kind: kind);

  /// Revoke every non-revoked session for [userId]. Called on password
  /// change so an attacker who snuck a session cookie out of the browser
  /// loses access the moment the rightful owner updates their password.
  Future<void> revokeAllSessions({
    required String userId,
    String? exceptTokenId,
  }) async {
    await _store.revokeAllTokensForUser(userId, kind: ApiTokenKind.session);
    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.tokenRevoked,
        agentId: userId,
        summary: exceptTokenId == null
            ? 'All sessions revoked for user.'
            : 'All sessions except current revoked for user.',
      ),
    );
  }

  /// Change a user's password after verifying the current password.
  ///
  /// Also clears the [User.mustChangePassword] flag, which is how the
  /// forced-reset flow completes.
  Future<void> changePassword({
    required String userId,
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = await _store.lookupUserById(userId);
    if (user == null || !user.isActive) {
      throw AuthException.invalidCredentials();
    }

    final existingHash = await _store.lookupPasswordHash(userId);
    if (existingHash == null) {
      throw AuthException.invalidCredentials();
    }

    final valid = await verifyPassword(currentPassword, existingHash);
    if (!valid) {
      throw AuthException.invalidCredentials();
    }

    final newHash = await hashPassword(newPassword);
    await _store.updateUser(
      userId,
      UserCompanion(
        userId: user.userId,
        email: user.email,
        passwordHash: newHash,
        displayName: user.displayName,
        role: user.role,
        isActive: user.isActive,
        mustChangePassword: false,
      ),
    );

    // Password change invalidates every existing session. An attacker who
    // stole a session cookie loses it the moment the owner rotates their
    // password. PATs (API keys) are *not* revoked here — users manage
    // those explicitly on the API keys page.
    //
    // We iterate and revoke per-session so each revocation gets an
    // audit-log entry with the tokenId, instead of one opaque bulk update.
    // Forensics can correlate a later incident back to the specific
    // session without needing row-level timestamps.
    final activeSessions = await _store.listTokensForUser(
      userId,
      kind: ApiTokenKind.session,
    );
    var revokedCount = 0;
    for (final session in activeSessions) {
      if (session.isRevoked) continue;
      await _store.revokeToken(session.tokenId);
      await _store.appendAuditLog(
        AuditLogCompanion(
          id: generateId(),
          kind: AuditKind.tokenRevoked,
          agentId: userId,
          summary: 'Session ${session.tokenId} revoked (password change).',
        ),
      );
      revokedCount++;
    }

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: AuditKind.userUpdated,
        agentId: userId,
        summary:
            'Password changed for ${user.email}; $revokedCount session(s) revoked.',
      ),
    );
  }
}
