/// Mirrors dart pub's
/// [`FileCaseValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/file_case.dart):
/// no two files in the archive may differ only by case (would collide on
/// case-insensitive filesystems like macOS / Windows).
library;

import 'validator.dart';

class FileCaseValidator extends Validator {
  FileCaseValidator(super.context);

  @override
  String get name => 'FileCaseValidator';

  @override
  Future<void> validate() async {
    // Parity with dart pub: report the first collision and stop. Enhanced
    // mode reports every collision.
    final seen = <String, String>{};
    final sorted = [...context.tarball.files]..sort();
    for (final f in sorted) {
      final existing = seen[f.toLowerCase()];
      if (existing != null) {
        error(
          'The file $f and $existing only differ in capitalization.\n\n'
          'This is not supported across platforms.\n\n'
          'Try renaming one of them.',
        );
        if (!context.enhanced) return;
      }
      seen[f.toLowerCase()] = f;
    }
  }
}
