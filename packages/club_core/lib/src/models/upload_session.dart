import 'package:equatable/equatable.dart';

class UploadSession extends Equatable {
  const UploadSession({
    required this.id,
    required this.userId,
    required this.tempPath,
    required this.state,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String userId;
  final String tempPath;
  final UploadState state;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  @override
  List<Object?> get props => [id];
}

enum UploadState {
  pending,
  received,
  processing,
  complete,
  failed
  ;

  static UploadState fromString(String value) => UploadState.values.firstWhere(
    (e) => e.name == value,
    orElse: () => throw ArgumentError('Invalid upload state: $value'),
  );
}

class UploadSessionCompanion {
  const UploadSessionCompanion({
    required this.id,
    required this.userId,
    required this.tempPath,
    required this.expiresAt,
  });

  final String id;
  final String userId;
  final String tempPath;
  final DateTime expiresAt;
}
