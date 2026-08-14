import 'package:club_cli/src/publish/version_prompt.dart';
import 'package:club_cli/src/util/prompt.dart';
import 'package:test/test.dart';

/// Feeds [lines] to `askText` one call at a time, then EOF.
String? Function() scriptedInput(List<String> lines) {
  var i = 0;
  return () => i < lines.length ? lines[i++] : null;
}

void main() {
  group('versionFormatError', () {
    test('accepts plain semver', () {
      expect(versionFormatError('1.2.3'), isNull);
      expect(versionFormatError('0.0.1'), isNull);
      expect(versionFormatError('10.20.30'), isNull);
    });

    test('accepts prerelease and build metadata', () {
      expect(versionFormatError('1.2.3-beta.1'), isNull);
      expect(versionFormatError('1.2.3+build5'), isNull);
      expect(versionFormatError('1.2.3-pr2+abc'), isNull);
    });

    test('tolerates surrounding whitespace', () {
      expect(versionFormatError('  1.2.3  '), isNull);
    });

    test('rejects empty input', () {
      expect(versionFormatError(''), contains('cannot be empty'));
      expect(versionFormatError('   '), contains('cannot be empty'));
    });

    test('rejects non-semver', () {
      for (final bad in ['1.2', 'v1.2.3', 'latest', '1.2.3.4', 'not-a-ver']) {
        expect(versionFormatError(bad), isNotNull, reason: bad);
      }
    });

    test('the message shows the offending value and an example', () {
      final message = versionFormatError('v1.2.3')!;
      expect(message, contains('v1.2.3'));
      expect(message, contains('1.2.3'));
    });
  });

  group('normalizeVersionChoice', () {
    test('a new value is an override', () {
      expect(normalizeVersionChoice('2.0.0', '1.2.0'), '2.0.0');
    });

    test('retyping the detected version is not an override', () {
      expect(normalizeVersionChoice('1.2.0', '1.2.0'), isNull);
    });

    test('no answer is not an override', () {
      expect(normalizeVersionChoice(null, '1.2.0'), isNull);
      expect(normalizeVersionChoice(null, null), isNull);
    });

    test('a value with no default offered is an override (--auto)', () {
      expect(normalizeVersionChoice('2.0.0', null), '2.0.0');
    });
  });

  group('askText', () {
    test('an empty reply takes the default', () async {
      final answer = await askText(
        'Publish as',
        defaultValue: '1.2.0',
        readLine: scriptedInput(['']),
        write: (_) {},
      );
      expect(answer, '1.2.0');
    });

    test('a typed value wins over the default', () async {
      final answer = await askText(
        'Publish as',
        defaultValue: '1.2.0',
        readLine: scriptedInput(['2.0.0']),
        write: (_) {},
      );
      expect(answer, '2.0.0');
    });

    test('input is trimmed', () async {
      final answer = await askText(
        'Publish as',
        readLine: scriptedInput(['  2.0.0  ']),
        write: (_) {},
      );
      expect(answer, '2.0.0');
    });

    test('invalid input re-prompts instead of aborting', () async {
      final shown = <String>[];
      final answer = await askText(
        'Publish as',
        defaultValue: '1.2.0',
        validate: versionFormatError,
        readLine: scriptedInput(['nope', 'still-bad', '2.0.0']),
        write: shown.add,
      );
      expect(answer, '2.0.0');
      // Prompted three times, complained about the first two.
      expect(shown.where((s) => s.contains('Publish as')).length, 3);
      expect(shown.where((s) => s.contains('Not valid semver')).length, 2);
    });

    test('EOF falls back to the default rather than looping', () async {
      final answer = await askText(
        'Publish as',
        defaultValue: '1.2.0',
        validate: versionFormatError,
        readLine: scriptedInput([]),
        write: (_) {},
      );
      expect(answer, '1.2.0');
    });

    test('EOF with no default returns null', () async {
      final answer = await askText(
        'Publish all packages as',
        validate: versionFormatError,
        readLine: scriptedInput([]),
        write: (_) {},
      );
      expect(answer, isNull);
    });

    test('the default is shown in brackets', () async {
      final shown = <String>[];
      await askText(
        'Publish as',
        defaultValue: '0.0.8-pr2',
        readLine: scriptedInput(['']),
        write: shown.add,
      );
      expect(shown.first, contains('[0.0.8-pr2]'));
    });

    test('the default is not run through validate', () async {
      // Callers own their default; it is offered as-is even if it would
      // not pass the validator applied to typed input.
      final answer = await askText(
        'Publish as',
        defaultValue: 'not-semver',
        validate: versionFormatError,
        readLine: scriptedInput(['']),
        write: (_) {},
      );
      expect(answer, 'not-semver');
    });
  });
}
