/// The four roles a user can hold on a club server.
///
/// Ordered from most to least privileged. Use [isAtLeast] for role-based
/// guards — direct equality checks should be rare and reserved for cases
/// where the specific role matters (e.g. the owner-only guards that
/// prevent an admin from touching the owner).
enum UserRole {
  /// The person who created the server. Full control including operator-
  /// level settings. Exactly one owner exists at a time.
  owner,

  /// Manages packages, users, and dashboard settings, but cannot touch
  /// operator-level settings or the owner.
  admin,

  /// Developer-style write access. Can publish packages and edit
  /// package/version metadata, but cannot delete packages, manage users,
  /// or change server-wide settings.
  ///
  /// Previously called `editor`. The wire format and DB value both use
  /// `member` now; the string `editor` is accepted as an alias during
  /// parsing for compatibility with stale local data or older clients.
  member,

  /// Read-only. Can browse and download packages. Cannot publish or
  /// modify anything.
  viewer
  ;

  /// True when this role is at least as privileged as [other].
  bool isAtLeast(UserRole other) => index <= other.index;

  /// True when this role is strictly more privileged than [other].
  bool isAbove(UserRole other) => index < other.index;

  /// Parse a persisted role string. Accepts the canonical enum names
  /// plus the legacy alias `editor` → [member]. Throws on unknown
  /// values so callers can surface the bad data rather than silently
  /// downgrading.
  static UserRole fromString(String value) {
    if (value == 'editor') return UserRole.member;
    for (final r in UserRole.values) {
      if (r.name == value) return r;
    }
    throw ArgumentError.value(value, 'role', 'Unknown role');
  }

  /// Parse-or-fallback variant for defensive code paths. Returns null on
  /// unknown values so the caller decides the fallback. The legacy alias
  /// `editor` resolves to [member].
  static UserRole? tryFromString(String? value) {
    if (value == null) return null;
    if (value == 'editor') return UserRole.member;
    for (final r in UserRole.values) {
      if (r.name == value) return r;
    }
    return null;
  }
}
