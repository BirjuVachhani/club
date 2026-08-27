/// Runs the Homebrew commands used for Homebrew-managed Club installations.
library;

import 'dart:io';

class HomebrewResult {
  const HomebrewResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.executableMissing = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool executableMissing;

  bool get succeeded => exitCode == 0;
}

class HomebrewUpgrader {
  HomebrewUpgrader({String executable = 'brew'}) : _executable = executable;

  final String _executable;

  /// Runs `brew` with [arguments].
  ///
  /// Captured mode is used when Club needs to inspect the result or preserve
  /// stdout for a single JSON document. Interactive mode hands the terminal to
  /// Homebrew so progress, prompts, and diagnostics behave normally.
  Future<HomebrewResult> run(
    List<String> arguments, {
    required bool captureOutput,
  }) async {
    try {
      if (captureOutput) {
        final result = await Process.run(_executable, arguments);
        return HomebrewResult(
          exitCode: result.exitCode,
          stdout: result.stdout as String,
          stderr: result.stderr as String,
        );
      }

      final process = await Process.start(
        _executable,
        arguments,
        mode: ProcessStartMode.inheritStdio,
      );
      return HomebrewResult(exitCode: await process.exitCode);
    } on ProcessException catch (e) {
      return HomebrewResult(
        exitCode: -1,
        stderr: e.message,
        executableMissing: true,
      );
    }
  }
}
