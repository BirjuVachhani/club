// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'success_message.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SuccessMessage _$SuccessMessageFromJson(Map<String, dynamic> json) =>
    SuccessMessage(
      success: Message.fromJson(json['success'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$SuccessMessageToJson(SuccessMessage instance) =>
    <String, dynamic>{'success': instance.success};

Message _$MessageFromJson(Map<String, dynamic> json) =>
    Message(message: json['message'] as String);

Map<String, dynamic> _$MessageToJson(Message instance) => <String, dynamic>{
  'message': instance.message,
};

ErrorResponse _$ErrorResponseFromJson(Map<String, dynamic> json) =>
    ErrorResponse(
      error: ErrorDetail.fromJson(json['error'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$ErrorResponseToJson(ErrorResponse instance) =>
    <String, dynamic>{'error': instance.error};

ErrorDetail _$ErrorDetailFromJson(Map<String, dynamic> json) => ErrorDetail(
  code: json['code'] as String,
  message: json['message'] as String,
);

Map<String, dynamic> _$ErrorDetailToJson(ErrorDetail instance) =>
    <String, dynamic>{'code': instance.code, 'message': instance.message};
