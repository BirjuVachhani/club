/// Chooses between `dart pub` and `flutter pub` and runs the result.
///
/// `dart pub` refuses to do version solving for any resolution that pulls in
/// the Flutter SDK, and says so:
///
/// ```
/// Because dream_council requires the Flutter SDK, version solving failed.
/// Flutter users should use `flutter pub` instead of `dart pub`.
/// ```
///
/// The inverse is not symmetric: `flutter pub` is *not* a drop-in replacement
/// for `dart pub` on pure-Dart packages (its post-`pub get` steps expect a
/// Flutter project layout), so we only reach for it when the pubspec actually
/// asks for the Flutter SDK.
library;

import 'dart:io';

import 'package:pubspec_parse/pubspec_parse.dart';

/// Which pub front-end to invoke.
enum PubTool {
  dart('dart'),
  flutter('flutter');

  const PubTool(this.executable);

  /// Name of the executable to spawn.
  final String executable;
}

/// Matches the two phrasings `dart pub` uses when it bails out because the
/// resolution needs the Flutter SDK.
final RegExp _needsFlutterPattern = RegExp(
  r'requires the Flutter SDK|Flutter users should use `flutter pub`',
  caseSensitive: false,
);

/// Picks the pub front-end required to resolve [parsed].
///
/// Returns [PubTool.flutter] when any dependency or dev_dependency comes from
/// the Flutter SDK (`sdk: flutter`), or when an `environment: flutter:`
/// constraint is declared. Root dev_dependencies participate in version
/// solving, so a lone `flutter_test: {sdk: flutter}` is enough to require
/// `flutter pub`.
PubTool pubToolFor(Pubspec parsed) {
  bool isFlutterSdkDep(Dependency dep) =>
      dep is SdkDependency && dep.sdk == 'flutter';

  if (parsed.dependencies.values.any(isFlutterSdkDep)) return PubTool.flutter;
  if (parsed.devDependencies.values.any(isFlutterSdkDep)) {
    return PubTool.flutter;
  }
  if (parsed.environment['flutter'] != null) return PubTool.flutter;
  return PubTool.dart;
}

/// Outcome of a [runPub] call.
class PubRunResult {
  PubRunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.tool,
    this.toolMissing = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  /// The front-end that actually produced this result. May differ from the
  /// requested tool when the Flutter fallback kicked in.
  final PubTool tool;

  /// True when the executable could not be found on PATH. [exitCode] is
  /// non-zero in that case, but callers usually want to degrade gracefully
  /// rather than fail the command.
  final bool toolMissing;

  bool get ok => exitCode == 0;

  /// stderr when it has content, stdout otherwise — matches how pub splits
  /// diagnostics across the two streams depending on the subcommand.
  String get output {
    final err = stderr.trim();
    return err.isNotEmpty ? err : stdout.trim();
  }
}

/// Runs `<tool> pub <args>` in [workingDirectory].
///
/// When [tool] is [PubTool.dart] and the run fails with pub's
/// "requires the Flutter SDK" diagnostic, the same arguments are retried once
/// with `flutter pub`. Detection via [pubToolFor] catches the common cases up
/// front; this retry covers the ones it cannot see, such as a pure-Dart
/// workspace member whose *sibling* is a Flutter package (pub escalates
/// resolution to the workspace root, so the Flutter requirement is invisible
/// from the member's own pubspec).
Future<PubRunResult> runPub(
  List<String> args, {
  required String workingDirectory,
  PubTool tool = PubTool.dart,
  bool allowFlutterFallback = true,
}) async {
  final first = await _run(tool, args, workingDirectory);
  if (first.ok || first.toolMissing) return first;
  if (tool != PubTool.dart || !allowFlutterFallback) return first;
  if (!_needsFlutterPattern.hasMatch(first.output)) return first;

  final retry = await _run(PubTool.flutter, args, workingDirectory);
  // A missing `flutter` on PATH is less useful to report than the original
  // Dart diagnostic, which at least names the offending package.
  return retry.toolMissing ? first : retry;
}

Future<PubRunResult> _run(
  PubTool tool,
  List<String> args,
  String workingDirectory,
) async {
  try {
    final result = await Process.run(
      tool.executable,
      ['pub', ...args],
      workingDirectory: workingDirectory,
      // `flutter` is a .bat shim on Windows, which Process.run cannot spawn
      // directly.
      runInShell: Platform.isWindows,
    );
    return PubRunResult(
      exitCode: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
      tool: tool,
    );
  } on ProcessException {
    return PubRunResult(
      exitCode: -1,
      stdout: '',
      stderr: '',
      tool: tool,
      toolMissing: true,
    );
  }
}
