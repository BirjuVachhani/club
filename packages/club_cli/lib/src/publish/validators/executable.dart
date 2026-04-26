/// Mirrors dart pub's
/// [`ExecutableValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/executable.dart):
/// every executable declared in pubspec.yaml must point to a real file
/// under bin/.
library;

import 'validator.dart';

class ExecutableValidator extends Validator {
  ExecutableValidator(super.context);

  @override
  String get name => 'ExecutableValidator';

  @override
  Future<void> validate() async {
    final raw = context.pubspec.rawMap['executables'];
    if (raw is! Map) return;

    for (final entry in raw.entries) {
      final scriptName = (entry.value as String?) ?? entry.key.toString();
      final relPath = 'bin/$scriptName.dart';
      if (!context.tarball.files.contains(relPath)) {
        warning(
          'pubspec.yaml declares executable `${entry.key}` but $relPath is '
          'not in the archive.',
        );
      }
    }
  }
}
