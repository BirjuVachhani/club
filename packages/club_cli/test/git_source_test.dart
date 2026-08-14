import 'package:club_cli/src/publish/git_source.dart';
import 'package:test/test.dart';

void main() {
  group('parseGitSource: GitHub pull requests', () {
    test('plain PR URL', () {
      final source = parseGitSource(
        'https://github.com/Azzeccagarbugli/core_haptics/pull/2',
      );
      expect(source.pullRequest, 2);
      expect(source.isPullRequest, isTrue);
      expect(
        source.cloneUrl,
        'https://github.com/Azzeccagarbugli/core_haptics.git',
      );
    });

    test('trailing browser segments are ignored', () {
      for (final tail in ['/files', '/commits', '/checks/12345']) {
        final source = parseGitSource('https://github.com/o/r/pull/2$tail');
        expect(source.pullRequest, 2, reason: tail);
        expect(source.cloneUrl, 'https://github.com/o/r.git', reason: tail);
      }
    });

    test('trailing slash, query, and fragment are ignored', () {
      expect(parseGitSource('https://github.com/o/r/pull/2/').pullRequest, 2);
      expect(parseGitSource('https://github.com/o/r/pull/2?w=1').pullRequest, 2);
      expect(
        parseGitSource('https://github.com/o/r/pull/2#issuecomment-1').
            pullRequest,
        2,
      );
    });

    test('www host is accepted', () {
      final source = parseGitSource('https://www.github.com/o/r/pull/8');
      expect(source.pullRequest, 8);
      expect(source.cloneUrl, 'https://www.github.com/o/r.git');
    });

    test('multi-digit PR numbers', () {
      expect(parseGitSource('https://github.com/o/r/pull/12345').pullRequest,
          12345);
    });

    test('a .git suffix on the repo segment is stripped', () {
      expect(
        parseGitSource('https://github.com/o/r.git/pull/2').cloneUrl,
        'https://github.com/o/r.git',
      );
    });
  });

  group('parseGitSource: non-PR URLs pass through unchanged', () {
    const passthrough = [
      'https://github.com/your-org/your-package',
      'https://github.com/your-org/your-package.git',
      'git@github.com:your-org/your-package.git',
      'ssh://git@github.com/your-org/your-package.git',
      'https://gitlab.com/group/subgroup/repo.git',
      'github.com:your-org/your-package.git',
    ];

    for (final url in passthrough) {
      test(url, () {
        final source = parseGitSource(url);
        expect(source.pullRequest, isNull);
        expect(source.isPullRequest, isFalse);
        expect(source.cloneUrl, url);
      });
    }

    test('surrounding whitespace is trimmed', () {
      expect(
        parseGitSource('  https://github.com/o/r.git  ').cloneUrl,
        'https://github.com/o/r.git',
      );
    });

    test('a repo literally named "pull" is not mistaken for a PR', () {
      final source = parseGitSource('https://github.com/o/pull');
      expect(source.pullRequest, isNull);
      expect(source.cloneUrl, 'https://github.com/o/pull');
    });
  });

  group('parseGitSource: errors', () {
    test('empty URL', () {
      expect(() => parseGitSource('   '), throwsA(isA<GitSourceError>()));
    });

    test('GitLab merge request URL names the limitation', () {
      expect(
        () => parseGitSource('https://gitlab.com/group/repo/-/merge_requests/4'),
        throwsA(
          isA<GitSourceError>().having(
            (e) => e.message,
            'message',
            contains('GitHub only'),
          ),
        ),
      );
    });

    test('Bitbucket pull request URL names the limitation', () {
      expect(
        () => parseGitSource('https://bitbucket.org/team/repo/pull-requests/9'),
        throwsA(isA<GitSourceError>()),
      );
    });

    test('a /pull/ URL on a non-GitHub host is rejected, not guessed at', () {
      expect(
        () => parseGitSource('https://gitea.example.com/o/r/pull/3'),
        throwsA(
          isA<GitSourceError>().having(
            (e) => e.hint,
            'hint',
            contains('refs/pull/3/head'),
          ),
        ),
      );
    });
  });
}
