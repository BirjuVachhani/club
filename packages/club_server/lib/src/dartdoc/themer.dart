/// Apply the club visual theme to a dartdoc-generated HTML tree in place.
///
/// Dartdoc's default output is the pub.dev-style page (Roboto, blue links,
/// dark gradient header). This pass swaps in club's design tokens, fonts,
/// and a handful of layout tweaks so docs served under `/documentation/`
/// match the rest of club_web.
///
/// Strategy — intentionally non-invasive so dartdoc's own search and
/// theme-toggle JS keep working:
///
///   1. Drop `club-theme.css`, `club-theme.js`, and `club_logo.svg` into
///      the tree's `static-assets/` directory.
///   2. For every `.html` file: parse the doc with `package:html`, append a
///      `<link rel="stylesheet">` and `<script src defer>` pointing at our
///      assets (with a per-page relative path), and rewrite the favicon
///      `<link rel="icon">` to club_logo.svg.
///
/// The injected stylesheet redefines dartdoc's `--main-*` CSS custom
/// properties using club's palette (`--club-primary`, `--club-bg`, …), so
/// dartdoc's existing rules pick up the new colors. The runtime script
/// adds copy buttons to `<pre>` blocks, marks the active sidebar link, and
/// cleans up the search input placeholder. Everything we add is safe under
/// the dartdoc CSP emitted by `security_headers.dart` (`script-src 'self'`,
/// `style-src 'self' 'unsafe-inline' fonts.googleapis.com`, etc.).
///
/// This pass runs *after* `sanitizeDartdocTree` in the scoring worker so
/// the sanitizer's HTML round-trip doesn't re-touch our injected nodes.
/// We add only known-safe content (external `src` / `href`, no inline JS,
/// no `on*` handlers), so an out-of-order run would also be acceptable.
library;

import 'dart:async';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

/// Apply the club theme to every HTML file under [root] and write the
/// supporting assets into `<root>/static-assets/`.
///
/// Returns counters that operators can dump to scoring logs to confirm
/// the pass actually ran on each generation.
Future<ThemeStats> applyClubTheme(
  Directory root, {
  void Function(String message)? log,
}) async {
  final stats = ThemeStats();
  if (!await root.exists()) return stats;

  // 1. Write the supporting assets. Always overwrite so a re-score picks up
  //    any updated tokens or scripts without operators having to clear the
  //    persisted tree by hand.
  final staticAssets = Directory(p.join(root.path, 'static-assets'));
  await staticAssets.create(recursive: true);

  await File(p.join(staticAssets.path, _clubCssFile))
      .writeAsString(_clubThemeCss);
  await File(p.join(staticAssets.path, _clubJsFile))
      .writeAsString(_clubThemeJs);
  await File(p.join(staticAssets.path, _clubLogoFile))
      .writeAsString(_clubLogoSvg);
  stats.assetsWritten = 3;

  // 2. Walk every .html file and inject our <link> + <script>.
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (p.extension(entity.path).toLowerCase() != '.html') continue;
    try {
      final injected = await _injectIntoHtml(entity, root.path);
      if (injected) stats.htmlFilesInjected++;
      stats.htmlFilesScanned++;
    } catch (e) {
      stats.errors++;
      log?.call('themer: failed to process ${entity.path}: $e');
    }
  }

  return stats;
}

/// Counters surfaced to scoring logs. Mirrors `SanitizeStats` so operators
/// see one consistent shape across the dartdoc post-processing phases.
class ThemeStats {
  int htmlFilesScanned = 0;
  int htmlFilesInjected = 0;
  int assetsWritten = 0;
  int errors = 0;

  @override
  String toString() =>
      'ThemeStats('
      'html=$htmlFilesInjected/$htmlFilesScanned, '
      'assets=$assetsWritten, '
      'errors=$errors)';
}

const _clubCssFile = 'club-theme.css';
const _clubJsFile = 'club-theme.js';
const _clubLogoFile = 'club_logo.svg';

/// Cache-buster bumped whenever the embedded CSS or JS changes. Keeps
/// browsers from serving a stale themed-but-old asset out of disk cache.
const _clubAssetVersion = 'v1';

Future<bool> _injectIntoHtml(File file, String rootPath) async {
  final raw = await file.readAsString();
  final doc = html_parser.parse(raw);
  final head = doc.head;
  if (head == null) return false;

  // Idempotent: if a previous theme pass already injected our nodes,
  // bail out so we don't duplicate them on re-runs.
  if (head.querySelector('link[data-club-theme]') != null) return false;

  final fromDir = p.dirname(file.path);
  String relTo(String name) {
    final target = p.join(rootPath, 'static-assets', name);
    return p.relative(target, from: fromDir).replaceAll(r'\', '/');
  }

  // Swap the favicon to club_logo.svg.
  final faviconHref = relTo(_clubLogoFile);
  final existingIcon = head.querySelector('link[rel="icon"]');
  if (existingIcon != null) {
    existingIcon.attributes['href'] = faviconHref;
    existingIcon.attributes['type'] = 'image/svg+xml';
  } else {
    head.append(
      doc.createElement('link')
        ..attributes['rel'] = 'icon'
        ..attributes['type'] = 'image/svg+xml'
        ..attributes['href'] = faviconHref,
    );
  }

  head.append(
    dom.Element.tag('link')
      ..attributes['rel'] = 'stylesheet'
      ..attributes['href'] = '${relTo(_clubCssFile)}?$_clubAssetVersion'
      ..attributes['data-club-theme'] = 'css',
  );

  head.append(
    dom.Element.tag('script')
      ..attributes['src'] = '${relTo(_clubJsFile)}?$_clubAssetVersion'
      ..attributes['defer'] = 'defer'
      ..attributes['data-club-theme'] = 'js',
  );

  await file.writeAsString(doc.outerHtml);
  return true;
}

// ───────────────────────────────────────────────────────────────────────
// Embedded assets. Kept as Dart const strings so the binary is self-
// contained — the scoring worker has no runtime access to packages/club_web.
//
// Tokens here intentionally mirror packages/club_web/src/app.css. When
// updating club's design tokens, update both files in lockstep.
// ───────────────────────────────────────────────────────────────────────

const _clubThemeCss = r'''
/* club theme overrides for dartdoc.
   Strategy: redefine dartdoc's --main-* custom properties using club's
   palette so all of dartdoc's existing rules pick up the new colors. */

@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
@import url('https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&display=swap');

:root {
  /* club tokens */
  --club-primary: #FF4F18;
  --club-primary-hover: #CC3600;

  /* light theme tokens */
  --club-bg: #FFFFFF;
  --club-fg: #141517;
  --club-card: #FFFFFF;
  --club-border: #E0E2E7;
  --club-muted: #f8f8f8;
  --club-muted-fg: #64748b;
  --club-accent: #FFF0EB;
  --club-secondary: #EAECF0;
  --club-code-bg: #F2F4F7;
  --club-code-border: #d8dce3;
  --club-header-bg: #FFFFFF;
  --club-header-fg: #141517;
  --club-header-border: #E0E2E7;
  --club-header-muted: #64748b;
  --club-input-bg: #F8F9FB;
  --club-input-border: #D5D7DC;
  --club-footer-bg: #050505;
  --club-footer-fg: #9A9AA1;
  --club-footer-border: #1a1a1a;
}

body.light-theme {
  --main-bg-color: var(--club-bg);
  --main-header-color: var(--club-header-bg);
  --main-sidebar-color: var(--club-fg);
  --main-text-color: var(--club-fg);
  --main-search-bar: var(--club-input-bg);
  --main-footer-background: var(--club-footer-bg);
  --main-h-text: var(--club-fg);
  --main-hyperlinks-color: var(--club-primary);
  --main-inset-bgColor: var(--club-muted);
  --main-inset-borderColor: var(--club-border);
  --main-code-bg: var(--club-code-bg);
  --main-keyword-color: #d73a49;
  --main-tag-color: #6f42c1;
  --main-section-color: #e36209;
  --main-comment-color: #6a737d;
}

body.dark-theme {
  --club-bg: #050505;
  --club-fg: #EDEDED;
  --club-card: #111111;
  --club-border: #252525;
  --club-muted: #161616;
  --club-muted-fg: #9A9AA1;
  --club-accent: #1F1F1F;
  --club-secondary: #1A1A1A;
  --club-code-bg: #0e0e0e;
  --club-code-border: #262626;
  --club-header-bg: #050505;
  --club-header-fg: #F2F4F7;
  --club-header-border: #1a1a1a;
  --club-header-muted: #9A9AA1;
  --club-input-bg: #111111;
  --club-input-border: #252525;
  --club-footer-bg: #161616;
  --club-footer-fg: #9A9AA1;
  --club-footer-border: #252525;

  --main-bg-color: var(--club-bg);
  --main-header-color: var(--club-header-bg);
  --main-sidebar-color: var(--club-fg);
  --main-text-color: var(--club-fg);
  --main-search-bar: var(--club-input-bg);
  --main-footer-background: var(--club-footer-bg);
  --main-h-text: var(--club-fg);
  --main-hyperlinks-color: #FF6633;
  --main-inset-bgColor: var(--club-card);
  --main-inset-borderColor: var(--club-border);
  --main-code-bg: var(--club-code-bg);
  --main-keyword-color: #ff7b72;
  --main-tag-color: #d2a8ff;
  --main-section-color: #ffa657;
  --main-comment-color: #8b949e;
}

/* ── Typography ────────────────────────────────────────────── */

body {
  font-family: 'Inter', system-ui, -apple-system, 'Segoe UI', Roboto,
    'Helvetica Neue', Arial, sans-serif !important;
  font-feature-settings: 'kern', 'calt';
  -webkit-font-smoothing: antialiased;
  font-size: 15px !important;
  line-height: 1.6 !important;
}

h1, h2, h3, h4, h5, h6 {
  font-family: inherit !important;
  letter-spacing: -0.02em;
  color: var(--club-fg) !important;
}

code, pre, kbd, .typeahead, .tt-wrapper .typeahead {
  font-family: 'Fira Code', 'Roboto Mono', ui-monospace, SFMono-Regular,
    Consolas, 'Liberation Mono', monospace !important;
  font-variant-ligatures: contextual common-ligatures;
  font-feature-settings: 'calt', 'liga';
}

/* ── Header ─────────────────────────────────────────────────── */

header#title {
  background: var(--club-header-bg) !important;
  color: var(--club-header-fg) !important;
  border-bottom: 1px solid var(--club-header-border) !important;
  height: 56px;
  padding: 0 1rem;
  box-shadow: none !important;
}

header#title .self-name {
  font-weight: 600;
  font-size: 15px;
  color: var(--club-header-fg);
  letter-spacing: -0.01em;
}

header#title .breadcrumbs li,
header#title .breadcrumbs a {
  color: var(--club-header-muted) !important;
  font-size: 14px;
}
header#title .breadcrumbs a:hover {
  color: var(--club-header-fg) !important;
}
header#title .breadcrumbs .self-crumb {
  color: var(--club-header-fg) !important;
  font-weight: 500;
}

header#title #sidenav-left-toggle {
  color: var(--club-header-fg);
}

/* Brand mark — small accent dot before the breadcrumbs to give docs
   pages a visual link back to the club brand. */
header#title::before {
  content: '';
  display: inline-block;
  width: 10px;
  height: 10px;
  border-radius: 999px;
  background: var(--club-primary);
  margin-right: 12px;
  flex-shrink: 0;
  box-shadow: 0 0 0 3px rgba(255, 79, 24, 0.18);
}

header#title .toggle {
  background: var(--club-input-bg) !important;
  border: 1px solid var(--club-input-border) !important;
  border-radius: 8px;
  color: var(--club-header-fg) !important;
  width: 36px;
  height: 36px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  transition: background 0.15s, border-color 0.15s;
}
header#title .toggle:hover {
  background: var(--club-accent) !important;
  border-color: color-mix(in srgb, var(--club-primary) 30%, var(--club-input-border)) !important;
}

/* ── Search input in header ─────────────────────────────────── */
/* dartdoc's bundled search.svg is dark-on-dark and disappears in our
   dark theme. Render the icon as an inline data-URI SVG so we can
   stroke it with a theme-aware muted color. */

header#title .search input,
header#title .typeahead {
  background-color: var(--club-input-bg) !important;
  border: 1px solid var(--club-input-border) !important;
  border-radius: 8px !important;
  color: var(--club-fg) !important;
  height: 36px !important;
  padding-left: 36px !important;
  background-repeat: no-repeat !important;
  background-position: 12px center !important;
  background-size: 16px 16px !important;
  filter: none;
  font-size: 14px !important;
  width: 320px !important;
}
body.light-theme header#title .search input,
body.light-theme header#title .typeahead {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%2364748b' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><circle cx='11' cy='11' r='8'/><path d='m21 21-4.35-4.35'/></svg>") !important;
}
body.dark-theme header#title .search input,
body.dark-theme header#title .typeahead {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%239A9AA1' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><circle cx='11' cy='11' r='8'/><path d='m21 21-4.35-4.35'/></svg>") !important;
}
header#title .search input::placeholder {
  color: var(--club-muted-fg) !important;
}
header#title .search input:focus,
header#title .typeahead:focus {
  outline: none !important;
  border-color: rgba(255, 79, 24, 0.5) !important;
  box-shadow: 0 0 0 3px rgba(255, 79, 24, 0.18) !important;
}

/* ── Sidebars ───────────────────────────────────────────────── */

#dartdoc-sidebar-left,
.sidebar-offcanvas-left {
  background: var(--club-bg) !important;
  border-right: 1px solid var(--club-border);
  box-shadow: none !important;
  font-size: 14px;
}

#dartdoc-sidebar-right,
.sidebar-offcanvas-right {
  background: var(--club-bg) !important;
  border-left: 1px solid var(--club-border);
  box-shadow: none !important;
  font-size: 14px;
  /* Default 12em is too cramped — give class members + nav room. */
  flex: 0 1 18em !important;
  min-width: 240px !important;
  padding: 25px 18px 15px 22px !important;
}

#dartdoc-sidebar-left ol li a,
#dartdoc-sidebar-right ol li a {
  color: var(--club-fg) !important;
  border-radius: 6px;
  padding: 4px 10px;
  display: block;
  transition: background 0.12s, color 0.12s;
}
#dartdoc-sidebar-left ol li a:hover,
#dartdoc-sidebar-right ol li a:hover {
  background: var(--club-accent);
  color: var(--club-primary) !important;
  text-decoration: none;
}

/* Active page in sidebar — toggled by club-theme.js based on current URL.
   Subtle accent fill + left rail to mirror club_web's nav idiom. */
#dartdoc-sidebar-left ol li a.club-active,
#dartdoc-sidebar-right ol li a.club-active {
  background: var(--club-accent) !important;
  color: var(--club-primary) !important;
  font-weight: 600;
  position: relative;
}
#dartdoc-sidebar-left ol li a.club-active::before,
#dartdoc-sidebar-right ol li a.club-active::before {
  content: '';
  position: absolute;
  left: -2px;
  top: 4px;
  bottom: 4px;
  width: 3px;
  border-radius: 999px;
  background: var(--club-primary);
}

#dartdoc-sidebar-left ol li.section-title,
#dartdoc-sidebar-right ol li.section-title {
  color: var(--club-muted-fg) !important;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  margin-top: 1.25rem;
  padding: 0 10px;
}

#dartdoc-sidebar-left h5 .package-name {
  color: var(--club-fg) !important;
  font-weight: 600;
}

/* ── Main content ───────────────────────────────────────────── */

main {
  background: var(--club-bg);
}

#dartdoc-main-content {
  font-size: 15px;
  line-height: 1.7;
}

#dartdoc-main-content h1 {
  font-size: 1.75rem;
  font-weight: 700;
  margin-bottom: 0.75rem;
}
#dartdoc-main-content h2 {
  font-size: 1.25rem;
  font-weight: 600;
  margin-top: 2rem;
  border-bottom: 1px solid var(--club-border);
  padding-bottom: 0.5rem;
}
#dartdoc-main-content h3 {
  font-size: 1.0625rem;
  font-weight: 600;
}

#dartdoc-main-content a {
  color: var(--club-primary) !important;
  text-decoration: none;
}
#dartdoc-main-content a:hover {
  color: var(--club-primary-hover) !important;
  text-decoration: underline;
  text-underline-offset: 3px;
}

/* Library / class summary lists — match baseline dartdoc: no card
   chrome, just clean vertical spacing between rows. */
.summary {
  margin-top: 1rem;
}
.summary dl {
  display: block;
}
.summary dt {
  background: transparent !important;
  border: 0 !important;
  padding: 0 !important;
  margin-top: 1rem;
  box-shadow: none !important;
}
.summary dd {
  margin-left: 0;
  padding: 0;
  color: var(--club-muted-fg);
  font-size: 14px;
  margin-bottom: 1rem;
}

/* ── Code blocks ────────────────────────────────────────────── */

pre, .source-code, code.prettyprint {
  background: var(--club-code-bg) !important;
  border: 1px solid var(--club-code-border) !important;
  border-radius: 12px !important;
  padding: 14px 18px !important;
  font-size: 13.5px !important;
  line-height: 1.55 !important;
  overflow-x: auto;
}

:not(pre) > code {
  background: var(--club-code-bg) !important;
  border: 1px solid var(--club-code-border);
  border-radius: 6px !important;
  padding: 0.1em 0.36em !important;
  font-size: 0.88em !important;
}

/* ── Tags / badges (e.g. inherited, override) ──────────────── */

.feature {
  background: var(--club-accent) !important;
  color: var(--club-primary) !important;
  border: 1px solid color-mix(in srgb, var(--club-primary) 25%, transparent) !important;
  border-radius: 999px !important;
  font-size: 11px !important;
  font-weight: 600;
  padding: 2px 10px !important;
  letter-spacing: 0.02em;
}

/* ── Topic / category chips ────────────────────────────────── */
/* dartdoc auto-generates rainbow .cp-N classes (cp-0 … cp-11). They
   look chaotic in a list. Override every variant to use one calm
   muted-chip style — like club_web's tag pills. */

.category,
.category.linked,
.category.cp-0, .category.cp-1, .category.cp-2, .category.cp-3,
.category.cp-4, .category.cp-5, .category.cp-6, .category.cp-7,
.category.cp-8, .category.cp-9, .category.cp-10, .category.cp-11,
.category.cp-12, .category.cp-13, .category.cp-14, .category.cp-15 {
  background: var(--club-muted) !important;
  color: var(--club-muted-fg) !important;
  border: 1px solid var(--club-border) !important;
  border-radius: 6px !important;
  font-size: 10.5px !important;
  font-weight: 600 !important;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  opacity: 1 !important;
  padding: 2px 7px !important;
  vertical-align: middle;
  transition: background 0.15s, border-color 0.15s, color 0.15s;
}
.category a,
.category.linked a {
  color: var(--club-muted-fg) !important;
  text-decoration: none !important;
}
.category.linked:hover {
  background: var(--club-accent) !important;
  border-color: color-mix(in srgb, var(--club-primary) 25%, var(--club-border)) !important;
  color: var(--club-primary) !important;
}
.category.linked:hover a {
  color: var(--club-primary) !important;
}

/* Neutralize dartdoc's `text-indent: -24px; margin-left: 24px` which
   shoves inline children (like the .category chip) over the class name.
   Use flex so the chip sits next to the name with a real gap. */
section.summary dt,
div.summary dt,
.summary dt {
  display: flex !important;
  flex-wrap: wrap;
  align-items: center;
  gap: 10px;
  text-indent: 0 !important;
  margin-left: 0 !important;
}
.summary dt > .name {
  flex: 0 0 auto;
}

/* ── Code block copy button (paired with club-theme.js) ─────── */

pre.club-code-wrap {
  position: relative;
}
pre .club-copy-btn {
  position: absolute;
  top: 8px;
  right: 8px;
  height: 28px;
  padding: 0 10px;
  border: 1px solid var(--club-code-border);
  border-radius: 6px;
  background: var(--club-bg);
  color: var(--club-muted-fg);
  font-family: 'Inter', system-ui, sans-serif;
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  cursor: pointer;
  opacity: 0;
  transition: opacity 0.12s, background 0.12s, color 0.12s, border-color 0.12s;
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
pre:hover .club-copy-btn,
pre:focus-within .club-copy-btn,
pre .club-copy-btn:focus-visible {
  opacity: 1;
}
pre .club-copy-btn:hover {
  color: var(--club-primary);
  border-color: color-mix(in srgb, var(--club-primary) 30%, var(--club-code-border));
  background: var(--club-accent);
}
pre .club-copy-btn[data-copied="true"] {
  color: var(--club-primary);
  border-color: color-mix(in srgb, var(--club-primary) 35%, var(--club-code-border));
}
pre .club-copy-btn svg {
  width: 12px;
  height: 12px;
}

/* ── Tables ─────────────────────────────────────────────────── */

table {
  border-collapse: collapse;
  width: 100%;
  font-size: 14px;
}
th, td {
  border-bottom: 1px solid var(--club-border) !important;
  padding: 0.65rem 0.85rem !important;
  text-align: left;
}
th {
  color: var(--club-muted-fg);
  font-weight: 600;
  font-size: 12px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

/* ── Footer ─────────────────────────────────────────────────── */

/* Pin footer to the bottom of short pages, otherwise dartdoc's white
   html background bleeds below. */
html, body {
  min-height: 100vh;
}
html {
  background: var(--club-bg);
}
body {
  background: var(--club-bg) !important;
}
main {
  flex: 1 0 auto !important;
}

footer {
  background: var(--club-footer-bg) !important;
  color: var(--club-footer-fg) !important;
  /* dartdoc forces `flex: 0 0 16px` which collides with border-box and
     pushes content past the box. Reset to auto-size. */
  flex: 0 0 auto !important;
  padding: 1rem 1.25rem !important;
  font-size: 12.5px;
  line-height: 1.4;
  border-top: 1px solid var(--club-footer-border) !important;
  margin-top: 0 !important;
}
footer .no-break {
  color: var(--club-footer-fg);
  letter-spacing: 0.02em;
}
footer::after {
  content: 'Powered by CLUB';
  margin-left: 1.25rem;
  color: #6a6a72;
  font-size: 12px;
  letter-spacing: 0.04em;
}

/* ── Typeahead search dropdown ─────────────────────────────── */

.tt-menu {
  background: var(--club-card) !important;
  border: 1px solid var(--club-border) !important;
  border-radius: 10px !important;
  box-shadow: 0 12px 28px rgba(0, 0, 0, 0.08) !important;
  overflow: hidden;
  margin-top: 6px;
}
.tt-menu .tt-suggestion {
  padding: 8px 12px;
  font-size: 13.5px;
}
.tt-menu .tt-suggestion:hover,
.tt-menu .tt-cursor {
  background: var(--club-accent) !important;
  color: var(--club-primary);
}

/* ── Scrollbars (subtle, like club_web) ────────────────────── */

* {
  scrollbar-width: thin;
  scrollbar-color: var(--club-border) transparent;
}
*::-webkit-scrollbar { width: 8px; height: 8px; }
*::-webkit-scrollbar-track { background: transparent; }
*::-webkit-scrollbar-thumb {
  background: var(--club-border);
  border-radius: 999px;
}
*::-webkit-scrollbar-thumb:hover {
  background: var(--club-muted-fg);
}

/* Hide the dartdoc footer "https://dart.dev" advertising row, if
   present on some templates. */
.no-break + a[href*="dart.dev"] { display: none; }
''';

const _clubThemeJs = r'''
(function () {
  var SVG_NS = 'http://www.w3.org/2000/svg';

  function svg(paths) {
    var el = document.createElementNS(SVG_NS, 'svg');
    el.setAttribute('viewBox', '0 0 24 24');
    el.setAttribute('fill', 'none');
    el.setAttribute('stroke', 'currentColor');
    el.setAttribute('stroke-width', '2');
    el.setAttribute('stroke-linecap', 'round');
    el.setAttribute('stroke-linejoin', 'round');
    paths.forEach(function (spec) {
      var node = document.createElementNS(SVG_NS, spec.tag);
      Object.keys(spec.attrs).forEach(function (k) {
        node.setAttribute(k, spec.attrs[k]);
      });
      el.appendChild(node);
    });
    return el;
  }

  function copyIcon() {
    return svg([
      { tag: 'rect', attrs: { x: 9, y: 9, width: 13, height: 13, rx: 2, ry: 2 } },
      { tag: 'path', attrs: { d: 'M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1' } },
    ]);
  }

  function checkIcon() {
    return svg([
      { tag: 'polyline', attrs: { points: '20 6 9 17 4 12' } },
    ]);
  }

  function renderBtnContent(btn, iconFactory, label) {
    btn.replaceChildren();
    btn.appendChild(iconFactory());
    var span = document.createElement('span');
    span.textContent = label;
    btn.appendChild(span);
  }

  function setPlaceholders() {
    document.querySelectorAll('input.typeahead').forEach(function (el) {
      // Wait for dartdoc's search to enable the input before changing text.
      var observer = new MutationObserver(function () {
        if (!el.disabled) el.setAttribute('placeholder', 'Search docs');
      });
      observer.observe(el, { attributes: true, attributeFilter: ['disabled'] });
      if (!el.disabled) el.setAttribute('placeholder', 'Search docs');
    });
  }

  function addCopyButtons() {
    document.querySelectorAll('pre').forEach(function (pre) {
      if (pre.querySelector('.club-copy-btn')) return;
      // Skip <pre> elements with no real code (e.g. ascii-art separators).
      var code = pre.querySelector('code') || pre;
      if (!code.textContent || !code.textContent.trim()) return;

      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'club-copy-btn';
      btn.setAttribute('aria-label', 'Copy code');
      renderBtnContent(btn, copyIcon, 'Copy');
      btn.addEventListener('click', function () {
        var text = code.textContent || '';
        var done = function () {
          btn.dataset.copied = 'true';
          renderBtnContent(btn, checkIcon, 'Copied');
          setTimeout(function () {
            btn.dataset.copied = 'false';
            renderBtnContent(btn, copyIcon, 'Copy');
          }, 1600);
        };
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(done, function () {});
        } else {
          var ta = document.createElement('textarea');
          ta.value = text;
          ta.style.position = 'fixed';
          ta.style.opacity = '0';
          document.body.appendChild(ta);
          ta.select();
          try { document.execCommand('copy'); done(); } catch (e) {}
          document.body.removeChild(ta);
        }
      });

      pre.classList.add('club-code-wrap');
      pre.appendChild(btn);
    });
  }

  // Mark the sidebar link whose href resolves to the current page.
  // location.pathname is percent-encoded ("Type-safe%20routes…"), but
  // sidebar hrefs are raw attribute strings with literal spaces. Decode
  // both sides to a canonical form before comparing.
  function decodeLeaf(s) {
    try { return decodeURIComponent(s); } catch (_) { return s; }
  }

  function markActiveSidebarLinks() {
    var sidebars = document.querySelectorAll(
      '#dartdoc-sidebar-left, #dartdoc-sidebar-right'
    );
    if (!sidebars.length) return;
    var current = decodeLeaf(location.pathname.split('/').pop() || 'index.html');
    sidebars.forEach(function (sb) {
      sb.querySelectorAll('a.club-active').forEach(function (el) {
        el.classList.remove('club-active');
      });
      sb.querySelectorAll('a[href]').forEach(function (a) {
        var href = a.getAttribute('href');
        if (!href || href.startsWith('#') || /^https?:/.test(href)) return;
        var leaf = decodeLeaf(href.split('#')[0].split('?')[0].split('/').pop());
        if (!leaf) return;
        if (
          leaf === current ||
          (current === '' && leaf === 'index.html') ||
          (current === 'index.html' && href === './')
        ) {
          a.classList.add('club-active');
        }
      });
    });
  }

  // dartdoc rewrites #dartdoc-sidebar-left-content async on some pages
  // (the package nav). Re-run our markup pass when that container changes.
  function watchSidebars() {
    var hosts = [
      document.getElementById('dartdoc-sidebar-left-content'),
      document.getElementById('dartdoc-sidebar-right'),
    ].filter(Boolean);
    hosts.forEach(function (host) {
      var mo = new MutationObserver(function () {
        markActiveSidebarLinks();
      });
      mo.observe(host, { childList: true, subtree: true });
    });
  }

  function init() {
    setPlaceholders();
    addCopyButtons();
    markActiveSidebarLinks();
    watchSidebars();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
''';

const _clubLogoSvg =
    '<svg width="690" height="690" viewBox="0 0 690 690" fill="none" '
    'xmlns="http://www.w3.org/2000/svg">'
    '<path d="M345 0C535.538 0 690 154.462 690 345C690 535.538 535.538 690 345 '
    '690C154.462 690 0 535.538 0 345C0 154.462 154.462 0 345 0ZM344.948 '
    '141.667C327.692 141.667 310.766 146.4 296.013 155.352C281.26 164.303 '
    '269.244 177.13 261.274 192.437C253.305 207.743 249.687 224.942 250.813 '
    '242.161C251.94 259.381 257.769 275.961 267.664 290.099C250.083 284.554 '
    '231.262 284.284 213.528 289.322C195.795 294.36 179.927 304.486 167.888 '
    '318.446C155.848 332.407 148.164 349.591 145.787 367.872C143.41 386.153 '
    '146.444 404.73 154.513 421.306C162.582 437.881 175.332 451.728 191.187 '
    '461.134C207.042 470.54 225.306 475.092 243.721 474.228C262.136 473.363 '
    '279.893 467.12 294.798 456.271C309.702 445.421 321.099 430.441 327.58 '
    '413.183C327.652 475.275 323.669 516.568 264.765 547.755H425.141C366.236 '
    '516.559 362.253 475.257 362.325 413.183C370.081 433.881 384.858 451.2 '
    '404.079 462.115C423.3 473.031 445.744 476.85 467.493 472.907C489.243 '
    '468.964 508.917 457.508 523.082 440.54C537.248 423.572 545.005 402.168 '
    '545 380.063C544.993 365.242 541.495 350.631 534.79 337.413C528.085 '
    '324.195 518.361 312.742 506.406 303.981C494.451 295.221 480.601 289.399 '
    '465.978 286.987C451.354 284.575 436.367 285.641 422.232 290.099C432.128 '
    '275.961 437.956 259.381 439.083 242.161C440.21 224.942 436.591 207.743 '
    '428.622 192.437C420.653 177.13 408.637 164.303 393.884 155.352C379.131 '
    '146.4 362.205 141.667 344.948 141.667Z" fill="#FE4F17"/>'
    '</svg>\n';
