/// Mirrors dart pub's
/// [`DeprecatedFieldsValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/deprecated_fields.dart):
/// warns about pubspec fields that are no longer supported.
library;

import 'validator.dart';

class DeprecatedFieldsValidator extends Validator {
  DeprecatedFieldsValidator(super.context);

  static const List<String> _deprecated = [
    'transformers',
    'web',
    'author',
    'authors',
  ];

  @override
  String get name => 'DeprecatedFieldsValidator';

  @override
  Future<void> validate() async {
    final raw = context.pubspec.rawMap;
    for (final field in _deprecated) {
      if (raw.containsKey(field)) {
        warning(
          'pubspec.yaml uses the deprecated `$field` field — remove it.',
        );
      }
    }
  }
}
