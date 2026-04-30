/// Mirrors dart pub's
/// [`PubspecFieldValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/pubspec_field.dart):
/// required fields present, URLs parseable.
library;

import 'validator.dart';

class PubspecFieldValidator extends Validator {
  PubspecFieldValidator(super.context);

  @override
  String get name => 'PubspecFieldValidator';

  @override
  Future<void> validate() async {
    final raw = context.pubspec.rawMap;

    _requireString(raw, 'description');
    _requireString(raw, 'version');

    _checkUrl(raw, 'homepage');
    _checkUrl(raw, 'repository');
    _checkUrl(raw, 'documentation');

    if (!raw.containsKey('homepage') && !raw.containsKey('repository')) {
      warning(
        'It\'s strongly recommended to include a "homepage" or '
        '"repository" field in your pubspec.yaml',
      );
    }
  }

  void _requireString(Map<String, dynamic> raw, String field) {
    final value = raw[field];
    if (value == null) {
      error('Your pubspec.yaml is missing a "$field" field.');
    } else if (value is! String) {
      error(
        'Your pubspec.yaml\'s "$field" field must be a string, but '
        'it was "$value".',
      );
    }
  }

  void _checkUrl(Map<String, dynamic> raw, String field) {
    final value = raw[field];
    if (value == null) return;
    if (value is! String) {
      error(
        'Your pubspec.yaml\'s "$field" field must be a string, but '
        'it was "$value".',
      );
      return;
    }
    if (!RegExp(r'^https?:').hasMatch(value)) {
      error(
        'Your pubspec.yaml\'s "$field" field must be an "http:" or '
        '"https:" URL, but it was "$value".',
      );
    }
  }
}
