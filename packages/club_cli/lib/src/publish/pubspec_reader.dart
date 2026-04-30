/// Reads and parses `pubspec.yaml` for the publish flow.
///
/// Mirrors the role of dart pub's
/// [`pubspec_parse.dart`](https://github.com/dart-lang/pub/blob/master/lib/src/pubspec_parse.dart).
/// We rely on the official `pubspec_parse` package for correctness so we
/// match dart pub's interpretation exactly, then expose the few extra bits
/// (raw map, raw YAML) that the validators need.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:yaml/yaml.dart';

/// Sentinel value `publish_to: none` uses to mean "private package".
///
/// Matches dart pub semantics: when `publish_to` is `none` the package is
/// private and `dart pub publish` refuses. The club CLI overrides this
/// behaviour and treats `none` the same as "publish_to is missing" — falling
/// back to the configured login(s).
const String publishToNone = 'none';

/// Wraps the parsed pubspec plus the original YAML for downstream tooling.
class PackagePubspec {
  PackagePubspec({
    required this.directory,
    required this.parsed,
    required this.rawYaml,
    required this.rawMap,
    this.versionOverride,
  });

  /// Absolute path to the package root (the directory containing pubspec.yaml).
  final String directory;

  /// Strongly-typed representation from `pubspec_parse`.
  final Pubspec parsed;

  /// Raw YAML text (preserved for hash / archiving / diagnostics).
  final String rawYaml;

  /// Raw map representation (used by validators that need access to fields
  /// that `pubspec_parse` does not expose, such as `flutter.plugin.platforms`).
  final Map<String, dynamic> rawMap;

  /// When set, overrides the version from [parsed] for display, validation,
  /// and tarball rewriting — without modifying source files.
  final String? versionOverride;

  String get name => parsed.name;
  String get version => versionOverride ?? (parsed.version?.toString() ?? '');
  String? get description => parsed.description;
  String? get homepage => parsed.homepage;
  String? get repository => parsed.repository?.toString();
  String? get publishTo => parsed.publishTo;

  /// True if `publish_to: none` was set (the dart pub "private" flag).
  bool get isPrivate => publishTo == publishToNone;

  /// Value of the `resolution:` field, if present.
  ///
  /// Workspace members are identified by `resolution: workspace`. See
  /// https://dart.dev/tools/pub/workspaces.
  String? get resolution => parsed.resolution;

  /// True if this package is a workspace member (`resolution: workspace`).
  bool get isWorkspaceMember => resolution == 'workspace';

  /// Entries of the `workspace:` field when this pubspec is a workspace root.
  List<String> get workspace => parsed.workspace ?? const [];
}

/// Read the pubspec from [packageDir] and return a [PackagePubspec].
///
/// Throws [FormatException] for invalid YAML or pubspec field types and
/// [FileSystemException] if the file does not exist.
PackagePubspec readPubspec(String packageDir, {String? versionOverride}) {
  final pubspecFile = File(p.join(packageDir, 'pubspec.yaml'));
  if (!pubspecFile.existsSync()) {
    throw FileSystemException(
      'No pubspec.yaml found in $packageDir',
      pubspecFile.path,
    );
  }

  return parsePubspec(
    packageDir,
    pubspecFile.readAsStringSync(),
    versionOverride: versionOverride,
    sourceUri: pubspecFile.uri,
  );
}

/// Parse [raw] as the pubspec for [packageDir] without touching the
/// filesystem. Used by `club publish --auto`: the runner computes a
/// rewritten pubspec in memory and feeds it here so the validators and
/// tarball builder see the post-rewrite shape, while the on-disk source
/// stays unchanged.
PackagePubspec parsePubspec(
  String packageDir,
  String raw, {
  String? versionOverride,
  Uri? sourceUri,
}) {
  final Pubspec parsed;
  try {
    parsed = Pubspec.parse(raw, sourceUrl: sourceUri);
  } on Exception catch (e) {
    throw FormatException('Invalid pubspec.yaml: $e');
  }

  final yamlNode = loadYaml(raw, sourceUrl: sourceUri);
  final rawMap = _yamlToDart(yamlNode) as Map<String, dynamic>;

  if (versionOverride != null) {
    rawMap['version'] = versionOverride;
  }

  return PackagePubspec(
    directory: p.absolute(packageDir),
    parsed: parsed,
    rawYaml: raw,
    rawMap: rawMap,
    versionOverride: versionOverride,
  );
}

/// Recursively convert a YamlNode tree to plain Dart Maps/Lists/scalars.
///
/// Required because YamlMap.toJson() does not deep-convert nested YamlLists.
Object? _yamlToDart(Object? node) {
  if (node is YamlMap) {
    return <String, dynamic>{
      for (final entry in node.entries)
        entry.key.toString(): _yamlToDart(entry.value),
    };
  }
  if (node is YamlList) {
    return [for (final item in node) _yamlToDart(item)];
  }
  return node;
}

/// Encode a map as compact JSON (used when computing stable hashes of the
/// pubspec for diagnostics).
String jsonEncodePubspec(Map<String, dynamic> map) => jsonEncode(map);
