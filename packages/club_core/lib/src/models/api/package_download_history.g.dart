// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'package_download_history.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DownloadWeek _$DownloadWeekFromJson(Map<String, dynamic> json) => DownloadWeek(
  weekStart: json['weekStart'] as String,
  weekLabel: json['weekLabel'] as String,
  total: (json['total'] as num).toInt(),
  byVersion: Map<String, int>.from(json['byVersion'] as Map),
);

Map<String, dynamic> _$DownloadWeekToJson(DownloadWeek instance) =>
    <String, dynamic>{
      'weekStart': instance.weekStart,
      'weekLabel': instance.weekLabel,
      'total': instance.total,
      'byVersion': instance.byVersion,
    };

PackageDownloadHistory _$PackageDownloadHistoryFromJson(
  Map<String, dynamic> json,
) => PackageDownloadHistory(
  packageName: json['packageName'] as String,
  total30Days: (json['total30Days'] as num).toInt(),
  weeks: (json['weeks'] as List<dynamic>)
      .map((e) => DownloadWeek.fromJson(e as Map<String, dynamic>))
      .toList(),
);

Map<String, dynamic> _$PackageDownloadHistoryToJson(
  PackageDownloadHistory instance,
) => <String, dynamic>{
  'packageName': instance.packageName,
  'total30Days': instance.total30Days,
  'weeks': instance.weeks,
};
