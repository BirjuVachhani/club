/// Mirrors dart pub's
/// [`LeakDetectionValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/leak_detection.dart):
/// scans every text file in the archive for embedded credentials.
///
/// Patterns are intentionally conservative — false positives are worse than
/// false negatives because they block publishes.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'validator.dart';

class LeakDetectionValidator extends Validator {
  LeakDetectionValidator(super.context);

  static final List<({String label, RegExp pattern})> _patterns = [
    (label: 'AWS access key', pattern: RegExp(r'\bAKIA[0-9A-Z]{16}\b')),
    (label: 'Google API key', pattern: RegExp(r'\bAIza[0-9A-Za-z\-_]{35}\b')),
    (label: 'GitHub token', pattern: RegExp(r'\bghp_[A-Za-z0-9]{36}\b')),
    (
      label: 'private key block',
      pattern: RegExp(r'-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'),
    ),
    (
      label: 'Slack token',
      pattern: RegExp(r'\bxox[abprs]-[A-Za-z0-9-]{10,}\b'),
    ),
  ];

  static const _maxBytes = 1 * 1024 * 1024;

  @override
  String get name => 'LeakDetectionValidator';

  @override
  Future<void> validate() async {
    final dir = context.pubspec.directory;
    for (final rel in context.tarball.files) {
      final file = File(p.join(dir, rel));
      final stat = file.statSync();
      if (stat.size > _maxBytes) continue;

      final String body;
      try {
        body = file.readAsStringSync();
      } catch (_) {
        continue; // binary file
      }

      for (final entry in _patterns) {
        if (entry.pattern.hasMatch(body)) {
          error(
            '$rel appears to contain a ${entry.label}. Remove it before '
            'publishing.',
          );
          break;
        }
      }
    }
  }
}
