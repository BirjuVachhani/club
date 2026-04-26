/// Mirrors dart pub's
/// [`PubspecValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/pubspec.dart):
/// pubspec.yaml must be in the archive (i.e. not excluded by .pubignore).
library;

import 'validator.dart';

class PubspecPresentValidator extends Validator {
  PubspecPresentValidator(super.context);

  @override
  String get name => 'PubspecPresentValidator';

  @override
  Future<void> validate() async {
    if (!context.tarball.files.contains('pubspec.yaml')) {
      error(
        'pubspec.yaml is excluded by your .pubignore or .gitignore — it MUST '
        'be included in published packages.',
      );
    }
  }
}
