/// Shared `dart pub get` invocation used by publish + add flows.
library;

import 'dart:io';

import 'log.dart';

/// Runs `dart pub get` in [dir] and prints progress via [log] helpers.
///
/// Returns `true` on success. Missing `dart` on PATH is treated as success
/// with a yellow "Skipped" note — the same soft-failure behaviour the
/// publish flow has always had, so the command does not hard-fail in
/// locked-down environments.
///
/// [errorHint] is appended to the error output on non-zero exit to give
/// callers a chance to suggest command-specific recovery (e.g. publish
/// suggests `--skip-validation`).
Future<bool> runDartPubGet(String dir, {String? errorHint}) async {
  heading('Resolving dependencies');
  final sw = Stopwatch()..start();
  final ProcessResult result;
  try {
    result = await Process.run(
      'dart',
      ['pub', 'get'],
      workingDirectory: dir,
    );
  } on ProcessException {
    sw.stop();
    detail(yellow('Skipped') + gray(' (could not locate `dart` on PATH)'));
    return true;
  }
  sw.stop();
  if (result.exitCode == 0) {
    detail(
      '${green('✓')} Resolved '
      '${gray('(${formatDuration(sw.elapsed)})')}',
    );
    return true;
  }

  final stderrText = (result.stderr as String).trim();
  final stdoutText = (result.stdout as String).trim();
  final body = stderrText.isNotEmpty ? stderrText : stdoutText;
  final indented = body.split('\n').map((l) => '  $l').join('\n');
  final hintSuffix = errorHint == null ? '' : '\n$errorHint';
  error('Dependency resolution failed.$hintSuffix\n$indented');
  return false;
}
