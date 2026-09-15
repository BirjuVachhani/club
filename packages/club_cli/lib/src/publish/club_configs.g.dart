// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'club_configs.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ClubConfigs _$ClubConfigsFromJson(Map<String, dynamic> json) =>
    ClubConfigs(sites: _sitesFromJson(json['sites'] as Map<String, dynamic>));

Map<String, dynamic> _$ClubConfigsToJson(ClubConfigs instance) =>
    <String, dynamic>{'sites': _sitesToJson(instance.sites)};

SiteTarget _$SiteTargetFromJson(Map<String, dynamic> json) => SiteTarget(
  name: json['name'] as String,
  build: json['build'] as String?,
  output: json['output'] as String?,
  url: json['url'] as String?,
  label: json['label'] as String?,
);

Map<String, dynamic> _$SiteTargetToJson(SiteTarget instance) =>
    <String, dynamic>{
      'name': instance.name,
      'build': instance.build,
      'output': instance.output,
      'url': instance.url,
      'label': instance.label,
    };
