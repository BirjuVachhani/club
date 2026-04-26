import 'package:club_package_reader/club_package_reader.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

/// Hosted-dep allowlist behaviour. Covers the seam where a private registry
/// needs to accept:
///   1. Default pub deps (`foo: ^1.0.0`)
///   2. Explicit pub.dev deps (`hosted: https://pub.dev`)
///   3. Self-referential deps (`hosted: url: <SERVER_URL>`) after appending
///      the server URL to the policy's allowlist
///   4. Reject anything else.
void main() {
  Pubspec p(String body) => Pubspec.parse('''
name: example
version: 1.0.0
description: A package with deps to validate.
environment:
  sdk: ^3.0.0
dependencies:
$body
''');

  group('ReaderPolicy.isHostedUrlAllowed', () {
    final defaults = ReaderPolicy.club;

    test('default list accepts pub.dev and legacy alias', () {
      expect(defaults.isHostedUrlAllowed('https://pub.dev'), isTrue);
      expect(defaults.isHostedUrlAllowed('https://pub.dartlang.org'), isTrue);
    });

    test('normalises trailing slash, case, default port', () {
      expect(defaults.isHostedUrlAllowed('https://pub.dev/'), isTrue);
      expect(defaults.isHostedUrlAllowed('HTTPS://PUB.DEV'), isTrue);
      expect(defaults.isHostedUrlAllowed('https://pub.dev:443'), isTrue);
    });

    test('rejects non-default port', () {
      expect(defaults.isHostedUrlAllowed('https://pub.dev:8443'), isFalse);
    });

    test('rejects non-http schemes', () {
      expect(defaults.isHostedUrlAllowed('ftp://pub.dev'), isFalse);
      expect(defaults.isHostedUrlAllowed('file:///etc/passwd'), isFalse);
    });

    test('rejects third-party registries', () {
      expect(defaults.isHostedUrlAllowed('https://example.com'), isFalse);
    });

    test('extending via copyWith lets self-URL pass', () {
      final policy = ReaderPolicy.club.copyWith(
        allowedHostedUrls: [
          ...ReaderPolicy.club.allowedHostedUrls,
          'https://club.example.com',
        ],
      );
      expect(policy.isHostedUrlAllowed('https://club.example.com'), isTrue);
      expect(policy.isHostedUrlAllowed('https://club.example.com/'), isTrue);
      expect(policy.isHostedUrlAllowed('https://pub.dev'), isTrue);
      expect(policy.isHostedUrlAllowed('https://evil.example.com'), isFalse);
    });
  });

  group('forbidGitDependencies', () {
    Iterable<String> issues(Pubspec pubspec, ReaderPolicy policy) =>
        forbidGitDependencies(
          pubspec,
          allowGit: !policy.forbidGitDependencies,
          forbidNonDefaultHosted: policy.forbidNonDefaultHostedDependencies,
          allowedHostedUrls: policy.allowedHostedUrls,
          isHostedUrlAllowed: policy.isHostedUrlAllowed,
        ).map((e) => e.message);

    test('bare `foo: ^1.0.0` is accepted (default pub)', () {
      expect(
        issues(p('  http: ^1.0.0\n'), ReaderPolicy.club),
        isEmpty,
      );
    });

    test('explicit `hosted: https://pub.dev` is accepted', () {
      expect(
        issues(
          p('''  http:
    hosted:
      name: http
      url: https://pub.dev
    version: ^1.0.0
'''),
          ReaderPolicy.club,
        ),
        isEmpty,
      );
    });

    test('self-club-URL dep is accepted when included in allowlist', () {
      final policy = ReaderPolicy.club.copyWith(
        allowedHostedUrls: [
          ...ReaderPolicy.club.allowedHostedUrls,
          'https://club.example.com',
        ],
      );
      expect(
        issues(
          p('''  my_private:
    hosted:
      name: my_private
      url: https://club.example.com
    version: ^1.0.0
'''),
          policy,
        ),
        isEmpty,
      );
    });

    test('third-party host is rejected with a helpful message', () {
      final result = issues(
        p('''  some_pkg:
    hosted:
      name: some_pkg
      url: https://other-registry.example.com
    version: ^1.0.0
'''),
        ReaderPolicy.club,
      ).toList();
      expect(result, hasLength(1));
      expect(result.single, contains('other-registry.example.com'));
      expect(result.single, contains('allowed-hosts list'));
      expect(result.single, contains('pub.dev'));
    });

    test('name mismatch is rejected independently of URL check', () {
      final policy = ReaderPolicy.club.copyWith(
        allowedHostedUrls: [
          ...ReaderPolicy.club.allowedHostedUrls,
          'https://club.example.com',
        ],
      );
      final result = issues(
        p('''  my_private:
    hosted:
      name: totally_different
      url: https://club.example.com
    version: ^1.0.0
'''),
        policy,
      ).toList();
      expect(result, hasLength(1));
      expect(result.single, contains('does not match the dependency key'));
    });

    test('git dep still rejected under club policy', () {
      final result = issues(
        p('''  foo:
    git:
      url: https://github.com/example/foo
'''),
        ReaderPolicy.club,
      ).toList();
      expect(result, hasLength(1));
      expect(result.single, contains('git dependency'));
    });
  });
}
