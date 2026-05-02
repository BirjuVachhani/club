// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'package_dartdoc_status.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PackageDartdocStatus _$PackageDartdocStatusFromJson(
  Map<String, dynamic> json,
) => PackageDartdocStatus(
  status: json['status'] as String,
  version: json['version'] as String?,
  generatedAt: json['generatedAt'] == null
      ? null
      : DateTime.parse(json['generatedAt'] as String),
  docsUrl: json['docsUrl'] as String?,
  errorMessage: json['errorMessage'] as String?,
);

Map<String, dynamic> _$PackageDartdocStatusToJson(
  PackageDartdocStatus instance,
) => <String, dynamic>{
  'status': instance.status,
  'version': instance.version,
  'generatedAt': instance.generatedAt?.toIso8601String(),
  'docsUrl': instance.docsUrl,
  'errorMessage': instance.errorMessage,
};
