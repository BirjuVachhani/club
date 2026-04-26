import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';

/// Health check endpoint. No authentication required.
class HealthApi {
  HealthApi({
    required this.metadataStore,
    required this.blobStore,
    required this.searchIndex,
  });

  final MetadataStore metadataStore;
  final BlobStore blobStore;
  final SearchIndex searchIndex;

  DecodedRouter get router {
    final router = DecodedRouter();
    router.get('/api/v1/health', _health);
    return router;
  }

  Future<Response> _health(Request request) async {
    final checks = <String, Map<String, dynamic>>{};
    var allOk = true;

    // Check metadata store
    try {
      final sw = Stopwatch()..start();
      await metadataStore.listPackages(limit: 1);
      sw.stop();
      checks['metadata_store'] = {
        'status': 'ok',
        'latencyMs': sw.elapsedMilliseconds,
      };
    } catch (e) {
      checks['metadata_store'] = {'status': 'error', 'message': e.toString()};
      allOk = false;
    }

    // Check blob store
    try {
      final sw = Stopwatch()..start();
      await blobStore.listPackages();
      sw.stop();
      checks['blob_store'] = {
        'status': 'ok',
        'latencyMs': sw.elapsedMilliseconds,
      };
    } catch (e) {
      checks['blob_store'] = {'status': 'error', 'message': e.toString()};
      allOk = false;
    }

    // Check search index
    try {
      final sw = Stopwatch()..start();
      final ready = await searchIndex.isReady();
      sw.stop();
      checks['search_index'] = {
        'status': ready ? 'ok' : 'initializing',
        'latencyMs': sw.elapsedMilliseconds,
      };
    } catch (e) {
      checks['search_index'] = {'status': 'error', 'message': e.toString()};
      allOk = false;
    }

    return Response(
      allOk ? 200 : 503,
      body: jsonEncode({
        'status': allOk ? 'ok' : 'degraded',
        'checks': checks,
        'version': '0.1.0',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }
}
