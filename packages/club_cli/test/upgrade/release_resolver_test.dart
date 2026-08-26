import 'package:club_cli/src/upgrade/release_resolver.dart';
import 'package:test/test.dart';

void main() {
  Map<String, dynamic> releaseJson({
    String tag = 'v0.4.2',
    List<String> assets = const [],
    bool prerelease = false,
    bool draft = false,
  }) => {
    'tag_name': tag,
    'prerelease': prerelease,
    'draft': draft,
    'html_url': 'https://github.com/BirjuVachhani/club/releases/tag/$tag',
    'assets': [
      for (final a in assets) {'name': a, 'size': 1},
    ],
  };

  List<String> fullAssets(String version) => [
    'club-cli-$version-linux-x64.tar.gz',
    'club-cli-$version-linux-arm64.tar.gz',
    'club-cli-$version-macos-x64.tar.gz',
    'club-cli-$version-macos-arm64.tar.gz',
    'club-cli-$version-windows-x64.zip',
    'club-cli-$version-windows-arm64.zip',
    'SHA256SUMS.txt',
  ];

  group('parseRelease', () {
    test('reads the tag, version, and assets', () {
      final r = parseRelease(releaseJson(assets: fullAssets('0.4.2')))!;
      expect(r.tag, 'v0.4.2');
      expect(r.version, '0.4.2');
      expect(r.assetNames, contains('SHA256SUMS.txt'));
    });

    test('a bare tag with no leading v still yields a version', () {
      expect(parseRelease(releaseJson(tag: '0.4.2'))!.version, '0.4.2');
    });

    test('rejects a missing or empty tag_name', () {
      expect(parseRelease({'assets': <dynamic>[]}), isNull);
      expect(parseRelease({'tag_name': ''}), isNull);
      expect(parseRelease({'tag_name': 42}), isNull);
    });

    test('rejects a non-object', () {
      expect(parseRelease(<dynamic>[]), isNull);
      expect(parseRelease(null), isNull);
      expect(parseRelease('nope'), isNull);
    });

    test('stableOnly rejects a pre-release or draft', () {
      expect(
        parseRelease(releaseJson(prerelease: true), stableOnly: true),
        isNull,
      );
      expect(parseRelease(releaseJson(draft: true), stableOnly: true), isNull);
    });

    test('without stableOnly a pre-release parses fine', () {
      // The --pre path and --version both need to read pre-releases.
      expect(parseRelease(releaseJson(prerelease: true)), isNotNull);
    });

    test('tolerates a missing or malformed assets array', () {
      expect(parseRelease({'tag_name': 'v1.0.0'})!.assetNames, isEmpty);
      expect(
        parseRelease({'tag_name': 'v1.0.0', 'assets': 'nope'})!.assetNames,
        isEmpty,
      );
      expect(
        parseRelease({
          'tag_name': 'v1.0.0',
          'assets': [
            {'size': 1},
            'junk',
            {'name': 'ok.tar.gz'},
          ],
        })!.assetNames,
        {'ok.tar.gz'},
      );
    });
  });

  group('asset availability gate', () {
    ReleaseInfo release(List<String> assets, {String version = '0.4.2'}) =>
        parseRelease(releaseJson(tag: 'v$version', assets: assets))!;

    test('a fully uploaded release passes for every target', () {
      final r = release(fullAssets('0.4.2'));
      for (final target in releaseTargetsForTest) {
        expect(r.hasAssetsFor(target), isTrue, reason: target);
      }
    });

    test('an empty assets list fails', () {
      // The window right after a release is published but before the
      // build workflow has uploaded anything.
      expect(release([]).hasAssetsFor('macos-arm64'), isFalse);
    });

    test('fails when this target is missing but others are present', () {
      final r = release([
        'club-cli-0.4.2-linux-x64.tar.gz',
        'club-cli-0.4.2-macos-x64.tar.gz',
        'SHA256SUMS.txt',
      ]);
      expect(r.hasAssetsFor('macos-arm64'), isFalse);
      expect(r.hasAssetsFor('linux-x64'), isTrue);
    });

    test('fails when SHA256SUMS.txt is missing, even with every archive', () {
      // install.sh refuses to install without a checksum, so offering the
      // upgrade here would just fail later and more confusingly.
      final assets = fullAssets('0.4.2')..remove('SHA256SUMS.txt');
      final r = release(assets);
      expect(r.hasAssetsFor('macos-arm64'), isFalse);
    });

    test('a different target does not satisfy the query', () {
      final r = release([
        'club-cli-0.4.2-linux-x64.tar.gz',
        'SHA256SUMS.txt',
      ]);
      expect(r.hasAssetsFor('linux-arm64'), isFalse);
    });

    test('windows targets need .zip, not .tar.gz', () {
      for (final target in ['windows-x64', 'windows-arm64']) {
        final tarRelease = release([
          'club-cli-0.4.2-$target.tar.gz',
          'SHA256SUMS.txt',
        ]);
        expect(tarRelease.hasAssetsFor(target), isFalse, reason: target);
        expect(
          release([
            'club-cli-0.4.2-$target.zip',
            'SHA256SUMS.txt',
          ]).hasAssetsFor(target),
          isTrue,
          reason: target,
        );
      }
    });

    test('windows x64 archive does not satisfy windows arm64', () {
      final r = release([
        'club-cli-0.4.2-windows-x64.zip',
        'SHA256SUMS.txt',
      ]);
      expect(r.hasAssetsFor('windows-arm64'), isFalse);
    });

    test('the version in the asset name has to match the tag', () {
      final r = release(fullAssets('0.4.1'), version: '0.4.2');
      expect(
        r.hasAssetsFor('macos-arm64'),
        isFalse,
        reason: 'stale assets from a prior release must not satisfy the gate',
      );
    });
  });

  group('FakeReleaseResolver', () {
    test('returns the configured latest', () async {
      final info = parseRelease(releaseJson(assets: fullAssets('0.4.2')))!;
      final resolver = FakeReleaseResolver(latest: info);
      final result = await resolver.resolveLatest(includePreReleases: false);
      expect(result.ok, isTrue);
      expect(result.release!.version, '0.4.2');
    });

    test('reports no release when unset', () async {
      final result = await FakeReleaseResolver().resolveLatest(
        includePreReleases: false,
      );
      expect(result.ok, isFalse);
      expect(result.failure, ResolveFailure.noRelease);
    });

    test('resolveTag matches with or without a leading v', () async {
      final info = parseRelease(releaseJson(tag: 'v0.3.0'))!;
      final resolver = FakeReleaseResolver(byTag: {'v0.3.0': info});
      expect((await resolver.resolveTag('0.3.0')).ok, isTrue);
      expect((await resolver.resolveTag('v0.3.0')).ok, isTrue);
      expect((await resolver.resolveTag('9.9.9')).ok, isFalse);
    });
  });
}

const releaseTargetsForTest = [
  'linux-x64',
  'linux-arm64',
  'macos-x64',
  'macos-arm64',
  'windows-x64',
  'windows-arm64',
];
