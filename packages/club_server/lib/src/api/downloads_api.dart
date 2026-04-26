import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';

/// Exposes download statistics for packages.
///
/// `GET /api/packages/<package>/downloads`
///   Returns [PackageDownloadHistory] for the last 53 weeks.
///   Public — no auth required (same access level as the package itself).
class DownloadsApi {
  DownloadsApi({
    required this.downloadService,
    required this.metadataStore,
  });

  final DownloadService downloadService;
  final MetadataStore metadataStore;

  DecodedRouter get router {
    final router = DecodedRouter();
    router.get('/api/packages/<package>/downloads', _getDownloads);
    return router;
  }

  Future<Response> _getDownloads(Request request, String package) async {
    final pkg = await metadataStore.lookupPackage(package);
    if (pkg == null) {
      return Response.notFound(
        jsonEncode({
          'error': {
            'code': 'PackageNotFound',
            'message': 'Package $package not found.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    final history = await downloadService.history(package);
    return Response.ok(
      jsonEncode(history.toJson()),
      headers: {'content-type': 'application/json'},
    );
  }
}
