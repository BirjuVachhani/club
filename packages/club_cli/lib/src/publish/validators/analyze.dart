/// Mirrors dart pub's
/// [`AnalyzeValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/analyze.dart):
/// runs `dart analyze` against the package and surfaces errors.
library;

import 'dart:io';

import 'validator.dart';

class AnalyzeValidator extends Validator {
  AnalyzeValidator(super.context);

  @override
  String get name => 'AnalyzeValidator';

  @override
  Future<void> validate() async {
    // Enhanced mode upgrades analyze to `--fatal-warnings` and treats any
    // issues as errors (club-specific strictness). Baseline matches
    // dart pub publish: no flags, issues surface as warnings.
    final args = context.enhanced
        ? ['analyze', '--fatal-warnings']
        : ['analyze'];
    final ProcessResult result;
    try {
      result = await Process.run(
        'dart',
        args,
        workingDirectory: context.pubspec.directory,
      );
    } on ProcessException {
      hint('Could not run `dart analyze` — Dart SDK not on PATH.');
      return;
    }

    final stdoutText = (result.stdout as String).trim();
    final stderrText = (result.stderr as String).trim();
    if (result.exitCode == 0) return;

    final body = stdoutText.isNotEmpty ? stdoutText : stderrText;
    final message =
        '`dart analyze` reported issues. Consider fixing them before '
        'publishing:\n${_indent(body)}';
    if (context.enhanced) {
      error(message);
    } else {
      warning(message);
    }
  }

  String _indent(String s) => s.split('\n').map((l) => '  $l').join('\n');
}
