import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'api_token.g.dart';

/// Distinguishes browser sessions from user-managed personal access tokens.
///
/// Sessions are short-lived with sliding expiry; they authenticate the web
/// UI via an HttpOnly cookie. PATs are user-created, long-lived keys used
/// by the CLI and programmatic clients via `Authorization: Bearer`.
enum ApiTokenKind {
  @JsonValue('session')
  session,
  @JsonValue('pat')
  pat
  ;

  String get name => switch (this) {
    ApiTokenKind.session => 'session',
    ApiTokenKind.pat => 'pat',
  };

  static ApiTokenKind fromString(String value) => switch (value) {
    'session' => ApiTokenKind.session,
    'pat' => ApiTokenKind.pat,
    _ => throw ArgumentError('Unknown ApiTokenKind: $value'),
  };
}

@JsonSerializable()
class ApiToken extends Equatable {
  const ApiToken({
    required this.tokenId,
    required this.userId,
    required this.kind,
    required this.name,
    required this.prefix,
    required this.scopes,
    required this.createdAt,
    this.expiresAt,
    this.absoluteExpiresAt,
    this.userAgent,
    this.clientIp,
    this.clientCity,
    this.clientRegion,
    this.clientCountry,
    this.clientCountryCode,
    this.lastUsedAt,
    this.revokedAt,
  });

  factory ApiToken.fromJson(Map<String, dynamic> json) =>
      _$ApiTokenFromJson(json);

  final String tokenId;
  final String userId;
  final ApiTokenKind kind;
  final String name;
  final String prefix;
  final List<String> scopes;
  final DateTime createdAt;

  /// Next-expiry instant. For sessions, this slides on each use; for PATs
  /// it's the user-chosen expiry (or null for never-expires).
  final DateTime? expiresAt;

  /// Hard ceiling for sessions. Even with activity, the session is dead
  /// after this instant. Null for PATs.
  final DateTime? absoluteExpiresAt;

  final String? userAgent;
  final String? clientIp;

  /// Geolocation captured at session creation (via ipwho.is). Frozen at
  /// issue-time — never updated on subsequent use, so the UI shows where
  /// the login happened, not where the session was last seen.
  final String? clientCity;
  final String? clientRegion;
  final String? clientCountry;

  /// ISO 3166-1 alpha-2 country code (e.g. "IN", "US"). Used to render
  /// country flags without shipping flag images.
  final String? clientCountryCode;

  final DateTime? lastUsedAt;
  final DateTime? revokedAt;

  bool get isRevoked => revokedAt != null;
  bool get isExpired {
    final now = DateTime.now().toUtc();
    if (expiresAt != null && now.isAfter(expiresAt!)) return true;
    if (absoluteExpiresAt != null && now.isAfter(absoluteExpiresAt!)) {
      return true;
    }
    return false;
  }

  bool get isActive => !isRevoked && !isExpired;

  bool hasScope(String scope) => scopes.contains(scope);

  Map<String, dynamic> toJson() => _$ApiTokenToJson(this);

  @override
  List<Object?> get props => [
    tokenId,
    userId,
    kind,
    name,
    prefix,
    scopes,
    createdAt,
    expiresAt,
    absoluteExpiresAt,
    userAgent,
    clientIp,
    clientCity,
    clientRegion,
    clientCountry,
    clientCountryCode,
    lastUsedAt,
    revokedAt,
  ];
}

class ApiTokenCompanion {
  const ApiTokenCompanion({
    required this.tokenId,
    required this.userId,
    required this.kind,
    required this.name,
    required this.tokenHash,
    required this.prefix,
    required this.scopes,
    this.expiresAt,
    this.absoluteExpiresAt,
    this.userAgent,
    this.clientIp,
    this.clientCity,
    this.clientRegion,
    this.clientCountry,
    this.clientCountryCode,
  });

  final String tokenId;
  final String userId;
  final ApiTokenKind kind;
  final String name;
  final String tokenHash;
  final String prefix;
  final List<String> scopes;
  final DateTime? expiresAt;
  final DateTime? absoluteExpiresAt;
  final String? userAgent;
  final String? clientIp;
  final String? clientCity;
  final String? clientRegion;
  final String? clientCountry;
  final String? clientCountryCode;
}

/// Scopes that can be assigned to API tokens.
abstract final class TokenScope {
  static const String read = 'read';
  static const String write = 'write';
  static const String admin = 'admin';

  static const List<String> all = [read, write, admin];

  static bool isValid(String scope) => all.contains(scope);
}
