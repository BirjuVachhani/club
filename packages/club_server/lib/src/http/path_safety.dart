/// Detects path segments that use percent-encoding to smuggle a separator
/// or a dot segment past URI normalization.
///
/// ## Why this is needed
///
/// `Uri.parse` normalizes percent-encoded *unreserved* characters and then
/// removes dot segments, so `/a/b/../c` and `/a/b/%2e%2e/c` both collapse
/// to `/a/c` before any handler sees them. That makes the obvious
/// traversal attempts harmless.
///
/// It does **not** decode `%2f` (encoded `/`) or `%5c` (encoded `\`),
/// because decoding those would change the path's structure. So
/// `/a/b/..%2f..%2fc` survives normalization intact: it is a single
/// segment as far as `Uri` is concerned, and only becomes a traversal
/// later, if something downstream decodes it while resolving a file.
///
/// That is exactly the shape that let an anonymous request read another
/// package's generated dartdoc: the visibility gate saw one opaque
/// segment and read the *first* path segment as the package name, while
/// `shelf_static` decoded the segment and walked out of that package's
/// directory.
///
/// Any route with a free-form path remainder must run [hasEncodedTraversal]
/// on the raw path before trusting that the earlier segments describe what
/// will actually be served.
library;

/// True when [rawPath] contains a segment that decodes to a path separator
/// or to a dot segment.
///
/// [rawPath] must be the **raw** path (`request.url.path`), not a decoded
/// one: the whole point is to catch encoding that survives normalization.
///
/// Fails closed on malformed percent-encoding. A segment that cannot be
/// decoded is treated as hostile rather than passed through, because what
/// a downstream decoder makes of it is unpredictable.
bool hasEncodedTraversal(String rawPath) {
  for (final segment in rawPath.split('/')) {
    if (segment.isEmpty) continue;

    // A segment containing no escape can only be what it looks like, and
    // `Uri` has already removed real dot segments. Skip the decode.
    if (!segment.contains('%')) {
      // Defensive: `Uri` should have collapsed these already, but if a
      // caller passes a non-normalized string, do not let it through.
      if (segment == '.' || segment == '..') return true;
      continue;
    }

    final String decoded;
    try {
      decoded = Uri.decodeComponent(segment);
    } catch (_) {
      // `Uri.decodeComponent` throws ArgumentError for malformed escapes
      // like `%zz`, not FormatException as the name might suggest. Catch
      // broadly: the point is that anything we cannot decode is something
      // we cannot reason about, so it fails closed.
      return true;
    }

    if (decoded == '.' || decoded == '..') return true;
    if (decoded.contains('/') || decoded.contains('\\')) return true;
  }
  return false;
}
