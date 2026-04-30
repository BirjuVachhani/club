import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

/// Middleware that blocks ALL API routes (except setup and health) when
/// initial setup has not been completed (no users in database).
///
/// This is a security measure — no auth, publish, search, or admin
/// endpoints should be accessible before the admin account exists.
Middleware setupGuardMiddleware(MetadataStore metadataStore) {
  bool? setupComplete;

  return (Handler innerHandler) {
    return (Request request) async {
      final path = '/${request.url.path}';

      // Non-API routes (static files) always pass through
      if (!path.startsWith('/api/')) {
        return innerHandler(request);
      }

      // These API paths are always allowed
      if (path.startsWith('/api/setup/') || path.startsWith('/api/v1/health')) {
        return innerHandler(request);
      }

      // Check if setup is complete (cache after first true)
      if (setupComplete != true) {
        final users = await metadataStore.listUsers(limit: 1);
        setupComplete = users.items.isNotEmpty;
      }

      if (!setupComplete!) {
        return Response(
          503,
          body: jsonEncode({
            'error': {
              'code': 'SetupRequired',
              'message':
                  'Initial setup has not been completed. '
                  'Open /setup in the browser to create the admin account.',
            },
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      return innerHandler(request);
    };
  };
}
