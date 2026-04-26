/// Derives SDK and platform tags from a pubspec map and source-level import
/// information, matching the behaviour of pub.dev / pana as closely as
/// possible without running full static analysis.
///
/// Tag format follows pub.dev conventions:
///   SDK:      `sdk:dart`, `sdk:flutter`
///   Platform: `platform:android`, `platform:ios`, `platform:linux`,
///             `platform:macos`, `platform:web`, `platform:windows`
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

  /// Derive all tags for a package version.
  ///
  /// [pubspec] is the parsed pubspec.yaml map.
  /// [dartImports] is the set of `dart:xxx` library names found in source
  /// files (e.g. `{'io', 'convert', 'async'}`).
  static List<String> deriveTags(
    Map<String, dynamic> pubspec, {
    Set<String> dartImports = const {},
  }) {
    return [
      ...deriveSdkTags(pubspec),
      ...derivePlatformTags(pubspec, dartImports: dartImports),
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
}
