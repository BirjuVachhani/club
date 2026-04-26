/// URL helpers shared across commands.
library;

/// Normalise a server URL for credential-store / resolver lookups.
///
/// Trims surrounding whitespace and strips trailing slashes so
/// `https://example.com` and `https://example.com/` match the same entry.
String normalizeServerUrl(String url) {
  var trimmed = url.trim();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}
