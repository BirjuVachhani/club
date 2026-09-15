import 'dart:io';

import 'package:club_cli/src/publish/club_configs.dart';
import 'package:club_cli/src/publish/site_builder.dart';
import 'package:club_cli/src/publish/publish_runner.dart';
import 'package:tar/tar.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sites-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  Future<void> index(String name) async {
    final file = File('${root.path}/$name/index.html');
    await file.parent.create(recursive: true);
    await file.writeAsString('<h1>$name</h1>');
  }

  test('archives all sites with index at archive root', () async {
    await index('one');
    await index('two');
    final prepared = await prepareSites(
      root.path,
      ClubConfigs(
        sites: [
          SiteTarget(name: 'demo', output: 'one'),
          SiteTarget(name: 'docs', output: '${root.path}/two'),
        ],
      ),
    );
    try {
      expect(prepared.attachments.length, 2);
      for (final attachment in prepared.attachments) {
        final reader = TarReader(
          attachment.file!.openRead().transform(gzip.decoder),
        );
        try {
          expect(await reader.moveNext(), isTrue);
          expect(reader.current.name, 'index.html');
          await reader.current.contents.drain<void>();
          expect(await reader.moveNext(), isFalse);
        } finally {
          await reader.cancel();
        }
      }
    } finally {
      await prepared.dispose();
    }
    expect(await prepared.directory.exists(), isFalse);
  });
  test('missing second output aborts the complete preparation', () async {
    await index('one');
    await expectLater(
      prepareSites(
        root.path,
        ClubConfigs(
          sites: [
            SiteTarget(name: 'demo', output: 'one'),
            SiteTarget(name: 'docs', output: 'missing'),
          ],
        ),
      ),
      throwsFormatException,
    );
  });
  test('multiline build executes from package root and fails fast', () async {
    final config = ClubConfigs(
      sites: [
        SiteTarget(
          name: 'demo',
          output: 'out',
          build: 'mkdir out\nprintf test > out/index.html\nfalse\nprintf bad > marker',
        ),
      ],
    );
    await expectLater(
      prepareSites(root.path, config),
      throwsA(isA<ProcessException>()),
    );
    expect(await File('${root.path}/out/index.html').exists(), isTrue);
    expect(await File('${root.path}/marker').exists(), isFalse);
  }, skip: Platform.isWindows);
  test('rejects symlinked contents', () async {
    await index('one');
    await Link('${root.path}/one/link').create('${root.path}/one/index.html');
    await expectLater(
      prepareSites(
        root.path,
        ClubConfigs(
          sites: [
            SiteTarget(name: 'demo', output: 'one'),
          ],
        ),
      ),
      throwsFormatException,
    );
  }, skip: Platform.isWindows);
  test(
    'archive export with sites is rejected before creating output',
    () async {
      await File('${root.path}/club.yaml').writeAsString('sites: {}');
      final archive = '${root.path}/package.tar.gz';
      await expectLater(
        PublishRunner(PublishOptions(directory: root.path, toArchive: archive))
            .run(),
        throwsFormatException,
      );
      expect(await File(archive).exists(), isFalse);
    },
  );
  test('URL target needs no output or build', () async {
    final prepared = await prepareSites(
      root.path,
      ClubConfigs.fromYaml('sites: {demo: {url: https://google.com}}')!,
    );
    try {
      expect(prepared.attachments.single.url, 'https://google.com');
      expect(prepared.attachments.single.file, isNull);
    } finally {
      await prepared.dispose();
    }
  });
}
