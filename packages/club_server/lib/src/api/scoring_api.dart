import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';
import '../scoring/scoring_service.dart';

/// API handlers for package scoring (pana analysis).
class ScoringApi {
  ScoringApi({
    required this.scoringService,
    required this.metadataStore,
    required this.settingsStore,
  });

  final ScoringService scoringService;
  final MetadataStore metadataStore;
  final SettingsStore settingsStore;

  DecodedRouter get router {
    final router = DecodedRouter();

    // Public — anyone can view the scoring report for a version.
    router.get(
      '/api/packages/<package>/versions/<version>/scoring-report',
      _getScoringReport,
    );

    // Admin — trigger re-analysis.
    router.post(
      '/api/admin/packages/<package>/versions/<version>/rescore',
      _rescore,
    );

    return router;
  }

  Future<Response> _getScoringReport(
    Request request,
    String package,
    String version,
  ) async {
    final scoringEnabled = await settingsStore.getScoringEnabled();
    if (!scoringEnabled) {
      return _json({'status': 'disabled'});
    }

    final score = await metadataStore.lookupScore(package, version);
    if (score == null) {
      return _json({'status': 'not_analyzed'});
    }

    switch (score.status) {
      case ScoreStatus.pending:
        return _json({'status': 'pending'});
      case ScoreStatus.running:
        return _json({'status': 'running'});
      case ScoreStatus.failed:
        return _json({
          'status': 'failed',
          'errorMessage':
              'Analysis failed. Contact the server administrator for details.',
        });
      case ScoreStatus.completed:
        // Parse the stored pana report to extract sections.
        List<Map<String, dynamic>>? sections;
        if (score.reportJson != null) {
          try {
            final report =
                jsonDecode(score.reportJson!) as Map<String, dynamic>;
            final reportObj = report['report'] as Map<String, dynamic>?;
            final rawSections = reportObj?['sections'] as List?;
            sections = rawSections?.map((s) {
              final m = s as Map<String, dynamic>;
              return {
                'id': m['id'],
                'title': m['title'],
                'grantedPoints': m['grantedPoints'],
                'maxPoints': m['maxPoints'],
                'status': m['status'],
                'summary': m['summary'],
              };
            }).toList();
          } catch (_) {
            // If report parsing fails, still return what we have.
          }
        }

        return _json({
          'status': 'completed',
          'grantedPoints': score.grantedPoints,
          'maxPoints': score.maxPoints,
          'sections': sections ?? [],
          'panaVersion': score.panaVersion,
          'dartVersion': score.dartVersion,
          'flutterVersion': score.flutterVersion,
          'analyzedAt': score.scoredAt?.toIso8601String(),
        });
    }
  }

  Future<Response> _rescore(
    Request request,
    String package,
    String version,
  ) async {
    requireRole(request, UserRole.admin);

    // Verify the version exists.
    final pv = await metadataStore.lookupVersion(package, version);
    if (pv == null) throw NotFoundException.version(package, version);

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
            'message': 'Scoring is not enabled on this server.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    await scoringService.enqueue(package, version);
    return Response(
      200,
      body: jsonEncode({'status': 'queued'}),
      headers: {'content-type': 'application/json'},
    );
  }

  Response _json(Object body) => Response.ok(
    jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );
}
