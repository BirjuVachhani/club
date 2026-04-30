import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'publisher.g.dart';

@JsonSerializable()
class Publisher extends Equatable {
  const Publisher({
    required this.id,
    required this.displayName,
    this.description,
    this.websiteUrl,
    this.contactEmail,
    this.verified = false,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Publisher.fromJson(Map<String, dynamic> json) =>
      _$PublisherFromJson(json);

  final String id;
  final String displayName;
  final String? description;
  final String? websiteUrl;
  final String? contactEmail;

  /// True when the id was proven via DNS TXT verification. Verified
  /// publishers always have a dot in their id (a domain); unverified
  /// publishers never do.
  final bool verified;

  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => _$PublisherToJson(this);

  @override
  List<Object?> get props => [id];
}

class PublisherCompanion {
  const PublisherCompanion({
    required this.id,
    required this.displayName,
    this.description,
    this.websiteUrl,
    this.contactEmail,
    this.verified = false,
    required this.createdBy,
  });

  final String id;
  final String displayName;
  final String? description;
  final String? websiteUrl;
  final String? contactEmail;
  final bool verified;
  final String createdBy;
}
