/// Fetches and minimally parses a package's dartdoc HTML so the MCP layer
/// can return a structured summary to the AI.
///
/// We can't just hand the AI the dartdoc URL — Club servers run on private
/// networks the AI client typically can't reach. The MCP process *can*
/// reach the server (it's running on the user's machine), so we proxy the
/// fetch and pull out the bits a model actually needs: the package
/// description and the libraries list.
///
/// Parsing is best-effort. If dartdoc's HTML structure changes or the
/// document doesn't match expectations, we return what we have (or null)
/// and let the caller fall back to "URL only".
library;

import 'dart:convert';

import 'package:club_api/club_api.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

/// Soft cap on the [DartdocSummary.description] field, in code units (not
/// bytes — Dart `String.length` counts UTF-16 code units). Keeps tool
/// results small; the AI can follow the docs URL for the full text.
const int _descriptionCharCap = 2000;

/// Minimal structured summary derived from a dartdoc index page.
class DartdocSummary {
  const DartdocSummary({
    required this.docsUrl,
    this.description,
    this.libraries = const [],
    this.fetchError,
  });

  /// Absolute URL to the dartdoc index (or null if unavailable).
  final String docsUrl;

  /// First paragraph(s) of the package's top-level dartdoc description,
  /// truncated to a reasonable length.
  final String? description;

  /// Libraries exported by the package, in the order dartdoc lists them.
  final List<DartdocLibrary> libraries;

  /// Set when the dartdoc fetch failed at the network/parse layer (as
  /// opposed to "docs aren't generated"). Lets callers tell a transient
  /// failure apart from a missing-by-design state.
  final String? fetchError;

  Map<String, dynamic> toJson() => {
    'docsUrl': docsUrl,
    if (description != null) 'description': description,
    'libraries': libraries.map((l) => l.toJson()).toList(),
    if (fetchError != null) 'fetchError': fetchError,
  };
}

class DartdocLibrary {
  const DartdocLibrary({required this.name, required this.href, this.summary});

  final String name;
  final String href;
  final String? summary;

  Map<String, dynamic> toJson() => {
    'name': name,
    'href': href,
    if (summary != null) 'summary': summary,
  };
}

/// Fetches `/documentation/<package>/latest/index.html` from the configured
/// server and extracts a [DartdocSummary]. Returns null if the page can't
/// be fetched or parsed; callers should fall back to URL-only output.
Future<DartdocSummary?> fetchDartdocSummary(
  ClubClient client,
  String package,
) async {
  final indexPath = '/documentation/$package/latest/index.html';
  final docsUrl = client.serverUrl.resolve(indexPath).toString();

  final List<int> bytes;
  try {
    bytes = await client.fetchBytes(indexPath);
  } on ClubApiException catch (e) {
    // 404 is the "no rendered docs at this URL" case — return null so the
    // caller can rely on `dartdoc-status` instead. Other status codes mean
    // something went wrong and we want the operator to know.
    if (e.statusCode == 404) return null;
    return DartdocSummary(
      docsUrl: docsUrl,
      fetchError: '${e.code}: ${e.message}',
    );
  } catch (e) {
    return DartdocSummary(
      docsUrl: docsUrl,
      fetchError: '${e.runtimeType}: $e',
    );
  }

  final dom.Document doc;
  try {
    doc = html.parse(utf8.decode(bytes, allowMalformed: true));
  } catch (e) {
    return DartdocSummary(
      docsUrl: docsUrl,
      fetchError: 'parse failed: ${e.runtimeType}',
    );
  }

  return DartdocSummary(
    docsUrl: docsUrl,
    description: _extractDescription(doc),
    libraries: _extractLibraries(doc),
  );
}

String? _extractDescription(dom.Document doc) {
  // Standard dartdoc layout: top-level <section class="desc markdown"> …
  // sometimes additionally tagged. We grab whichever appears first.
  final candidates = [
    doc.querySelector('section.desc.markdown'),
    doc.querySelector('section.desc'),
    doc.querySelector('main section.markdown'),
  ];
  for (final node in candidates) {
    if (node == null) continue;
    final text = _normalizeWhitespace(node.text);
    if (text.isEmpty) continue;
    return _truncate(text, _descriptionCharCap);
  }
  return null;
}

List<DartdocLibrary> _extractLibraries(dom.Document doc) {
  // dartdoc renders the libraries list as a <dl> inside a section labeled
  // "Libraries". Different theme versions tag it slightly differently, so
  // try a few selectors before giving up.
  final dl =
      doc.querySelector('section.summary > dl') ??
      doc.querySelector('main dl');
  if (dl == null) return const [];

  final results = <DartdocLibrary>[];
  final children = dl.children;
  for (var i = 0; i < children.length; i++) {
    final node = children[i];
    if (node.localName != 'dt') continue;
    final anchor = node.querySelector('a');
    if (anchor == null) continue;
    final name = _normalizeWhitespace(anchor.text);
    final href = anchor.attributes['href'] ?? '';
    if (name.isEmpty || href.isEmpty) continue;

    String? summary;
    if (i + 1 < children.length && children[i + 1].localName == 'dd') {
      final raw = _normalizeWhitespace(children[i + 1].text);
      if (raw.isNotEmpty) summary = _truncate(raw, 280);
    }

    results.add(DartdocLibrary(name: name, href: href, summary: summary));
  }
  return results;
}

String _normalizeWhitespace(String input) =>
    input.replaceAll(RegExp(r'\s+'), ' ').trim();

String _truncate(String input, int byteCap) {
  if (input.length <= byteCap) return input;
  return '${input.substring(0, byteCap).trimRight()}…';
}
