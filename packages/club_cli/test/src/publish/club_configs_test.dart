import 'package:club_cli/src/publish/club_configs.dart';
import 'package:test/test.dart';

void main() {
  group('ClubConfigs.fromYaml', () {
    test('distinguishes absent sites from an explicitly empty set', () {
      expect(ClubConfigs.fromYaml(''), isNull);
      expect(ClubConfigs.fromYaml('{}'), isNull);
      expect(ClubConfigs.fromYaml('sites: {}')!.sites, isEmpty);
    });

    test('JSON serialization preserves named target mapping', () {
      final input = <String, dynamic>{
        'sites': {
          'demo': {'output': 'dist', 'build': 'build'},
        },
      };
      expect(ClubConfigs.fromJson(input).toJson(), input);
    });

    test('reads named targets and preserves multiline build scripts', () {
      final config = ClubConfigs.fromYaml('''
sites:
  demo:
    build: |
      cd example
      flutter build web
    output: example/build/web
  docs:
    output: /tmp/site
''')!;
      expect(config.sites.map((site) => site.name), ['demo', 'docs']);
      expect(config.sites.first.build, 'cd example\nflutter build web\n');
      expect(config.sites.first.requiresBuild, isTrue);
      expect(config.sites.last.requiresBuild, isFalse);
      expect(config.sites.last.output, '/tmp/site');
    });

    for (final source in [
      'sites: []',
      'sites: {demo: null}',
      'sites: {../demo: {output: dist}}',
      'sites: {demo: {output: dist}, Demo: {output: other}}',
      'sites: {demo: {output: ""}}',
      'sites: {demo: {output: 12}}',
      'sites: {demo: {output: dist, build: []}}',
      'sites: {demo: {output: dist, typo: true}}',
    ]) {
      test('rejects malformed configuration: $source', () {
        expect(() => ClubConfigs.fromYaml(source), throwsFormatException);
      });
    }
  });
  test('URL targets serialize without output', () {
    final config = ClubConfigs.fromYaml(
      'sites: {demo: {url: https://google.com}}',
    )!;
    expect(config.toJson(), {
      'sites': {
        'demo': {'url': 'https://google.com'},
      },
    });
    expect(ClubConfigs.fromJson(config.toJson()), config);
  });
  test('rejects unsafe URLs and mixed targets', () {
    for (final target in [
      'url: javascript:alert(1)',
      'url: /relative',
      'url: https://user:pass@example.com',
      'url: https://example.com, output: dist',
      'url: https://example.com, build: echo',
    ]) {
      expect(
        () => ClubConfigs.fromYaml('sites: {demo: {$target}}'),
        throwsFormatException,
      );
    }
  });
  test('labels round trip for URL and archive targets', () {
    final config = ClubConfigs.fromYaml(
      'sites: {demo: {output: dist, label: Live demo}, home: {url: https://example.com, label: Website}}',
    )!;
    expect(config.sites.map((s) => s.label), ['Live demo', 'Website']);
    expect(ClubConfigs.fromJson(config.toJson()), config);
    expect(
      () => ClubConfigs.fromYaml(
        'sites: {home: {url: https://example.com, label: ""}}',
      ),
      throwsFormatException,
    );
  });
}
