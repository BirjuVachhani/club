import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../version.dart';

/// Tiny public endpoint that lets the SPA's footer (visible to anyone,
/// including signed-out visitors) render the running server version
/// without invoking the heavier `/api/v1/health` checks. Kept separate
/// from `/health` so a footer fetch can never light up the orchestrator's
/// liveness probe and so the response can be cached aggressively.
class VersionApi {
  VersionApi();

  DecodedRouter get router {
    final router = DecodedRouter();
    router.get('/api/v1/version', _version);
    return router;
  }

  Future<Response> _version(Request request) async {
    // Static for the lifetime of the process — a new image is a new
    // container — so intermediaries can serve from cache for 5 min.
    return _jsonResponse(
      const {'version': kServerVersion, 'name': 'club'},
    ).change(headers: const {'cache-control': 'public, max-age=300'});
  }

  Response _jsonResponse(Object data) => Response.ok(
    jsonEncode(data),
    headers: {'content-type': 'application/json'},
  );
}
