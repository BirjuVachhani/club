/// Builds the `WWW-Authenticate` challenge that `dart pub` reads to decide
/// whether to prompt for credentials.
///
/// There are two places a 401 can originate: `authMiddleware`, which denies
/// before the handler runs, and `errorMiddleware`, which renders an
/// [AuthException] a handler threw. Both must emit the header, a 401 without
/// it makes `dart pub` fail opaquely instead of saying "this repository
/// requires authentication". Keeping the construction here means the two
/// cannot drift apart.
library;

/// Format the `www-authenticate` value for a Bearer challenge in the `pub`
/// realm, carrying [message] as the human-readable reason.
///
/// [message] is quoted-string escaped. Today every caller passes a fixed
/// constant from `AuthException`, so nothing can currently inject a `"` or a
/// newline, but this is a *response header built from an exception message*,
/// and the set of exception messages is not a closed system. Escaping here
/// means a future `AuthException('Token for "$host" expired')` cannot split
/// the header.
String bearerChallenge(String message) =>
    'Bearer realm="pub", message="${_escapeQuotedString(message)}"';

/// Escape a value for inclusion in an RFC 7230 quoted-string: backslash and
/// double-quote get backslash-escaped, and CR/LF/NUL are dropped outright
/// rather than escaped (they have no legal quoted-pair form in a header value
/// and are the response-splitting primitive).
String _escapeQuotedString(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    switch (rune) {
      case 0x00: // NUL
      case 0x0A: // LF
      case 0x0D: // CR
        break;
      case 0x22: // "
      case 0x5C: // \
        buffer
          ..writeCharCode(0x5C)
          ..writeCharCode(rune);
      default:
        buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}
