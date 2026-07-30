import 'dart:io';

import 'package:club_cli/src/upgrade/update_check_cache.dart';
import 'package:club_cli/src/upgrade/update_notice.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('shouldCheckForUpdates', () {
    bool check({
      String version = '0.4.1',
      String? command = 'publish',
      bool silenced = false,
      bool ci = false,
      Map<String, String> env = const {},
    }) =>
        shouldCheckForUpdates(
          runningVersion: version,
          command: command,
          stdoutSilenced: silenced,
          inCI: ci,
          environment: env,
        );

    test('runs for a normal released build', () {
      expect(check(), isTrue);
    });

    test('never runs when stdout is silenced', () {
      // `club mcp` sets this to protect JSON-RPC framing; a stray hint
      // would corrupt the stream.
      expect(check(silenced: true), isFalse);
    });

    test('never runs in CI', () {
      expect(check(ci: true), isFalse);
    });

    test('respects NO_UPDATE_CHECK', () {
      expect(check(env: {'NO_UPDATE_CHECK': '1'}), isFalse);
      expect(check(env: {'NO_UPDATE_CHECK': ''}), isFalse);
    });

    test('skips the mcp and upgrade commands', () {
      expect(check(command: 'mcp'), isFalse);
      expect(check(command: 'upgrade'), isFalse);
    });

    test('skips a source checkout', () {
      expect(check(version: 'dev'), isFalse);
    });

    test('skips a local build-cli.sh build', () {
      expect(check(version: '0.4.1-9c4f1e2.dev'), isFalse);
    });

    test('skips an unparseable version', () {
      expect(check(version: 'garbage'), isFalse);
    });

    test('never runs without a command, e.g. `club --version`', () {
      // install.sh greps `club --version` for a semver, and build-cli.yml
      // compares its entire output against the expected version, so an
      // extra stdout line here breaks real tooling.
      expect(check(command: null), isFalse);
    });
  });

  group('UpdateCheckCache', () {
    late Directory tmp;
    late String path;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('club-cache-test-');
      path = p.join(tmp.path, 'update_check.json');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('round-trips a record', () {
      final cache = UpdateCheckCache(path: path);
      final at = DateTime.utc(2026, 7, 30, 12);
      cache.write(UpdateCheckRecord(checkedAt: at, latest: '0.4.2'));

      final read = cache.read()!;
      expect(read.latest, '0.4.2');
      expect(read.checkedAt, at);
    });

    test('records a null latest, so a failed check still throttles', () {
      final cache = UpdateCheckCache(path: path);
      cache.write(
        UpdateCheckRecord(checkedAt: DateTime.utc(2026, 7, 30), latest: null),
      );
      expect(cache.read()!.latest, isNull);
    });

    test('a missing file reads as null', () {
      expect(UpdateCheckCache(path: path).read(), isNull);
    });

    test('corrupt JSON reads as null rather than throwing', () {
      File(path).writeAsStringSync('{not json');
      expect(UpdateCheckCache(path: path).read(), isNull);
    });

    test('a valid JSON file with the wrong shape reads as null', () {
      File(path).writeAsStringSync('[1,2,3]');
      expect(UpdateCheckCache(path: path).read(), isNull);
      File(path).writeAsStringSync('{"checkedAt":"not-a-date"}');
      expect(UpdateCheckCache(path: path).read(), isNull);
    });

    test('an unwritable directory is tolerated silently', () {
      if (Platform.isWindows) return;
      Process.runSync('chmod', ['500', tmp.path]);
      addTearDown(() => Process.runSync('chmod', ['700', tmp.path]));

      // Must not throw: a read-only home should degrade to checking every
      // run, never to an error on an unrelated command.
      expect(
        () => UpdateCheckCache(path: path).write(
          UpdateCheckRecord(checkedAt: DateTime.now(), latest: '1.0.0'),
        ),
        returnsNormally,
      );
    }, skip: Platform.isWindows ? 'chmod semantics differ on Windows' : null);

    group('freshness', () {
      final at = DateTime.utc(2026, 7, 30, 12);

      test('is fresh within the interval', () {
        final r = UpdateCheckRecord(checkedAt: at, latest: '0.4.2');
        expect(r.isFreshAt(at.add(const Duration(hours: 23))), isTrue);
      });

      test('is stale past the interval', () {
        final r = UpdateCheckRecord(checkedAt: at, latest: '0.4.2');
        expect(r.isFreshAt(at.add(const Duration(hours: 25))), isFalse);
      });

      test('a clock that jumped backwards is still treated as fresh', () {
        // Without abs(), a backwards clock would make every run re-check.
        final r = UpdateCheckRecord(checkedAt: at, latest: '0.4.2');
        expect(r.isFreshAt(at.subtract(const Duration(hours: 1))), isTrue);
      });
    });
  });
}
