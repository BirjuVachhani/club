import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'publisher_member.g.dart';

@JsonSerializable()
class PublisherMember extends Equatable {
  const PublisherMember({
    required this.publisherId,
    required this.userId,
    required this.role,
    required this.createdAt,
  });

  factory PublisherMember.fromJson(Map<String, dynamic> json) =>
      _$PublisherMemberFromJson(json);

  final String publisherId;
  final String userId;
  final String role;
  final DateTime createdAt;

  bool get isAdmin => role == PublisherRole.admin;

  Map<String, dynamic> toJson() => _$PublisherMemberToJson(this);

  @override
  List<Object?> get props => [publisherId, userId];
}

class PublisherMemberCompanion {
  const PublisherMemberCompanion({
    required this.publisherId,
    required this.userId,
    required this.role,
  });

  final String publisherId;
  final String userId;
  final String role;
}

abstract final class PublisherRole {
  static const String admin = 'admin';
  static const String member = 'member';
  static const List<String> all = [admin, member];
  static bool isValid(String role) => all.contains(role);
}
