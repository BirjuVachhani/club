import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';
import '../scoring/scoring_service.dart';

/// API handlers for dartdoc generation status and admin triggers.
class DartdocApi {
  DartdocApi({
    required this.scoringService,
    required this.metadataStore,
    required this.settingsStore,
  });

  final ScoringService scoringService;
  final MetadataStore metadataStore;
  final SettingsStore settingsStore;

  DecodedRouter get router {
    final router = DecodedRouter();

    // Public — frontend polls this to decide whether to show "API Reference".
    router.get('/api/packages/<package>/dartdoc-status', _getStatus);

    // Admin — trigger re-generation (re-enqueues scoring which includes dartdoc).
    router.post(
      '/api/admin/packages/<package>/regenerate-docs',
      _regenerate,
    );

    return router;
  }

  Future<Response> _getStatus(Request request, String package) async {
    final doc = await metadataStore.lookupDartdoc(package);
    if (doc == null) {
      return _json({'status': 'not_generated'});
    }

    return _json({
      'status': doc.status.name,
      'version': doc.version,
      if (doc.generatedAt != null)
        'generatedAt': doc.generatedAt!.toIso8601String(),
      if (doc.status == DartdocStatus.completed)
        'docsUrl': '/documentation/$package/latest/',
      if (doc.status == DartdocStatus.failed)
        'errorMessage':
            'Documentation generation failed. Contact the server administrator.',
    });
  }

  Future<Response> _regenerate(Request request, String package) async {
    requireRole(request, UserRole.admin);

    final pkg = await metadataStore.lookupPackage(package);
    if (pkg == null) throw NotFoundException.package(package);

    final latestVersion = pkg.latestVersion ?? pkg.latestPrerelease;
    if (latestVersion == null) {
      return Response(
        400,
        body: jsonEncode({
          'error': {
            'code': 'no_version',
            'message': 'Package has no versions.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    // Read fresh from settings rather than `scoringService.systemStatus.enabled`,
    // which reflects the cached `_lastConfig` and is null until a worker has
    // actually dispatched a job (e.g. right after a server restart).
    final enabled = await settingsStore.getScoringEnabled();
    if (!enabled) {
      return Response(
        400,
        body: jsonEncode({
          'error': {
            'code': 'scoring_disabled',
            'message':
                'Scoring is not enabled. Dartdoc generation runs as part of '
                'scoring; enable it under Admin → SDK settings.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    await scoringService.enqueue(package, latestVersion);
    return Response.ok(
      jsonEncode({'status': 'queued', 'version': latestVersion}),
      headers: {'content-type': 'application/json'},
    );
  }

  Response _json(Object body) => Response.ok(
    jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );
}
