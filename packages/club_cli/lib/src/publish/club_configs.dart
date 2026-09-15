import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:yaml/yaml.dart';
import 'package:club_api/club_api.dart' show isValidSiteUrl;

part 'club_configs.g.dart';

/// Represents the structure and data of club.yaml.
/// club.yaml file defines various configurations for club CLI.
@JsonSerializable()
class ClubConfigs extends Equatable {
  @JsonKey(fromJson: _sitesFromJson, toJson: _sitesToJson)
  final List<SiteTarget> sites;

  factory ClubConfigs.fromJson(Map<String, dynamic> json) =>
      _$ClubConfigsFromJson(json);

  Map<String, dynamic> toJson() => _$ClubConfigsToJson(this);

  /// Reads named targets from YAML. Null means sites were not declared.
  static ClubConfigs? fromYaml(String source) {
    final document = loadYaml(source);
    if (document == null) return null;
    if (document is! Map) {
      throw const FormatException('club.yaml must contain a mapping.');
    }
    if (!document.containsKey('sites')) return null;
    final targets = document['sites'];
    if (targets is! Map) {
      throw const FormatException('club.yaml sites must be a mapping.');
    }
    final names = <String>{};
    final sites = <SiteTarget>[];
    for (final entry in targets.entries) {
      final name = entry.key;
      if (name is! String ||
          name.length > 128 ||
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(name)) {
        throw FormatException('Invalid site name: $name.');
      }
      if (!names.add(name.toLowerCase())) {
        throw FormatException('Duplicate site name: $name.');
      }
      final target = entry.value;
      if (target is! Map) {
        throw FormatException('Site "$name" must contain a mapping.');
      }
      for (final key in target.keys) {
        if (key != 'output' &&
            key != 'build' &&
            key != 'url' &&
            key != 'label') {
          throw FormatException('Unknown field "$key" in site "$name".');
        }
      }
      final label = target['label'];
      if (label != null &&
          (label is! String || label.trim().isEmpty || label.length > 200)) {
        throw FormatException(
          'Site "$name" label must be nonblank and at most 200 characters.',
        );
      }
      if (target.containsKey('url')) {
        final url = target['url'];
        if (url is! String ||
            !isValidSiteUrl(url) ||
            target.containsKey('output') ||
            target.containsKey('build')) {
          throw FormatException(
            'Site "$name" requires an absolute HTTP/HTTPS url without build or output.',
          );
        }
        sites.add(SiteTarget(name: name, url: url, label: label as String?));
        continue;
      }
      final output = target['output'];
      if (output is! String ||
          output.trim().isEmpty ||
          output.contains('\x00')) {
        throw FormatException('Site "$name" requires a nonblank output path.');
      }
      final build = target['build'];
      if (build != null && build is! String) {
        throw FormatException('Site "$name" build must be a string.');
      }
      sites.add(
        SiteTarget(
          name: name,
          output: output,
          build: build as String?,
          label: label as String?,
        ),
      );
    }
    return ClubConfigs(sites: sites);
  }

  ClubConfigs({required this.sites});

  @override
  List<Object?> get props => [sites];
}

/// A site target in `sites` in club.yaml
/// This defines a site target that would be available as a site at
/// host/packages/package_name/site/site_name.
/// e.g. https://myclub.example.com/packages/my_package/site/demo.
@JsonSerializable()
class SiteTarget extends Equatable {
  /// Name of the site. This also acts as its identifier.
  /// Demo is a default name. This becomes path for this site.
  ///   e.g. https://myclub.example.com/packages/my_package/site/demo
  ///   Where, thinking_orbs is package name and /demo is this site.
  ///   /site is internal path prefix to identify all sites and route them to site handler.
  /// Validations:
  ///   - Must not be blank
  ///   - no spaces.
  ///   - Must start with a letter or alphabet.
  ///   - Must only contain [a-zA-Z0-9_-].
  final String name;

  /// Build command to build the site.
  /// This is optional. If provided then, it must be ran before archiving.
  /// If execution of build command fails then the process is aborted.
  final String? build;

  /// Output directory of the site. This is where the site files will be.
  /// This is required. This gets archived as tar.gz and uploaded to the club server.
  /// If [build] is provided then it will be ran before archiving.
  /// Ensure it outputs in the [output] directory.
  ///
  /// If [build] is not provided then this directory must exist.
  /// Validations:
  ///   - Either an absolute path or a relative path from package root.
  ///   - Must not be blank.
  ///   - Must be a valid path.
  ///   - Must exist. Must be a directory path.
  ///   - Directory Must contain an index.html file in the root.
  final String? output;

  /// External site destination, mutually exclusive with build and output.
  final String? url;

  /// Display text; defaults to the target name when omitted.
  final String? label;

  bool get requiresBuild => build != null && build!.trim().isNotEmpty;

  SiteTarget({
    required this.name,
    this.build,
    this.output,
    this.url,
    this.label,
  });

  factory SiteTarget.fromJson(Map<String, dynamic> json) =>
      _$SiteTargetFromJson(json);

  Map<String, dynamic> toJson() => _$SiteTargetToJson(this);

  SiteTarget copyWith({
    String? name,
    String? build,
    String? output,
    String? url,
    String? label,
  }) => SiteTarget(
    name: name ?? this.name,
    build: build ?? this.build,
    output: output ?? this.output,
    url: url ?? this.url,
    label: label ?? this.label,
  );

  @override
  List<Object?> get props => [name, build, output, url, label];
}

List<SiteTarget> _sitesFromJson(Map<String, dynamic> sites) => [
  for (final entry in sites.entries)
    SiteTarget.fromJson({
      ...Map<String, dynamic>.from(entry.value as Map),
      'name': entry.key,
    }),
];

Map<String, dynamic> _sitesToJson(List<SiteTarget> sites) => {
  for (final site in sites)
    site.name: {
      if (site.build != null) 'build': site.build,
      if (site.output != null) 'output': site.output,
      if (site.url != null) 'url': site.url,
      if (site.label != null) 'label': site.label,
    },
};
