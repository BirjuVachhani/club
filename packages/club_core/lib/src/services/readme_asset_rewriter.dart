import 'package:crypto/crypto.dart';

import '../models/package_screenshot.dart' show screenshotExtOf;

/// One file referenced by the README and pulled out of the tarball at
/// publish time. The bytes are persisted to the blob store under the
/// asset key `<version>/readme-assets/<index>.<extension>`.
class ExtractedReadmeAsset {
  const ExtractedReadmeAsset({
    required this.extension,
    required this.mimeType,
    required this.bytes,
  });

  /// Lower-case extension without leading dot (e.g. `png`, `mp4`).
  final String extension;

  /// IANA media type derived from [extension].
  final String mimeType;

  /// Raw file bytes from the tarball.
  final List<int> bytes;
}

/// Output of [rewriteReadmeAssets].
class ReadmeRewriteResult {
  const ReadmeRewriteResult({required this.readme, required this.assets});

  /// README content with relative file references replaced by root-relative
  /// URLs that resolve against the server origin.
  final String readme;

  /// Assets the caller must persist alongside the rewritten README.
  /// Indices are stable: asset `i` is referenced by `<prefix>/i.<extension>`.
  final List<ExtractedReadmeAsset> assets;
}

/// Returns the readme-asset MIME type for [ext], or `null` if [ext] is not
/// in the supported set.
String? readmeAssetMimeFor(String ext) => _readmeAssetTypes[ext]?.mimeType;

/// Returns the per-file size cap (bytes) for [ext], or `null` if [ext] is
/// not a supported readme-asset extension. Callers use this to filter
/// archive entries during extraction so oversized files never reach the
/// rewriter.
int? readmeAssetCapFor(String ext) => _readmeAssetTypes[ext]?.cap;

/// Whitelisted extensions (lower-case, no dot) for files that may be
/// extracted as readme-assets, with their MIME type and per-file size
/// cap.
const Map<String, ({String mimeType, int cap})> _readmeAssetTypes = {
  'png': (mimeType: 'image/png', cap: _smallCap),
  'jpg': (mimeType: 'image/jpeg', cap: _smallCap),
  'jpeg': (mimeType: 'image/jpeg', cap: _smallCap),
  'gif': (mimeType: 'image/gif', cap: _smallCap),
  'webp': (mimeType: 'image/webp', cap: _smallCap),
  'svg': (mimeType: 'image/svg+xml', cap: _smallCap),
  'mp4': (mimeType: 'video/mp4', cap: _largeCap),
  'mov': (mimeType: 'video/quicktime', cap: _largeCap),
  'webm': (mimeType: 'video/webm', cap: _largeCap),
  'pdf': (mimeType: 'application/pdf', cap: _largeCap),
  'csv': (mimeType: 'text/csv', cap: _smallCap),
  'txt': (mimeType: 'text/plain', cap: _smallCap),
};

const int _smallCap = 5 * 1024 * 1024;
const int _largeCap = 50 * 1024 * 1024;

/// Rewrite relative file references in [readme] to root-relative URLs and
/// return the assets that need persisting.
///
/// Rewrite targets, in resolution order:
///   1. References whose normalised path matches a `screenshots:` entry
///      → reuse the existing screenshot URL (no duplicate stored).
///   2. References whose normalised path is in [archiveBytesByPath] AND
///      has a supported extension → extracted under a fresh index.
///   3. Everything else (absolute URLs, data:/mailto:/anchors, missing
///      files, unsupported extensions) is left untouched.
///
/// [archiveBytesByPath] must already be filtered to supported extensions
/// within their size caps; this function does no I/O and trusts what it
/// is given. Keys are POSIX paths with any leading `./` stripped.
ReadmeRewriteResult rewriteReadmeAssets({
  required String readme,
  required Map<String, List<int>> archiveBytesByPath,
  required List<String> screenshotPaths,
  required String packageName,
  required String version,
}) {
  final readmeAssetPrefix =
      '/api/packages/$packageName/versions/$version/readme-assets/';
  final screenshotPrefix =
      '/api/packages/$packageName/versions/$version/screenshots/';

  // Pre-build screenshot lookup keyed by the same normalised path used
  // for archive lookups so a README can reference `./screenshots/a.png`,
  // `screenshots/a.png`, or `/screenshots/a.png` interchangeably.
  final screenshotUrlByPath = <String, String>{};
  for (var i = 0; i < screenshotPaths.length; i++) {
    final raw = screenshotPaths[i];
    final ext = screenshotExtOf(raw);
    final normalised = _normalisePath(raw);
    if (normalised.isEmpty) continue;
    screenshotUrlByPath[normalised] = '$screenshotPrefix$i.$ext';
  }

  final assets = <ExtractedReadmeAsset>[];
  final indexBySha = <String, int>{};

  String? resolveUrl(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) return null;
    if (_isAbsoluteOrSpecial(trimmed)) return null;

    // Split path from query/fragment so we can preserve the suffix when
    // rewriting (e.g. `foo.png?v=2` → `<url>?v=2`).
    var path = trimmed;
    var suffix = '';
    final cutAt = _firstIndexOfAny(path, const ['?', '#']);
    if (cutAt >= 0) {
      suffix = path.substring(cutAt);
      path = path.substring(0, cutAt);
    }

    final normalised = _normalisePath(_safeUrlDecode(path));
    if (normalised.isEmpty) return null;

    final screenshotUrl = screenshotUrlByPath[normalised];
    if (screenshotUrl != null) return '$screenshotUrl$suffix';

    final bytes = archiveBytesByPath[normalised];
    if (bytes == null) return null;

    final ext = screenshotExtOf(normalised);
    final type = _readmeAssetTypes[ext];
    if (type == null) return null;

    final shaHex = sha256.convert(bytes).toString();
    final idx = indexBySha.putIfAbsent(shaHex, () {
      final i = assets.length;
      assets.add(
        ExtractedReadmeAsset(
          extension: ext,
          mimeType: type.mimeType,
          bytes: bytes,
        ),
      );
      return i;
    });

    return '$readmeAssetPrefix$idx.$ext$suffix';
  }

  var rewritten = readme;
  for (final pattern in _patterns) {
    rewritten = rewritten.replaceAllMapped(pattern, (m) {
      final match = m as RegExpMatch;
      final orig = match.group(0)!;
      final path = match.namedGroup('path');
      if (path == null) return orig;
      final url = resolveUrl(path);
      if (url == null) return orig;
      final prefix = match.namedGroup('prefix') ?? '';
      final suffix = match.namedGroup('suffix') ?? '';
      return '$prefix$url$suffix';
    });
  }

  return ReadmeRewriteResult(readme: rewritten, assets: assets);
}

/// Strip the readme-asset URL scheme prefixes that signal a non-local
/// reference. Includes `//` (protocol-relative) so we never accidentally
/// rewrite an external CDN reference into a local path.
bool _isAbsoluteOrSpecial(String s) =>
    s.startsWith('http://') ||
    s.startsWith('https://') ||
    s.startsWith('mailto:') ||
    s.startsWith('tel:') ||
    s.startsWith('data:') ||
    s.startsWith('javascript:') ||
    s.startsWith('//') ||
    s.startsWith('#');

/// Strip leading `./` and `/` so author-style paths resolve against the
/// archive root (where pubspec.yaml + README live), matching how the
/// reader normalises archive entry names. Returns an empty string for
/// paths containing `..` segments — these can't appear in a tarball
/// (the reader rejects them) but skipping defensively keeps traversal
/// strings out of lookup maps.
String _normalisePath(String path) {
  var n = path;
  while (n.startsWith('./')) {
    n = n.substring(2);
  }
  while (n.startsWith('/')) {
    n = n.substring(1);
  }
  if (n.split('/').contains('..')) return '';
  return n;
}

String _safeUrlDecode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

int _firstIndexOfAny(String s, List<String> needles) {
  var lowest = -1;
  for (final n in needles) {
    final i = s.indexOf(n);
    if (i >= 0 && (lowest < 0 || i < lowest)) lowest = i;
  }
  return lowest;
}

/// Capture groups: `prefix` (text kept verbatim before the path),
/// `path` (the URL/path being rewritten), `suffix` (text kept after).
/// Each pattern preserves surrounding markup so the rewrite is local to
/// the URL portion.
final List<RegExp> _patterns = [
  // Markdown image: ![alt](path) or ![alt](path "title")
  RegExp(
    r'(?<prefix>!\[[^\]]*\]\()(?<path>[^\s)]+)(?<suffix>(?:\s+"[^"]*")?\))',
  ),
  // Markdown link: [text](path) — negative lookbehind excludes images.
  RegExp(
    r'(?<prefix>(?<!!)\[[^\]]*\]\()(?<path>[^\s)]+)(?<suffix>(?:\s+"[^"]*")?\))',
  ),
  // Markdown link reference definition at start of line:
  //   [label]: path
  //   [label]: path "title"
  RegExp(
    r'(?<prefix>^\s*\[[^\]]+\]:\s+)(?<path>\S+)(?<suffix>(?:\s+["(].*)?)$',
    multiLine: true,
  ),
  // HTML attributes (double-quoted) on tags that can host file references.
  RegExp(
    r'(?<prefix><(?:img|video|audio|source|a)\b[^>]*?\b(?:src|href|poster)=")(?<path>[^"]*)(?<suffix>")',
    caseSensitive: false,
  ),
  // Same, single-quoted.
  RegExp(
    r"(?<prefix><(?:img|video|audio|source|a)\b[^>]*?\b(?:src|href|poster)=')(?<path>[^']*)(?<suffix>')",
    caseSensitive: false,
  ),
];
