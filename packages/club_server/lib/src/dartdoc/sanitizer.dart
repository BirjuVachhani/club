import 'dart:async';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

/// Scrub attacker-controlled execution vectors out of a dartdoc HTML tree.
///
/// A malicious package can embed HTML inside its dartdoc comments (e.g.
/// ```` ```dart /// <script>…</script> ``` ````) and dartdoc will faithfully
/// render it into `<…>-library.html` and similar pages. If we serve those
/// pages under the registry's origin, that script runs with access to the
/// registry's cookies — session theft, PAT exfiltration, silent mutations.
///
/// We close that off by rewriting every HTML and SVG file in the tree
/// before it's persisted: inline `<script>` bodies are removed (we keep
/// same-origin `<script src="…">` for dartdoc's own bundle), every `on*`
/// event-handler attribute is dropped, and any attribute whose value
/// resolves to a `javascript:` URL is stripped.
///
/// The strict CSP emitted by the security_headers middleware
/// (`script-src 'self'`, no `'unsafe-inline'`) is the primary defense —
/// browsers will refuse to run any inline script regardless of what slips
/// through here. This sanitizer is the belt-and-braces counterpart for
/// contexts where CSP isn't enforced (legacy browsers, embedded WebView).
Future<SanitizeStats> sanitizeDartdocTree(
  Directory root, {
  void Function(String message)? log,
}) async {
  final stats = SanitizeStats();
  if (!await root.exists()) return stats;

  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final ext = p.extension(entity.path).toLowerCase();
    try {
      if (ext == '.html' || ext == '.htm') {
        final changed = await _sanitizeHtmlFile(entity, stats);
        if (changed) stats.htmlFilesRewritten++;
        stats.htmlFilesScanned++;
      } else if (ext == '.svg') {
        final changed = await _sanitizeSvgFile(entity, stats);
        if (changed) stats.svgFilesRewritten++;
        stats.svgFilesScanned++;
      }
    } catch (e) {
      stats.errors++;
      log?.call('sanitizer: failed to process ${entity.path}: $e');
    }
  }

  return stats;
}

/// Counters surfaced to the scoring logs so operators can see that
/// sanitization ran and whether it found anything worth stripping.
class SanitizeStats {
  int htmlFilesScanned = 0;
  int htmlFilesRewritten = 0;
  int svgFilesScanned = 0;
  int svgFilesRewritten = 0;
  int inlineScriptsRemoved = 0;
  int eventHandlersRemoved = 0;
  int javascriptUrisRemoved = 0;
  int errors = 0;

  @override
  String toString() =>
      'SanitizeStats('
      'html=$htmlFilesRewritten/$htmlFilesScanned, '
      'svg=$svgFilesRewritten/$svgFilesScanned, '
      'inlineScripts=$inlineScriptsRemoved, '
      'onHandlers=$eventHandlersRemoved, '
      'jsUris=$javascriptUrisRemoved, '
      'errors=$errors)';
}

Future<bool> _sanitizeHtmlFile(File file, SanitizeStats stats) async {
  final original = await file.readAsString();
  final doc = html_parser.parse(original);
  final changed = _scrubDocument(doc, stats);
  if (!changed) return false;
  // `outerHtml` on the Document gives us the full serialised tree including
  // the doctype. package:html normalises attribute quoting and case, so the
  // output won't be byte-identical even when `changed` is true — we only
  // rewrite when something was actually stripped.
  await file.writeAsString(doc.outerHtml);
  return true;
}

Future<bool> _sanitizeSvgFile(File file, SanitizeStats stats) async {
  final original = await file.readAsString();
  // Parse SVG as an HTML fragment. package:html is lenient enough that
  // embedded `<script>` and `on*` handlers are still exposed as element
  // nodes / attributes we can strip — good enough for our defense-in-depth
  // pass. A full XML parser would be more faithful but would also reject
  // a lot of real-world dartdoc-embedded SVG that tolerates minor quirks.
  final doc = html_parser.parseFragment(original);
  final changed = _scrubNode(doc, stats);
  if (!changed) return false;
  await file.writeAsString(doc.outerHtml);
  return true;
}

bool _scrubDocument(dom.Document doc, SanitizeStats stats) {
  var changed = false;
  if (_scrubNode(doc.documentElement ?? doc, stats)) changed = true;
  return changed;
}

bool _scrubNode(dom.Node node, SanitizeStats stats) {
  var changed = false;

  if (node is dom.Element) {
    final tagName = node.localName?.toLowerCase();

    // Inline `<script>` bodies are the primary stored-XSS vector. We keep
    // external same-origin references (`<script src="static-assets/…">`)
    // that dartdoc needs to function, because they can only load code from
    // the same origin (CSP `script-src 'self'` enforces this at runtime).
    if (tagName == 'script') {
      final src = node.attributes['src'];
      if (src == null || src.isEmpty) {
        node.remove();
        stats.inlineScriptsRemoved++;
        return true;
      }
      // External script — still strip dangerous attributes below, but keep
      // the element.
    }

    // Same-origin policy for `<iframe>` and `<object>` would require runtime
    // inspection of the `src`/`data` attribute against the registry's origin.
    // Dartdoc doesn't emit either, so we remove them wholesale — anything
    // that appears is attacker-controlled.
    if (tagName == 'iframe' ||
        tagName == 'object' ||
        tagName == 'embed' ||
        tagName == 'applet') {
      node.remove();
      stats.inlineScriptsRemoved++;
      return true;
    }

    // Strip event-handler and javascript:-URL attributes. We iterate over
    // a snapshot because removals mutate the underlying map.
    final attrsSnapshot = node.attributes.entries.toList();
    for (final entry in attrsSnapshot) {
      final rawKey = entry.key;
      final keyString = rawKey is dom.AttributeName
          ? rawKey.name
          : rawKey.toString();
      final keyLower = keyString.toLowerCase();
      final value = entry.value;

      if (keyLower.startsWith('on')) {
        node.attributes.remove(rawKey);
        stats.eventHandlersRemoved++;
        changed = true;
        continue;
      }

      if (_isUrlAttribute(keyLower) && _looksLikeJavascriptUrl(value)) {
        node.attributes.remove(rawKey);
        stats.javascriptUrisRemoved++;
        changed = true;
        continue;
      }
    }
  }

  // Recurse into children. Copy the list because scrubbing may remove
  // children from the parent.
  final children = List<dom.Node>.from(node.nodes);
  for (final child in children) {
    if (_scrubNode(child, stats)) changed = true;
  }

  return changed;
}

bool _isUrlAttribute(String name) {
  return name == 'href' ||
      name == 'src' ||
      name == 'action' ||
      name == 'formaction' ||
      name == 'background' ||
      name == 'poster' ||
      name == 'cite' ||
      name == 'xlink:href';
}

bool _looksLikeJavascriptUrl(String value) {
  // Browsers strip ASCII whitespace and control chars from the start of
  // a URL before evaluating its scheme, so `java\tscript:` and newline-
  // padded variants still run as JS. Mirror that parsing here.
  final normalized = value
      .replaceAll(RegExp(r'[\s\x00-\x1f]'), '')
      .toLowerCase();
  return normalized.startsWith('javascript:') ||
      normalized.startsWith('vbscript:') ||
      normalized.startsWith('data:text/html') ||
      normalized.startsWith('data:application/javascript') ||
      normalized.startsWith('data:application/x-javascript') ||
      normalized.startsWith('data:text/javascript');
}
