/// Parses `[<section>:]<package>[:<descriptor>]` tokens.
///
/// Matches the grammar documented in `dart pub add --help`:
///   foo                                          → hosted, ^latest
///   dev:foo                                      → dev_dependencies
///   override:foo                                 → dependency_overrides
///   foo:^1.2.3                                   → explicit constraint
///   foo:{hosted: https://my-pub.dev}             → hosted pin
///   foo:{hosted: https://..., version: ^1.0.0}   → hosted pin + constraint
///
/// `path`, `git`, and `sdk` descriptors are intentionally rejected in v1 —
/// `club add` is scoped to hosted dependencies. Users wanting those sources
/// should fall back to `dart pub add`.
library;

import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:yaml/yaml.dart';

import '../util/url.dart';
import 'add_options.dart';

/// Thrown for invalid descriptor syntax or unsupported sources.
class DescriptorParseError implements Exception {
  DescriptorParseError(this.message, [this.hint]);
  final String message;
  final String? hint;
  @override
  String toString() => message;
}

/// Parse every positional arg from the command line into an [AddRequest].
List<AddRequest> parseDescriptors(List<String> args) {
  if (args.isEmpty) {
    throw DescriptorParseError(
      'Provide at least one package to add.',
      'Example: club add my_package',
    );
  }
  return [for (final a in args) _parseOne(a)];
}

AddRequest _parseOne(String input) {
  var rest = input.trim();
  if (rest.isEmpty) {
    throw DescriptorParseError('Empty package argument.');
  }

  // ── 1. Peel off a leading `dev:` / `override:` section prefix. ──────────
  var section = DepSection.dependencies;
  for (final prefix in const {
    'dev:': DepSection.devDependencies,
    'override:': DepSection.dependencyOverrides,
  }.entries) {
    if (rest.startsWith(prefix.key)) {
      section = prefix.value;
      rest = rest.substring(prefix.key.length);
      break;
    }
  }

  // ── 2. Split `<name>[:<descriptor>]` on the first colon that isn't ──────
  //    inside a brace block. A `{` opens an inline YAML descriptor that
  //    may contain its own colons (e.g. `{hosted: https://x}`), so the
  //    naive `split(':', 2)` is not enough.
  final splitIdx = _firstTopLevelColon(rest);
  final String name;
  String? descriptor;
  if (splitIdx < 0) {
    name = rest;
  } else {
    name = rest.substring(0, splitIdx);
    final after = rest.substring(splitIdx + 1).trim();
    descriptor = after.isEmpty ? null : after;
  }

  if (name.isEmpty) {
    throw DescriptorParseError('Empty package name in "$input".');
  }
  _validateName(name, input);

  if (descriptor == null) {
    return AddRequest(name: name, section: section);
  }

  // ── 3. Interpret the descriptor: YAML map vs. bare constraint. ──────────
  if (descriptor.startsWith('{')) {
    return _parseMapDescriptor(
      name: name,
      section: section,
      descriptor: descriptor,
      original: input,
    );
  }
  final semver.VersionConstraint constraint;
  try {
    constraint = semver.VersionConstraint.parse(descriptor);
  } on FormatException catch (e) {
    throw DescriptorParseError(
      'Invalid version constraint "$descriptor" in "$input": ${e.message}',
    );
  }
  return AddRequest(
    name: name,
    section: section,
    explicitConstraint: constraint,
    rawDescriptor: descriptor,
  );
}

AddRequest _parseMapDescriptor({
  required String name,
  required DepSection section,
  required String descriptor,
  required String original,
}) {
  final Object? parsed;
  try {
    parsed = loadYaml(descriptor);
  } on YamlException catch (e) {
    throw DescriptorParseError(
      'Invalid descriptor "$descriptor" in "$original": ${e.message}',
    );
  }
  if (parsed is! Map) {
    throw DescriptorParseError(
      'Descriptor "$descriptor" in "$original" must be a YAML map.',
    );
  }
  final map = Map<String, Object?>.fromEntries(
    parsed.entries.map((e) => MapEntry(e.key.toString(), e.value)),
  );

  for (final unsupported in const ['path', 'git', 'sdk']) {
    if (map.containsKey(unsupported)) {
      throw DescriptorParseError(
        '`club add` only supports hosted dependencies in this version '
            '(got `$unsupported` in "$original").',
        'Use `dart pub add "$original"` for $unsupported dependencies.',
      );
    }
  }

  if (!map.containsKey('hosted')) {
    throw DescriptorParseError(
      'Descriptor "$descriptor" in "$original" has no `hosted` key.',
      'Supported shape: foo:{hosted: myclub.birju.dev} or '
          'foo:{hosted: myclub.birju.dev, version: ^1.0.0}.',
    );
  }

  final hostedNode = map['hosted'];
  final String hostedUrl;
  if (hostedNode is String) {
    hostedUrl = hostedNode;
  } else if (hostedNode is Map) {
    final url = hostedNode['url'];
    if (url is! String) {
      throw DescriptorParseError(
        '`hosted.url` must be a string in "$original".',
      );
    }
    hostedUrl = url;
  } else {
    throw DescriptorParseError(
      '`hosted` must be a host or URL string, or a map with `url:`, '
          'in "$original".',
    );
  }

  semver.VersionConstraint? constraint;
  final versionNode = map['version'];
  if (versionNode is String) {
    try {
      constraint = semver.VersionConstraint.parse(versionNode);
    } on FormatException catch (e) {
      throw DescriptorParseError(
        'Invalid version "$versionNode" in "$original": ${e.message}',
      );
    }
  } else if (versionNode != null) {
    throw DescriptorParseError(
      '`version` must be a string in "$original".',
    );
  }

  return AddRequest(
    name: name,
    section: section,
    explicitConstraint: constraint,
    explicitHostedUrl: _normalizeUrl(hostedUrl),
    rawDescriptor: descriptor,
  );
}

/// Find the index of the first `:` that is not nested inside `{...}`.
/// Returns -1 if there is none.
int _firstTopLevelColon(String s) {
  var depth = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '{') depth++;
    if (c == '}') depth--;
    if (c == ':' && depth == 0) return i;
  }
  return -1;
}

/// Match dart pub's accepted package-name shape.
/// (Letters, digits, underscores; starts with a letter or underscore.)
void _validateName(String name, String input) {
  final re = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');
  if (!re.hasMatch(name)) {
    throw DescriptorParseError(
      'Invalid package name "$name" in "$input".',
    );
  }
}

String _normalizeUrl(String url) => parseServerInput(url);
