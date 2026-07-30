/// Shared `pub get` invocation used by publish + add flows.
library;

import 'package:pubspec_parse/pubspec_parse.dart';

import 'log.dart';
import 'pub_tool.dart';

/// Runs `pub get` in [dir] and prints progress via [log] helpers.
///
/// [tool] selects the front-end. Pass the result of [pubToolFor] when the
/// pubspec is already parsed; the default ([PubTool.dart]) still recovers via
/// the Flutter retry inside [runPub].
///
/// Returns `true` on success. A missing executable is treated as success with
/// a yellow "Skipped" note — the same soft-failure behaviour the publish flow
/// has always had, so the command does not hard-fail in locked-down
/// environments.
///
/// [errorHint] is appended to the error output on non-zero exit to give
/// callers a chance to suggest command-specific recovery (e.g. publish
/// suggests `--skip-validation`).
Future<bool> runPubGet(
  String dir, {
  PubTool tool = PubTool.dart,
  String? errorHint,
  bool printHeading = true,
}) async {
  if (printHeading) heading('Resolving dependencies');
  final sw = Stopwatch()..start();
  final result = await runPub(['get'], workingDirectory: dir, tool: tool);
  sw.stop();

  if (result.toolMissing) {
    detail(
      yellow('Skipped') +
          gray(' (could not locate `${result.tool.executable}` on PATH)'),
    );
    return true;
  }

  if (result.ok) {
    detail(
      '${green('✓')} Resolved with '
      '${gray('`${result.tool.executable} pub get`')} '
      '${gray('(${formatDuration(sw.elapsed)})')}',
    );
    return true;
  }

  final indented = result.output.split('\n').map((l) => '  $l').join('\n');
  final hintSuffix = errorHint == null ? '' : '\n$errorHint';
  error('Dependency resolution failed.$hintSuffix\n$indented');
  return false;
}

/// Convenience wrapper that derives the front-end from [parsed].
Future<bool> runPubGetFor(
  String dir,
  Pubspec parsed, {
  String? errorHint,
  bool printHeading = true,
}) => runPubGet(
  dir,
  tool: pubToolFor(parsed),
  errorHint: errorHint,
  printHeading: printHeading,
);
