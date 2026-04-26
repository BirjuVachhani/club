/// Base exception for club API client errors.
class ClubApiException implements Exception {
  const ClubApiException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => 'ClubApiException($statusCode $code: $message)';
}

class ClubNotFoundException extends ClubApiException {
  const ClubNotFoundException(String message) : super(404, 'NotFound', message);
}

class ClubAuthException extends ClubApiException {
  const ClubAuthException(String message)
    : super(401, 'MissingAuthentication', message);
}

class ClubForbiddenException extends ClubApiException {
  const ClubForbiddenException(String message)
    : super(403, 'InsufficientPermissions', message);
}

class ClubBadRequestException extends ClubApiException {
  const ClubBadRequestException(String code, String message)
    : super(400, code, message);
}

class ClubConflictException extends ClubApiException {
  const ClubConflictException(String message) : super(409, 'Conflict', message);
}

class ClubServerException extends ClubApiException {
  const ClubServerException(String message)
    : super(500, 'InternalError', message);
}
