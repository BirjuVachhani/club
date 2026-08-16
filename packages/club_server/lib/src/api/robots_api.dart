import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';

/// Serves `/robots.txt`.
///
/// A route rather than a static file because the answer depends on
/// server state. A private registry must tell crawlers to stay out
/// entirely; once an operator has enabled public packages the package
/// pages are legitimately indexable, but the API and the generated
/// documentation trees are not.
///
/// Worth being honest about the limits: the SPA is `ssr = false`, so a
/// crawler that does not execute JavaScript sees an empty shell whatever
/// this file says. Real indexing would need server-side rendering or
/// prerendered package pages, which is a separate project. This exists so
/// that a well-behaved crawler is not told to index things it should not,
/// and so that a private deployment is explicitly off-limits.
///
/// It is not an access control. Nothing here keeps anyone out; the auth
/// middleware does that.
class RobotsApi {
  RobotsApi({required this.publicBrowsingEnabled});

  /// Same predicate the SPA uses to decide between a landing page and a
  /// login wall: public packages enabled *and* at least one exists.
  final Future<bool> Function() publicBrowsingEnabled;

  DecodedRouter get router {
    final router = DecodedRouter();
    router.get('/robots.txt', _robots);
    return router;
  }

  Future<Response> _robots(Request request) async {
    final body = await publicBrowsingEnabled()
        ? '''
# This club server hosts public packages.
User-agent: *
Allow: /packages
Disallow: /api/
Disallow: /documentation/
Disallow: /admin/
Disallow: /settings/
Disallow: /login
Disallow: /signup
'''
        : '''
# Private package registry. Nothing here is intended for indexing.
User-agent: *
Disallow: /
''';

    return Response.ok(
      body,
      headers: {
        'content-type': 'text/plain; charset=utf-8',
        // Short TTL: this flips the moment an operator enables public
        // packages, and a crawler holding a day-old "Disallow: /" would
        // keep a newly public registry out of results.
        'cache-control': 'public, max-age=300',
      },
    );
  }
}
