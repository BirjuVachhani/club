import 'package:equatable/equatable.dart';

/// One-time invite issued by an admin when creating a user via the
/// "send invite link" flow. The raw token is shown to the admin exactly
/// once; only a SHA-256 hash is persisted.
class UserInvite extends Equatable {
  const UserInvite({
    required this.inviteId,
    required this.userId,
    required this.tokenHash,
    required this.expiresAt,
    this.usedAt,
    this.createdBy,
    required this.createdAt,
  });

  final String inviteId;
  final String userId;
  final String tokenHash;
  final DateTime expiresAt;
  final DateTime? usedAt;
  final String? createdBy;
  final DateTime createdAt;

  bool get isUsed => usedAt != null;
  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);
  bool get isValid => !isUsed && !isExpired;

  @override
  List<Object?> get props => [
    inviteId,
    userId,
    tokenHash,
    expiresAt,
    usedAt,
    createdBy,
    createdAt,
  ];
}

/// Write-path struct for creating a new invite.
class UserInviteCompanion {
  const UserInviteCompanion({
    required this.inviteId,
    required this.userId,
    required this.tokenHash,
    required this.expiresAt,
    this.createdBy,
  });

  final String inviteId;
  final String userId;
  final String tokenHash;
  final DateTime expiresAt;
  final String? createdBy;
}
