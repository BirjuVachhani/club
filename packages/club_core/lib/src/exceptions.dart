/// Exception hierarchy for club.
///
/// All exceptions extend [ClubException] and map to specific HTTP status codes.
/// The server's error middleware catches these and renders the pub spec v2
/// error format: `{"error": {"code": "...", "message": "..."}}`.
sealed class ClubException implements Exception {
  const ClubException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// 404 — Resource not found.
class NotFoundException extends ClubException {
  const NotFoundException(String message) : super('NotFound', message);

  factory NotFoundException.package(String name) =>
      NotFoundException('Package \'$name\' was not found.');

  factory NotFoundException.version(String name, String version) =>
      NotFoundException(
        'Version \'$version\' of package \'$name\' was not found.',
      );

  factory NotFoundException.user(String id) =>
      NotFoundException('User \'$id\' was not found.');

  factory NotFoundException.publisher(String id) =>
      NotFoundException('Publisher \'$id\' was not found.');

  factory NotFoundException.token(String id) =>
      NotFoundException('Token \'$id\' was not found.');
}

/// 401 — Authentication required or failed.
class AuthException extends ClubException {
  const AuthException(String message) : super('MissingAuthentication', message);

  factory AuthException.invalidCredentials() =>
      const AuthException('Invalid email or password.');

  factory AuthException.tokenExpired() =>
      const AuthException('Token has expired.');

  factory AuthException.tokenRevoked() =>
      const AuthException('Token has been revoked.');

  factory AuthException.missingToken() =>
      const AuthException('Authentication required.');
}

/// 403 — Insufficient permissions.
class ForbiddenException extends ClubException {
  const ForbiddenException(String message)
    : super('InsufficientPermissions', message);

  factory ForbiddenException.notUploader(String package) =>
      ForbiddenException('You are not an uploader for package \'$package\'.');

  factory ForbiddenException.notAdmin() =>
      const ForbiddenException('Admin privileges required.');

  factory ForbiddenException.insufficientScope(String required) =>
      ForbiddenException('Token requires \'$required\' scope.');
}

/// 400 — Invalid input or malformed request.
class InvalidInputException extends ClubException {
  const InvalidInputException(String message) : super('InvalidInput', message);
}

/// 404 — DNS verification record was not found or did not match.
class VerificationNotFoundException extends NotFoundException {
  VerificationNotFoundException(this.host)
    : super(
        'Verification TXT record at "$host" was not found or did not '
        'contain the expected value. Add or update the record and try '
        'again after DNS propagation.',
      );

  final String host;
}

/// 503 — DNS verification could not be completed due to a transient failure.
class VerificationTemporaryFailure extends ClubException {
  const VerificationTemporaryFailure(String message)
    : super('VerificationTemporarilyUnavailable', message);
}

/// 400 — Package upload validation failed.
class PackageRejectedException extends ClubException {
  const PackageRejectedException(String message)
    : super('PackageRejected', message);

  factory PackageRejectedException.versionExists(String name, String version) =>
      PackageRejectedException(
        'Version \'$version\' of package \'$name\' already exists.',
      );

  factory PackageRejectedException.invalidName(String name) =>
      PackageRejectedException(
        '\'$name\' is not a valid package name. '
        'Package names must be lowercase, start with a letter, '
        'and contain only letters, numbers, and underscores.',
      );

  factory PackageRejectedException.invalidVersion(String version) =>
      PackageRejectedException('\'$version\' is not a valid semantic version.');

  factory PackageRejectedException.invalidArchive(String reason) =>
      PackageRejectedException('Invalid package archive: $reason');

  factory PackageRejectedException.tooLarge(int maxBytes) =>
      PackageRejectedException(
        'Package archive exceeds maximum size of '
        '${(maxBytes / 1024 / 1024).toStringAsFixed(0)} MB.',
      );
}

/// 409 — Resource conflict.
class ConflictException extends ClubException {
  const ConflictException(String message) : super('Conflict', message);
}

/// 429 — Rate limit exceeded.
class RateLimitException extends ClubException {
  const RateLimitException(String message)
    : super('RateLimitExceeded', message);
}
