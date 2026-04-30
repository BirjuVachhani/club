import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

/// Drop-in replacement for [Router] that percent-decodes every [String]
/// path parameter before invoking the handler.
///
/// `shelf_router` matches routes against the raw `request.url.path` and
/// stores the raw (still URL-encoded) captures in the handler arguments.
/// That means `<version>` in a route receives `"1.0.0%2B1"`, not
/// `"1.0.0+1"` — which silently breaks every handler that does an exact
/// DB lookup on the value. Our own bug report for this: version strings
/// with `+` build metadata caused 404s on `/rescore` and `{status:
/// not_analyzed}` on `/scoring-report`.
///
/// Use this in place of [Router] everywhere. All routing methods proxy
/// to an inner [Router]; the only thing we change is wrapping the
/// handler so each string positional argument (after [Request]) passes
/// through [Uri.decodeComponent]. Malformed percent-encoding is left
/// untouched so the handler can return a clean 404 instead of a 500.
///
/// Because `Router` is sealed we can't subclass it; this class composes
/// one and exposes [call] so it can be used directly as a shelf [Handler]
/// (e.g. `Cascade().add(myApi.router.call)`).
class DecodedRouter {
  DecodedRouter();

  final Router _inner = Router();

  /// Dispatches [request] through the inner router. Exposing `call` lets
  /// a [DecodedRouter] instance be used anywhere a shelf [Handler] is
  /// expected (e.g. `Cascade().add(router.call)`).
  FutureOr<Response> call(Request request) => _inner.call(request);

  void add(String verb, String route, Function handler) =>
      _inner.add(verb, route, _wrap(handler));

  void get(String route, Function handler) => add('GET', route, handler);
  void head(String route, Function handler) => add('HEAD', route, handler);
  void post(String route, Function handler) => add('POST', route, handler);
  void put(String route, Function handler) => add('PUT', route, handler);
  void delete(String route, Function handler) => add('DELETE', route, handler);
  void connect(String route, Function handler) =>
      add('CONNECT', route, handler);
  void options(String route, Function handler) =>
      add('OPTIONS', route, handler);
  void trace(String route, Function handler) => add('TRACE', route, handler);
  void patch(String route, Function handler) => add('PATCH', route, handler);

  void all(String route, Function handler) => _inner.all(route, _wrap(handler));

  /// Mounts are passed through unchanged — [Handler] takes no extracted
  /// path parameters, so there is nothing to decode.
  void mount(String prefix, Handler handler) => _inner.mount(prefix, handler);

  static Function _wrap(Function handler) {
    return (
      Request request, [
      Object? a,
      Object? b,
      Object? c,
      Object? d,
      Object? e,
      Object? f,
    ]) {
      final args = <Object?>[request];
      for (final p in [a, b, c, d, e, f]) {
        if (p == null) break;
        args.add(_maybeDecode(p));
      }
      return Function.apply(handler, args);
    };
  }

  static Object _maybeDecode(Object v) {
    if (v is! String) return v;
    try {
      return Uri.decodeComponent(v);
    } on FormatException {
      return v;
    }
  }
}
