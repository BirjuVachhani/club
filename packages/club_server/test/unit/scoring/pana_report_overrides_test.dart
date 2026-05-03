import 'package:club_server/src/scoring/pana_report_overrides.dart';
import 'package:test/test.dart';

/// Sample criterion body that pana emits when the publish_to check is the
/// SOLE failure for "Provide a valid `pubspec.yaml`". Keep this in sync
/// with pana's verbatim wording — that's what the override matches on.
const _publishToOnlyBody = '''<details>
<summary>
Failed to verify repository URL.
</summary>

*`packages/audio_tags/pubspec.yaml` from the repository defines `publish_to`, thus, we are unable to verify the package is published from here.*

Please provide a valid [`repository`](https://dart.dev/tools/pub/pubspec#repository) URL in `pubspec.yaml`, such that:

 * `repository` can be cloned,
 * a clone of the repository contains a `pubspec.yaml`, which:,
    * contains `name: audio_tags`,
    * contains a `version` property, and,
    * does not contain a `publish_to` property.
</details>
''';

Map<String, dynamic> _summaryWithConvention({
  required int granted,
  required int max,
  required String summaryMd,
  String status = 'failed',
  List<Map<String, dynamic>> extraSections = const [],
}) {
  return {
    'report': {
      'sections': [
        {
          'id': 'convention',
          'title': 'Follow Dart file conventions',
          'grantedPoints': granted,
          'maxPoints': max,
          'status': status,
          'summary': summaryMd,
        },
        ...extraSections,
      ],
    },
  };
}

void main() {
  group('applyClubOverrides — publish_to re-grant', () {
    test('re-grants when publish_to is the SOLE failure', () {
      final summaryMd =
          'Some intro paragraph.\n\n'
          '### [x] 0/10 points: Provide a valid `pubspec.yaml`\n'
          '\n'
          '$_publishToOnlyBody'
          '\n'
          '### [*] 10/10 points: Provide a valid `README.md`\n'
          '\n'
          'A README is at the package root.\n';

      final json = _summaryWithConvention(
        granted: 20, // 10 (README ok) + 0 (pubspec failed) + 10 (other)
        max: 30,
        summaryMd: summaryMd,
      );

      applyClubOverrides(json);

      final section =
          (json['report'] as Map)['sections'][0] as Map<String, dynamic>;
      expect(section['grantedPoints'], 30, reason: '+10 for re-grant');
      expect(section['status'], 'passed');
      expect(section['summary'], contains('### [*] 10/10 points: Provide'));
      expect(
        section['summary'],
        contains('Adjusted by Club'),
        reason: 'rewrite leaves an audit-trail breadcrumb',
      );
      expect(
        section['summary'],
        isNot(contains('Failed to verify repository URL.')),
        reason: 'the failure block is gone',
      );
      // Other criteria are preserved.
      expect(section['summary'], contains('### [*] 10/10 points: Provide a valid `README.md`'));
    });

    test('partial section status when re-grant lifts off the floor', () {
      // Convention section worth 30 points; only the pubspec criterion
      // failed (10/10), so granted goes from 20 → 30 (passed) above. Here
      // we test the case where some OTHER non-publish_to deduction still
      // costs points after the re-grant — section ends partial.
      final summaryMd =
          '### [x] 0/10 points: Provide a valid `pubspec.yaml`\n'
          '\n'
          '$_publishToOnlyBody'
          '\n'
          '### [~] 2/5 points: Provide a valid `README.md`\n'
          '\n'
          'README has issues.\n';

      final json = _summaryWithConvention(
        granted: 2, // 2 (README partial) + 0 (pubspec failed)
        max: 15, // arbitrary larger max so re-grant doesn't equal max
        summaryMd: summaryMd,
      );
      // Force a max where 12 < max so status will be partial after +10
      final section =
          (json['report'] as Map)['sections'][0] as Map<String, dynamic>;
      section['maxPoints'] = 15;

      applyClubOverrides(json);

      expect(section['grantedPoints'], 12);
      expect(section['status'], 'partial');
    });

    test('does NOT re-grant when there are multiple issues', () {
      final summaryMd =
          '### [x] 0/10 points: Provide a valid `pubspec.yaml`\n'
          '\n'
          '$_publishToOnlyBody'
          '\n'
          '<details>\n'
          '<summary>\n'
          'Description is too short.\n'
          '</summary>\n'
          '\n'
          'Add a longer description.\n'
          '</details>\n';

      final json = _summaryWithConvention(
        granted: 0,
        max: 10,
        summaryMd: summaryMd,
      );
      applyClubOverrides(json);
      final section =
          (json['report'] as Map)['sections'][0] as Map<String, dynamic>;
      expect(section['grantedPoints'], 0, reason: 'left untouched');
      expect(section['status'], 'failed');
      expect(section['summary'], contains('### [x] 0/10 points'));
    });

    test('does NOT re-grant when the failure is something else', () {
      const otherFailure = '''<details>
<summary>
Failed to verify repository URL.
</summary>

*Repository URL is missing.*

Please provide a valid repository URL.
</details>
''';
      final summaryMd =
          '### [x] 0/10 points: Provide a valid `pubspec.yaml`\n'
          '\n'
          '$otherFailure';

      final json = _summaryWithConvention(
        granted: 0,
        max: 10,
        summaryMd: summaryMd,
      );
      applyClubOverrides(json);
      final section =
          (json['report'] as Map)['sections'][0] as Map<String, dynamic>;
      expect(section['grantedPoints'], 0, reason: 'wrong failure → no re-grant');
    });

    test('does NOT re-grant when the criterion already passed', () {
      final summaryMd =
          '### [*] 10/10 points: Provide a valid `pubspec.yaml`\n'
          '\n'
          'All good.\n';
      final json = _summaryWithConvention(
        granted: 10,
        max: 10,
        summaryMd: summaryMd,
        status: 'passed',
      );
      applyClubOverrides(json);
      final section =
          (json['report'] as Map)['sections'][0] as Map<String, dynamic>;
      expect(section['grantedPoints'], 10);
      expect(section['summary'], same(summaryMd));
    });

    test('skips non-convention sections silently', () {
      final json = {
        'report': {
          'sections': [
            {
              'id': 'analysis',
              'grantedPoints': 0,
              'maxPoints': 50,
              'status': 'failed',
              'summary':
                  '### [x] 0/10 points: Provide a valid `pubspec.yaml`\n'
                  '\n$_publishToOnlyBody',
            },
          ],
        },
      };
      applyClubOverrides(json);
      final section =
          (json['report'] as Map)['sections'][0] as Map<String, dynamic>;
      expect(section['grantedPoints'], 0);
    });

    test('handles malformed input without throwing', () {
      expect(() => applyClubOverrides(<String, dynamic>{}), returnsNormally);
      expect(
        () => applyClubOverrides({'report': 'not a map'}),
        returnsNormally,
      );
      expect(
        () => applyClubOverrides({
          'report': {'sections': 'not a list'},
        }),
        returnsNormally,
      );
      expect(
        () => applyClubOverrides({
          'report': {
            'sections': [
              {'id': 'convention', 'summary': 42}, // wrong type
            ],
          },
        }),
        returnsNormally,
      );
    });
  });
}
