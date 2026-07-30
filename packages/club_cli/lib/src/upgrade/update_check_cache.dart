/// Remembers the last update check so the CLI does not hit the GitHub API
/// on every invocation.
///
/// This is a cache, never a receipt. It records only what to *tell* the
/// user, never how to upgrade them: install-method detection stays purely
/// path-based so it keeps working for everyone who installed before this
/// file existed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../util/paths.dart';

/// How long a check stays fresh.
const updateCheckInterval = Duration(hours: 24);

/// A previously recorded check.
class UpdateCheckRecord {
  const UpdateCheckRecord({required this.checkedAt, required this.latest});

  final DateTime checkedAt;

  /// The newest *installable* version seen, or null when the check ran and
  /// found nothing worth recording. Storing the gated result rather than
  /// the raw tag is what stops the hint advertising a version that
  /// `club upgrade` would then refuse.
  final String? latest;

  bool isFreshAt(DateTime now) =>
      now.difference(checkedAt).abs() < updateCheckInterval;
}

/// Reads and writes the update-check cache.
///
/// Every method is best effort. A corrupt file, a read-only home
/// directory, or a clock that jumped should degrade to "check again",
/// never to an error on an unrelated command.
class UpdateCheckCache {
  UpdateCheckCache({String? path})
      : _path = path ?? p.join(clubConfigDir(), 'update_check.json');

  final String _path;

  UpdateCheckRecord? read() {
    try {
      final file = File(_path);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;

      final checkedAt = DateTime.tryParse(decoded['checkedAt'] as String? ?? '');
      if (checkedAt == null) return null;

      final latest = decoded['latest'];
      return UpdateCheckRecord(
        checkedAt: checkedAt,
        latest: latest is String && latest.isNotEmpty ? latest : null,
      );
    } on Object {
      // Corrupt JSON, a permissions change, a directory where the file
      // should be. All of them mean the same thing: no usable record.
      return null;
    }
  }

  void write(UpdateCheckRecord record) {
    try {
      final file = File(_path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'checkedAt': record.checkedAt.toUtc().toIso8601String(),
          'latest': record.latest,
        }),
      );
    } on Object {
      // A read-only home should mean "check every run", not a failure on
      // whatever command the user actually asked for.
    }
  }
}
