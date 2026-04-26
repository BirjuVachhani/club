import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';

/// Favorites / likes API handlers.
class LikesApi {
  LikesApi({required this.likesService});

  final LikesService likesService;

  DecodedRouter get router {
    final router = DecodedRouter();
    router.put('/api/account/likes/<package>', _like);
    router.delete('/api/account/likes/<package>', _unlike);
    router.get('/api/account/likes', _listLikes);
    return router;
  }

  Future<Response> _like(Request request, String package) async {
    final user = requireAuthUser(request);
    await likesService.like(user.userId, package);
    return Response.ok(
      jsonEncode({'package': package, 'liked': true}),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _unlike(Request request, String package) async {
    final user = requireAuthUser(request);
    await likesService.unlike(user.userId, package);
    return Response.ok(
      jsonEncode({'package': package, 'liked': false}),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _listLikes(Request request) async {
    final user = requireAuthUser(request);
    final packages = await likesService.getLikedPackages(user.userId);
    return Response.ok(
      jsonEncode({
        'likedPackages': packages
            .map((p) => {'package': p, 'liked': true})
            .toList(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }
}
