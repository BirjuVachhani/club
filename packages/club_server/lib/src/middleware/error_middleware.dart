import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

/// Middleware that catches [ClubException] subclasses and renders them
/// as pub spec v2 error JSON responses.
Middleware errorMiddleware() {
  return (Handler innerHandler) {
    return (Request request) async {
      try {
        return await innerHandler(request);
      } on ClubException catch (e, stack) {
        final statusCode = switch (e) {
          NotFoundException() => 404,
          AuthException() => 401,
          ForbiddenException() => 403,
          InvalidInputException() => 400,
          PackageRejectedException() => 400,
          ConflictException() => 409,
          RateLimitException() => 429,
          VerificationTemporaryFailure() => 503,
        };

        // Always print caught errors with their stack trace so operators
        // can trace user-facing errors back to their source. Expected
        // domain exceptions included — silent swallowing makes field
        // debugging impossible.
        // ignore: avoid_print
        print(
          '[${request.method} ${request.requestedUri.path}] '
          '$statusCode ${e.code}: ${e.message}\n$stack',
        );

        return Response(
          statusCode,
          body: jsonEncode({
            'error': {'code': e.code, 'message': e.message},
          }),
          headers: {'content-type': 'application/json'},
        );
      } catch (e, stack) {
        // ignore: avoid_print
        print(
          '[${request.method} ${request.requestedUri.path}] '
          'Unhandled error: $e\n$stack',
        );

        return Response.internalServerError(
          body: jsonEncode({
            'error': {
              'code': 'InternalError',
              'message': 'An unexpected error occurred.',
            },
          }),
          headers: {'content-type': 'application/json'},
        );
      }
    };
  };
}
