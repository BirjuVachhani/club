import 'package:json_annotation/json_annotation.dart';

part 'success_message.g.dart';

/// Standard success response for the pub API.
@JsonSerializable()
class SuccessMessage {
  const SuccessMessage({required this.success});

  factory SuccessMessage.fromJson(Map<String, dynamic> json) =>
      _$SuccessMessageFromJson(json);

  final Message success;

  Map<String, dynamic> toJson() => _$SuccessMessageToJson(this);
}

@JsonSerializable()
class Message {
  const Message({required this.message});

  factory Message.fromJson(Map<String, dynamic> json) =>
      _$MessageFromJson(json);

  final String message;

  Map<String, dynamic> toJson() => _$MessageToJson(this);
}

/// Standard error response for the pub API.
@JsonSerializable()
class ErrorResponse {
  const ErrorResponse({required this.error});

  factory ErrorResponse.fromJson(Map<String, dynamic> json) =>
      _$ErrorResponseFromJson(json);

  final ErrorDetail error;

  Map<String, dynamic> toJson() => _$ErrorResponseToJson(this);
}

@JsonSerializable()
class ErrorDetail {
  const ErrorDetail({required this.code, required this.message});

  factory ErrorDetail.fromJson(Map<String, dynamic> json) =>
      _$ErrorDetailFromJson(json);

  final String code;
  final String message;

  Map<String, dynamic> toJson() => _$ErrorDetailToJson(this);
}
