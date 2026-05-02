import 'package:pub_semver/pub_semver.dart';

/// Derives SDK, platform, and capability tags from a pubspec map and
/// source-level import information, matching pana's tag vocabulary as
/// closely as possible without running full transitive static analysis.
///
/// These tags are a publish-time best-effort fallback. When pana runs on
/// the package later, [mergeWithPana] replaces our heuristic answers in
/// pana's authoritative namespaces (`sdk:`, `platform:`, `runtime:`,
/// `is:`, `license:`, `topic:`) with pana's tags. Club-only namespaces
/// (e.g. `has:build-hooks`) are never replaced — pana doesn't analyze
/// them.
///
/// Tag format follows pub.dev / pana conventions:
///   SDK:        `sdk:dart`, `sdk:flutter`
///   Platform:   `platform:android`, `platform:ios`, `platform:linux`,
///               `platform:macos`, `platform:web`, `platform:windows`
///   Capability: `is:wasm-ready`, `is:plugin`, `is:dart3-compatible`
///   Club-only:  `has:build-hooks`
class TagDerivation {
  const TagDerivation._();

  static const _allPlatforms = [
    'android',
    'ios',
    'linux',
    'macos',
    'web',
    'windows',
  ];

  static const _nativePlatforms = [
    'android',
    'ios',
    'linux',
    'macos',
    'windows',
  ];

  /// `dart:` libraries available under the wasm runtime, mirrored from
  /// `pana`'s `Runtime.wasm` allowlist (lib/src/tag/_specs.dart). Any
  /// import outside this set blocks the `is:wasm-ready` tag.
  static const _wasmAllowedDartLibs = <String>{
    // Platform-agnostic core (always available everywhere)
    'async', 'collection', 'convert', 'core', 'developer', 'math',
    'typed_data', '_internal',
    // Wasm-specific extras
    'ui', 'ui_web', 'js_interop', 'js_interop_unsafe',
  };

  /// Tag namespaces where pana's analysis is authoritative. When pana
  /// runs, [mergeWithPana] drops our publish-time tags in these
  /// namespaces and substitutes pana's. Anything outside this set
  /// (notably `has:`) is additive — both producers contribute, deduped.
  static const _panaAuthoritativePrefixes = <String>{
    'sdk:',
    'platform:',
    'runtime:',
    'is:',
    'license:',
    'topic:',
  };

  /// Derive all tags for a package version.
  ///
  /// [pubspec] is the parsed pubspec.yaml map.
  /// [dartImports] is the set of `dart:xxx` library names found in source
  /// files (e.g. `{'io', 'convert', 'async'}`).
  /// [hasBuildHooks] is true when the archive contains any `hook/*.dart`
  /// file (Dart Build hooks). Surfaced as the `has:build-hooks` tag.
  static List<String> deriveTags(
    Map<String, dynamic> pubspec, {
    Set<String> dartImports = const {},
    bool hasBuildHooks = false,
  }) {
    return [
      ...deriveSdkTags(pubspec),
      ...derivePlatformTags(pubspec, dartImports: dartImports),
      ...deriveCapabilityTags(pubspec, dartImports: dartImports),
      if (hasBuildHooks) 'has:build-hooks',
    ];
  }

  /// Derive SDK tags from the pubspec.
  ///
  /// A package is treated as Flutter-only (tag: `sdk:flutter`) if any of:
  ///   1. `environment.flutter` constraint is set
  ///   2. `flutter` appears in `dependencies` (typically `sdk: flutter`)
  ///   3. A top-level `flutter:` key is present
  ///
  /// Otherwise it is pure Dart, which also runs under Flutter, so it gets
  /// both `sdk:dart` and `sdk:flutter`.
  static List<String> deriveSdkTags(Map<String, dynamic> pubspec) {
    final env = pubspec['environment'];
    final hasFlutterEnv = env is Map && env['flutter'] != null;

    final deps = pubspec['dependencies'];
    final hasFlutterDep = deps is Map && deps.containsKey('flutter');

    final hasFlutterTopLevel = pubspec['flutter'] != null;

    if (hasFlutterEnv || hasFlutterDep || hasFlutterTopLevel) {
      return ['sdk:flutter'];
    }

    return ['sdk:dart', 'sdk:flutter'];
  }

  /// Derive platform tags from pubspec declarations and source imports.
  ///
  /// Priority order (matching pub.dev / pana):
  /// 1. Explicit `platforms` field in pubspec → use exactly those
  /// 2. Flutter plugin `flutter.plugin.platforms` → use those platform keys
  /// 3. Default: all platforms, narrowed by dart: import analysis
  static List<String> derivePlatformTags(
    Map<String, dynamic> pubspec, {
    Set<String> dartImports = const {},
  }) {
    // 1. Check for explicit `platforms` declaration
    final platforms = pubspec['platforms'];
    if (platforms is Map && platforms.isNotEmpty) {
      return _filterValidPlatforms(platforms.keys.cast<String>());
    }

    // 2. Check for Flutter plugin platform declarations
    final flutter = pubspec['flutter'];
    if (flutter is Map) {
      final plugin = flutter['plugin'];
      if (plugin is Map) {
        final pluginPlatforms = plugin['platforms'];
        if (pluginPlatforms is Map && pluginPlatforms.isNotEmpty) {
          return _filterValidPlatforms(pluginPlatforms.keys.cast<String>());
        }
      }
    }

    // 3. Derive from imports
    return _deriveFromImports(pubspec, dartImports);
  }

  /// Derive platforms based on dart: imports when no explicit platform
  /// declaration exists.
  static List<String> _deriveFromImports(
    Map<String, dynamic> pubspec,
    Set<String> dartImports,
  ) {
    final usesDartIO = dartImports.contains('io');
    final usesDartHtml = dartImports.contains('html');
    final usesDartFfi = dartImports.contains('ffi');
    final usesDartJsInterop =
        dartImports.contains('js_interop') ||
        dartImports.contains('js_interop_unsafe');

    // dart:html or dart:js_interop without dart:io → web only
    if ((usesDartHtml || usesDartJsInterop) && !usesDartIO) {
      return ['platform:web'];
    }

    // dart:io or dart:ffi → native only (no web)
    if (usesDartIO || usesDartFfi) {
      return _nativePlatforms.map((p) => 'platform:$p').toList();
    }

    // No platform-specific imports → all platforms
    return _allPlatforms.map((p) => 'platform:$p').toList();
  }

  /// Filter and prefix valid platform names.
  static List<String> _filterValidPlatforms(Iterable<String> platforms) {
    return platforms
        .map((p) => p.toLowerCase().trim())
        .where(_allPlatforms.contains)
        .map((p) => 'platform:$p')
        .toList();
  }

  /// Derive capability `is:*` tags that pana also produces:
  /// `is:wasm-ready`, `is:plugin`, `is:dart3-compatible`. These are
  /// best-effort heuristics — pana's transitive analysis is the source
  /// of truth and overrides via [mergeWithPana] when scoring runs.
  static List<String> deriveCapabilityTags(
    Map<String, dynamic> pubspec, {
    Set<String> dartImports = const {},
  }) {
    return [
      if (_isWasmReady(dartImports)) 'is:wasm-ready',
      if (_isPlugin(pubspec)) 'is:plugin',
      if (_isDart3Compatible(pubspec)) 'is:dart3-compatible',
    ];
  }

  /// Heuristic wasm-ready: package's own `dart:*` imports are all in the
  /// wasm runtime allowlist AND there's at least one such import. The
  /// non-empty requirement avoids tagging every pure-data package that
  /// imports nothing — pana's transitive walk would still consider its
  /// dependencies, which we can't see at publish time. False negative
  /// for genuinely zero-dep packages, corrected by pana when it runs.
  static bool _isWasmReady(Set<String> dartImports) {
    if (dartImports.isEmpty) return false;
    return dartImports.every(_wasmAllowedDartLibs.contains);
  }

  /// A package is a Flutter plugin iff `flutter.plugin` is a map.
  /// Matches pana's `is:plugin` exactly (no transitive analysis needed).
  static bool _isPlugin(Map<String, dynamic> pubspec) {
    final flutter = pubspec['flutter'];
    if (flutter is! Map) return false;
    return flutter['plugin'] is Map;
  }

  /// Heuristic Dart-3 compatible: `environment.sdk` constraint admits at
  /// least one version `>=3.0.0`. Pana refines this with package-graph
  /// analysis (a dep with a `<3.0.0` upper bound disqualifies the
  /// package) — that correction lands via [mergeWithPana].
  static bool _isDart3Compatible(Map<String, dynamic> pubspec) {
    final env = pubspec['environment'];
    if (env is! Map) return false;
    final sdk = env['sdk'];
    if (sdk is! String) return false;
    try {
      final constraint = VersionConstraint.parse(sdk);
      return constraint.allows(Version(3, 0, 0));
    } on FormatException {
      return false;
    }
  }

  /// Merge publish-time tags ([ours]) with pana-emitted tags ([panaTags]).
  ///
  /// Within [_panaAuthoritativePrefixes] (`sdk:`, `platform:`, `runtime:`,
  /// `is:`, `license:`, `topic:`), pana's set replaces ours wholesale —
  /// pana's omission is meaningful (e.g. no `is:wasm-ready` from pana
  /// means "checked transitively, the answer is no", which should win
  /// over a heuristic false positive). Outside those namespaces the two
  /// sets are unioned, so club-only tags like `has:build-hooks` survive
  /// alongside pana's `has:executable`/`has:screenshot`/`has:error`.
  ///
  /// When [panaTags] is empty (scoring disabled, in-flight, or failed),
  /// returns [ours] unchanged.
  static List<String> mergeWithPana(
    List<String> ours,
    List<String> panaTags,
  ) {
    if (panaTags.isEmpty) return List<String>.from(ours);
    final merged = <String>{
      ...ours.where(
        (t) => !_panaAuthoritativePrefixes.any((p) => t.startsWith(p)),
      ),
      ...panaTags,
    };
    return merged.toList();
  }
}
