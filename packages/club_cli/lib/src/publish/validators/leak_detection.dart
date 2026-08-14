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

  /// [publicInFirebaseConfig] marks a pattern whose matches are expected, and
  /// harmless, inside a generated Firebase client config — see
  /// [_firebaseClientConfig].
  static final List<({String label, RegExp pattern, bool
      publicInFirebaseConfig})> _patterns = [
    (
      label: 'AWS access key',
      pattern: RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
      publicInFirebaseConfig: false,
    ),
    (
      label: 'Google API key',
      pattern: RegExp(r'\bAIza[0-9A-Za-z\-_]{35}\b'),
      publicInFirebaseConfig: true,
    ),
    (
      label: 'GitHub token',
      pattern: RegExp(r'\bghp_[A-Za-z0-9]{36}\b'),
      publicInFirebaseConfig: false,
    ),
    (
      label: 'private key block',
      pattern: RegExp(r'-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'),
      publicInFirebaseConfig: false,
    ),
    (
      label: 'Slack token',
      pattern: RegExp(r'\bxox[abprs]-[A-Za-z0-9-]{10,}\b'),
      publicInFirebaseConfig: false,
    ),
  ];

  /// Generated Firebase client-config files, by exact file name.
  ///
  /// `flutterfire configure` (and the Firebase console) produce these, and the
  /// `apiKey` they carry identifies a project rather than authenticating one:
  /// Firebase protects data with security rules and App Check, not by keeping
  /// this value secret, and it ships in every compiled client app anyway. A
  /// Flutter package with an `example/` almost always includes one, so
  /// treating it as a leak blocks a publish that is not leaking anything.
  ///
  /// Only patterns flagged [publicInFirebaseConfig] are skipped for these
  /// files. An AWS key or a private key block in one is still an error.
  static const _firebaseClientConfig = {
    'firebase_options.dart',
    'google-services.json',
    'GoogleService-Info.plist',
  };

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

      final isFirebaseConfig = _firebaseClientConfig.contains(p.basename(rel));
      for (final entry in _patterns) {
        if (entry.publicInFirebaseConfig && isFirebaseConfig) continue;
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
