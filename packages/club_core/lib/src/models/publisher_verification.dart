import 'package:equatable/equatable.dart';

/// A pending DNS-based publisher verification. The user has requested a
/// token for a given domain; the raw token is held only by them, while
/// the server stores just its SHA-256 hash so a leaked verifications row
/// can't be used to forge a verification.
class PublisherVerification extends Equatable {
  const PublisherVerification({
    required this.id,
    required this.userId,
    required this.domain,
    required this.tokenHash,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String userId;
  final String domain;
  final String tokenHash;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  @override
  List<Object?> get props => [id];
}

class PublisherVerificationCompanion {
  const PublisherVerificationCompanion({
    required this.id,
    required this.userId,
    required this.domain,
    required this.tokenHash,
    required this.expiresAt,
  });

  final String id;
  final String userId;
  final String domain;
  final String tokenHash;
  final DateTime expiresAt;
}
