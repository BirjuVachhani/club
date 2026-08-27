import 'package:args/command_runner.dart';
import 'package:club_cli/src/commands/command_runner.dart';
import 'package:test/test.dart';

void main() {
  group('SetVersionCommand', () {
    test('is registered with the expected invocation', () {
      final runner = buildCommandRunner();

      expect(runner.commands, contains('set-version'));
      expect(
        runner.commands['set-version']!.invocation,
        'club set-version [options] <version_tag>',
      );
    });

    test('rejects a missing version tag', () async {
      final runner = buildCommandRunner();

      await expectLater(
        runner.run(['set-version']),
        throwsA(
          isA<UsageException>().having(
            (exception) => exception.message,
            'message',
            contains('Missing version tag'),
          ),
        ),
      );
    });

    test('rejects extra positional arguments', () async {
      final runner = buildCommandRunner();

      await expectLater(
        runner.run(['set-version', '1.0.0', '2.0.0']),
        throwsA(
          isA<UsageException>().having(
            (exception) => exception.message,
            'message',
            contains('Expected exactly one version tag'),
          ),
        ),
      );
    });

    test('rejects a version prefixed with v', () async {
      final runner = buildCommandRunner();

      await expectLater(
        runner.run(['set-version', 'v1.0.0']),
        throwsA(
          isA<UsageException>().having(
            (exception) => exception.message,
            'message',
            contains('Not valid semver'),
          ),
        ),
      );
    });
  });
}
