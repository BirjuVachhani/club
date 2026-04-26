import 'dart:convert';
import 'dart:io';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';
import '../scoring/scoring_service.dart';
import '../sdk/sdk_manager.dart';

/// Admin API for managing Flutter SDK installations and scoring settings.
class SdkApi {
  SdkApi({
    required this.sdkManager,
    required this.settingsStore,
    required this.scoringService,
    required this.metadataStore,
  });

  final SdkManager sdkManager;
  final SettingsStore settingsStore;
  final ScoringService scoringService;
  final MetadataStore metadataStore;

  DecodedRouter get router {
    final router = DecodedRouter();

    router.get('/api/admin/sdk/releases', _listReleases);
    router.get('/api/admin/sdk/installs', _listInstalls);
    router.post('/api/admin/sdk/installs', _startInstall);
    router.get('/api/admin/sdk/installs/<id>/progress', _getProgress);
    router.post('/api/admin/sdk/installs/<id>/set-default', _setDefault);
    router.post('/api/admin/sdk/installs/<id>/rebuild', _rebuild);
    router.delete('/api/admin/sdk/installs/<id>', _deleteInstall);
    router.get('/api/admin/sdk/settings', _getSettings);
    router.put('/api/admin/sdk/settings', _updateSettings);
    router.get('/api/admin/sdk/platform', _getPlatform);
    router.get('/api/admin/sdk/scoring-logs', _getScoringLogs);
    router.delete('/api/admin/sdk/scoring-logs', _clearScoringLogs);
    router.post('/api/admin/sdk/score-remaining', _scoreRemaining);
    router.post('/api/admin/sdk/rescan-all', _rescanAll);
    router.post('/api/admin/sdk/cancel-in-flight', _cancelInFlight);
    router.post('/api/admin/sdk/scan', _scan);

    return router;
  }

  /// Scan the SDK base directory for Flutter installs not tracked in the
  /// DB and register them. Rebuilds run async in the background.
  Future<Response> _scan(Request request) async {
    requireRole(request, UserRole.admin);
    final discovered = await sdkManager.discoverOrphanedSdks();
    return _json({
      'discovered': discovered.map(_installToJson).toList(),
    });
  }

  /// List available Flutter releases from the official API.
  Future<Response> _listReleases(Request request) async {
    requireRole(request, UserRole.admin);
    final channel = request.url.queryParameters['channel'];
    final releases = await sdkManager.fetchAvailableVersions(channel: channel);
    return _json({'releases': releases.map((r) => r.toJson()).toList()});
  }

  /// List all installed SDK versions with their status.
  Future<Response> _listInstalls(Request request) async {
    requireRole(request, UserRole.admin);
    final installs = await sdkManager.listInstalled();
    return _json({
      'installs': installs.map(_installToJson).toList(),
    });
  }

  /// Start installing a Flutter SDK version via git clone.
  Future<Response> _startInstall(Request request) async {
    requireRole(request, UserRole.admin);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final version = body['version'] as String?;
    final channel = body['channel'] as String?;

    if (version == null || channel == null) {
      return Response(
        400,
        body: jsonEncode({
          'error': {
            'code': 'invalid_input',
            'message': 'version and channel are required.',
          },
        }),
        headers: _jsonHeaders,
      );
    }

    final install = await sdkManager.startInstall(
      version: version,
      channel: channel,
    );

    return _json(_installToJson(install));
  }

  /// Get install progress for an in-flight install.
  Future<Response> _getProgress(Request request, String id) async {
    requireRole(request, UserRole.admin);
    final progress = sdkManager.getProgress(id);
    if (progress != null) {
      return _json(progress.toJson());
    }
    // Not in-flight — check DB for terminal state.
    final install = await settingsStore.lookupSdkInstall(id);
    if (install == null) {
      return Response.notFound(
        jsonEncode({
          'error': {'code': 'not_found', 'message': 'Install not found.'},
        }),
        headers: _jsonHeaders,
      );
    }
    return _json({
      'installId': id,
      'phase': install.status.name,
      'error': install.errorMessage,
      'logs': <String>[],
    });
  }

  /// Mark an installed SDK as the default for scoring.
  Future<Response> _setDefault(Request request, String id) async {
    requireRole(request, UserRole.admin);
    await sdkManager.setDefault(id);
    return _json({'status': 'ok'});
  }

  /// Rebuild an installed SDK (re-run setup steps without re-cloning).
  Future<Response> _rebuild(Request request, String id) async {
    requireRole(request, UserRole.admin);
    final install = await sdkManager.rebuild(id);
    return _json(_installToJson(install));
  }

  /// Delete an installed SDK.
  Future<Response> _deleteInstall(Request request, String id) async {
    requireRole(request, UserRole.admin);
    await sdkManager.deleteInstall(id);
    return _json({'status': 'ok'});
  }

  /// Get scoring settings and stats.
  Future<Response> _getSettings(Request request) async {
    requireRole(request, UserRole.admin);
    final enabled = await settingsStore.getScoringEnabled();
    final defaultVersion = await settingsStore.getDefaultSdkVersion();
    final diskSpace = await sdkManager.getAvailableDiskSpace();
    final status = scoringService.systemStatus;
    final coverage = await metadataStore.countScoringCoverage();
    return _json({
      'scoringEnabled': enabled,
      'defaultSdkVersion': defaultVersion,
      'platform': sdkManager.platform,
      'availableDiskSpace': diskSpace,
      'workers': {
        'total': status.workerCount,
        'active': status.activeJobs,
        'queued': status.queueDepth,
        'inFlightJobs': [
          for (final job in status.inFlightJobs) job.toJson(),
        ],
      },
      'coverage': {
        'totalPackages': coverage.total,
        'scoredPackages': coverage.scored,
      },
      'discovery': {
        'error': sdkManager.lastDiscoveryError,
        'at': sdkManager.lastDiscoveryAt?.toIso8601String(),
      },
    });
  }

  /// Update scoring settings.
  Future<Response> _updateSettings(Request request) async {
    requireRole(request, UserRole.admin);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;

    if (body.containsKey('scoringEnabled')) {
      await settingsStore.setScoringEnabled(body['scoringEnabled'] as bool);
    }

    return _json({'status': 'ok'});
  }

  /// Enqueue all unscored package versions for scoring.
  // Reads the toggle from settingsStore rather than
  // `scoringService.systemStatus.enabled`. The latter reflects the service's
  // cached `_lastConfig`, which is only populated once workers spawn — so
  // enabling scoring via the toggle and clicking "Process Remaining" before
  // any job has ever been dispatched would otherwise 400 spuriously.
  Future<Response> _scoreRemaining(Request request) async {
    requireRole(request, UserRole.admin);
    final enabled = await settingsStore.getScoringEnabled();
    if (!enabled) {
      return Response(
        400,
        body: jsonEncode({
          'error': {
            'code': 'scoring_disabled',
            'message': 'Scoring is not enabled.',
          },
        }),
        headers: _jsonHeaders,
      );
    }
    final count = await scoringService.enqueueUnscored();
    return _json({'queued': count});
  }

  /// Enqueue every package version for a full rescan, replacing existing
  /// scores. Body accepts `{ "scope": "latest" | "all" }`; defaults to
  /// "latest" if omitted.
  Future<Response> _rescanAll(Request request) async {
    requireRole(request, UserRole.admin);
    final enabled = await settingsStore.getScoringEnabled();
    if (!enabled) {
      return Response(
        400,
        body: jsonEncode({
          'error': {
            'code': 'scoring_disabled',
            'message': 'Scoring is not enabled.',
          },
        }),
        headers: _jsonHeaders,
      );
    }

    final raw = await request.readAsString();
    final body = raw.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    final scope = body['scope'] as String? ?? 'latest';
    if (scope != 'latest' && scope != 'all') {
      return Response(
        400,
        body: jsonEncode({
          'error': {
            'code': 'invalid_input',
            'message': 'scope must be "latest" or "all".',
          },
        }),
        headers: _jsonHeaders,
      );
    }

    final count = await scoringService.enqueueAll(
      latestOnly: scope == 'latest',
    );
    return _json({'queued': count});
  }

  /// Operator-triggered cancellation of in-flight scoring subprocess(es).
  /// Body is optional; pass `{packageName, version}` to target a single job,
  /// or omit the body / send `{}` to cancel every in-flight job. The
  /// existing wait-and-persist flow records the kill as a failure and the
  /// dispatcher moves on.
  Future<Response> _cancelInFlight(Request request) async {
    requireRole(request, UserRole.admin);
    final raw = await request.readAsString();
    final body = raw.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    final packageName = body['packageName'] as String?;
    final version = body['version'] as String?;
    final cancelled = await scoringService.cancelInFlight(
      packageName: packageName,
      version: version,
    );
    return _json({'cancelled': cancelled});
  }

  /// Get the last N lines from the scoring log file.
  Future<Response> _getScoringLogs(Request request) async {
    requireRole(request, UserRole.admin);
    final lines = await scoringService.readLogLines();
    return _json({'lines': lines});
  }

  /// Clear the scoring log file.
  Future<Response> _clearScoringLogs(Request request) async {
    requireRole(request, UserRole.admin);
    await scoringService.clearLogs();
    return _json({'ok': true});
  }

  /// Get platform info (arch, OS).
  Future<Response> _getPlatform(Request request) async {
    requireRole(request, UserRole.admin);
    final diskSpace = await sdkManager.getAvailableDiskSpace();
    return _json({
      'platform': sdkManager.platform,
      'os': Platform.operatingSystem,
      'availableDiskSpace': diskSpace,
    });
  }

  Map<String, dynamic> _installToJson(SdkInstall install) => {
    'id': install.id,
    'channel': install.channel,
    'version': install.version,
    'dartVersion': install.dartVersion,
    'installPath': install.installPath,
    'sizeBytes': install.sizeBytes,
    'status': install.status.name,
    'errorMessage': install.errorMessage,
    'isDefault': install.isDefault,
    'installedAt': install.installedAt?.toIso8601String(),
    'createdAt': install.createdAt.toIso8601String(),
  };

  static const _jsonHeaders = {'content-type': 'application/json'};

  Response _json(Object body) => Response.ok(
    jsonEncode(body),
    headers: _jsonHeaders,
  );
}
