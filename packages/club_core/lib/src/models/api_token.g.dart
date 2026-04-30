// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'api_token.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ApiToken _$ApiTokenFromJson(Map<String, dynamic> json) => ApiToken(
  tokenId: json['tokenId'] as String,
  userId: json['userId'] as String,
  kind: $enumDecode(_$ApiTokenKindEnumMap, json['kind']),
  name: json['name'] as String,
  prefix: json['prefix'] as String,
  scopes: (json['scopes'] as List<dynamic>).map((e) => e as String).toList(),
  createdAt: DateTime.parse(json['createdAt'] as String),
  expiresAt: json['expiresAt'] == null
      ? null
      : DateTime.parse(json['expiresAt'] as String),
  absoluteExpiresAt: json['absoluteExpiresAt'] == null
      ? null
      : DateTime.parse(json['absoluteExpiresAt'] as String),
  userAgent: json['userAgent'] as String?,
  clientIp: json['clientIp'] as String?,
  clientCity: json['clientCity'] as String?,
  clientRegion: json['clientRegion'] as String?,
  clientCountry: json['clientCountry'] as String?,
  clientCountryCode: json['clientCountryCode'] as String?,
  lastUsedAt: json['lastUsedAt'] == null
      ? null
      : DateTime.parse(json['lastUsedAt'] as String),
  revokedAt: json['revokedAt'] == null
      ? null
      : DateTime.parse(json['revokedAt'] as String),
);

Map<String, dynamic> _$ApiTokenToJson(ApiToken instance) => <String, dynamic>{
  'tokenId': instance.tokenId,
  'userId': instance.userId,
  'kind': _$ApiTokenKindEnumMap[instance.kind]!,
  'name': instance.name,
  'prefix': instance.prefix,
  'scopes': instance.scopes,
  'createdAt': instance.createdAt.toIso8601String(),
  'expiresAt': instance.expiresAt?.toIso8601String(),
  'absoluteExpiresAt': instance.absoluteExpiresAt?.toIso8601String(),
  'userAgent': instance.userAgent,
  'clientIp': instance.clientIp,
  'clientCity': instance.clientCity,
  'clientRegion': instance.clientRegion,
  'clientCountry': instance.clientCountry,
  'clientCountryCode': instance.clientCountryCode,
  'lastUsedAt': instance.lastUsedAt?.toIso8601String(),
  'revokedAt': instance.revokedAt?.toIso8601String(),
};

const _$ApiTokenKindEnumMap = {
  ApiTokenKind.session: 'session',
  ApiTokenKind.pat: 'pat',
};
