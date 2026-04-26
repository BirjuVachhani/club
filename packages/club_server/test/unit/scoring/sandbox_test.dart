import 'dart:io';

import 'package:club_server/src/scoring/sandbox.dart';
import 'package:test/test.dart';

void main() {
  group('SandboxConfig.wrap', () {
    const innerCmd = ['dart', 'run', 'club_server:scoring_subprocess'];

    test('no hardening returns the command verbatim', () {
      expect(SandboxConfig.none.wrap(innerCmd), innerCmd);
      expect(SandboxConfig.none.isActive, isFalse);
    });

    test('command prefix is outermost', () {
      final cfg = SandboxConfig(
        commandPrefix: ['bwrap', '--unshare-all', '--ro-bind', '/', '/'],
      );
      expect(cfg.wrap(innerCmd), [
        'bwrap',
        '--unshare-all',
        '--ro-bind',
        '/',
        '/',
        ...innerCmd,
      ]);
    });

    test('rlimits wrap inner command via bash -c ulimit…', () {
      final cfg = SandboxConfig(
        rlimits: {'v': 4000000, 'n': 1024},
      );
      final wrapped = cfg.wrap(innerCmd);
      expect(wrapped.first, 'bash');
      expect(wrapped[1], '-c');
      // Order of map entries preserved in the ulimit chain.
      expect(wrapped[2], contains('ulimit -v 4000000'));
      expect(wrapped[2], contains('ulimit -n 1024'));
      expect(wrapped[2], contains('exec "\$@"'));
      // $0 placeholder then the inner command.
      expect(wrapped[3], isNotEmpty);
      expect(wrapped.sublist(4), innerCmd);
    });

    test('commandPrefix + rlimits compose with prefix outermost', () {
      final cfg = SandboxConfig(
        commandPrefix: ['systemd-run', '--scope'],
        rlimits: {'t': 3600},
      );
      final wrapped = cfg.wrap(innerCmd);
      expect(wrapped.first, 'systemd-run');
      expect(wrapped[1], '--scope');
      expect(wrapped[2], 'bash');
      expect(wrapped[3], '-c');
      expect(wrapped[4], contains('ulimit -t 3600'));
    });

    test(
      'UID drop emits setpriv only on Linux',
      () {
        final cfg = SandboxConfig(dropToUid: 1000, dropToGid: 1000);
        final wrapped = cfg.wrap(innerCmd);
        if (Platform.isLinux) {
          expect(wrapped.first, 'setpriv');
          expect(wrapped, contains('--reuid=1000'));
          expect(wrapped, contains('--regid=1000'));
          expect(wrapped, contains('--clear-groups'));
          expect(wrapped, contains('--'));
          expect(wrapped.last, innerCmd.last);
        } else {
          // Non-Linux: UID drop is silently skipped.
          expect(wrapped, innerCmd);
        }
      },
    );

    test('describe() summarises the active layers', () {
      expect(SandboxConfig.none.describe(), 'none');
      expect(
        SandboxConfig(commandPrefix: ['bwrap']).describe(),
        'prefix=bwrap',
      );
      expect(
        SandboxConfig(dropToUid: 1000).describe(),
        contains('drop=1000:-'),
      );
      expect(
        SandboxConfig(rlimits: {'v': 4000000}).describe(),
        'rlimits=v=4000000',
      );
    });
  });

  group('SandboxConfig.fromEnv', () {
    test('empty env produces SandboxConfig.none-equivalent', () {
      final cfg = SandboxConfig.fromEnv({});
      expect(cfg.commandPrefix, isEmpty);
      expect(cfg.dropToUid, isNull);
      expect(cfg.dropToGid, isNull);
      expect(cfg.rlimits, isEmpty);
      expect(cfg.isActive, isFalse);
    });

    test('parses prefix as whitespace-split argv', () {
      final cfg = SandboxConfig.fromEnv({
        'SCORING_SANDBOX_PREFIX': 'bwrap --unshare-all --ro-bind / /',
      });
      expect(cfg.commandPrefix, [
        'bwrap',
        '--unshare-all',
        '--ro-bind',
        '/',
        '/',
      ]);
    });

    test('parses UID/GID as integers', () {
      final cfg = SandboxConfig.fromEnv({
        'SCORING_SANDBOX_UID': '1000',
        'SCORING_SANDBOX_GID': '1001',
      });
      expect(cfg.dropToUid, 1000);
      expect(cfg.dropToGid, 1001);
    });

    test('parses comma-separated rlimits', () {
      final cfg = SandboxConfig.fromEnv({
        'SCORING_SANDBOX_RLIMITS': 'v=4000000,t=3600,n=1024',
      });
      expect(cfg.rlimits, {'v': 4000000, 't': 3600, 'n': 1024});
    });

    test('skips malformed rlimit entries without throwing', () {
      final cfg = SandboxConfig.fromEnv({
        'SCORING_SANDBOX_RLIMITS': 'v=4000000,garbage,=5,t=,n=1024',
      });
      expect(cfg.rlimits, {'v': 4000000, 'n': 1024});
    });
  });

  group('rlimit wrapper actually caps limits', () {
    // Integration: build a bash command that'd report its limits and
    // verify ulimit was effective. Works on macOS and Linux since ulimit
    // semantics match for these flags.
    test('ulimit -n 42 is enforced in the spawned shell', () async {
      final cfg = SandboxConfig(rlimits: {'n': 42});
      // Use `bash -c 'ulimit -n'` as the "inner" command — ulimit with no
      // args prints the current soft limit. The wrapper should have set
      // it to 42.
      final wrapped = cfg.wrap(['bash', '-c', 'ulimit -n']);
      final result = await Process.run(wrapped.first, wrapped.sublist(1));
      expect(result.exitCode, 0);
      expect(result.stdout.toString().trim(), '42');
    });
  });
}
