import 'dart:io';

import 'package:club_cli/src/upgrade/homebrew_upgrader.dart';
import 'package:test/test.dart';

void main() {
  test('captures process output and exit code', () async {
    final result = await HomebrewUpgrader(
      executable: Platform.resolvedExecutable,
    ).run(['--version'], captureOutput: true);

    expect(result.succeeded, isTrue);
    expect(result.stdout, isNotEmpty);
    expect(result.stderr, isEmpty);
    expect(result.executableMissing, isFalse);
  });

  test('reports a missing executable without throwing', () async {
    final result = await HomebrewUpgrader(
      executable: '/club-test/no-such-homebrew-executable',
    ).run(const [], captureOutput: true);

    expect(result.succeeded, isFalse);
    expect(result.executableMissing, isTrue);
    expect(result.exitCode, -1);
    expect(result.stderr, isNotEmpty);
  });
}
