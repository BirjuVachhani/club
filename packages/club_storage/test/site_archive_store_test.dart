import 'dart:io';
import 'package:club_core/club_core.dart';
import 'package:club_storage/club_storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late FilesystemSiteArchiveStore store;
  const site = SiteUpload(
    name: 'demo',
    part: 'site_0',
    length: 3,
    sha256: 'unused',
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('site-store-');
    store = FilesystemSiteArchiveStore(rootPath: '${root.path}/sites');
    await store.open();
    await File('${root.path}/site_0').writeAsString('old');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test('replaces complete set and explicit empty clears', () async {
    await store.replace('my_package', root.path, [site]);
    final file = File('${root.path}/sites/my_package/demo/site.tar.gz');
    expect(await file.readAsString(), 'old');
    await File('${root.path}/site_0').writeAsString('new');
    await store.replace('my_package', root.path, [site]);
    expect(await file.readAsString(), 'new');
    await store.replace('my_package', root.path, []);
    expect(await file.exists(), isFalse);
  });
  test('failed candidate copy preserves prior set', () async {
    await store.replace('my_package', root.path, [site]);
    await File('${root.path}/site_0').delete();
    await expectLater(
      store.replace('my_package', root.path, [site]),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await File(
        '${root.path}/sites/my_package/demo/site.tar.gz',
      ).readAsString(),
      'old',
    );
  });
  test('startup restores interrupted promotion', () async {
    await store.replace('my_package', root.path, [site]);
    await Directory(
      '${root.path}/sites/my_package',
    ).rename('${root.path}/sites/my_package.backup');
    await Directory('${root.path}/sites/my_package.candidate').create();
    await store.open();
    expect(
      await File(
        '${root.path}/sites/my_package/demo/site.tar.gz',
      ).readAsString(),
      'old',
    );
    expect(
      await Directory('${root.path}/sites/my_package.candidate').exists(),
      isFalse,
    );
  });
  test('delete rejects traversal and never follows package symlinks', () async {
    await expectLater(
      store.deletePackage('../outside'),
      throwsA(isA<InvalidInputException>()),
    );
    await Link('${root.path}/sites/my_package').create(root.path);
    await store.deletePackage('my_package');
    expect(await File('${root.path}/site_0').readAsString(), 'old');
  });
  test('switches between archive and URL without stale artifacts', () async {
    await store.replace('my_package', root.path, [site]);
    await store.replace('my_package', root.path, [
      const SiteUpload(name: 'demo', url: 'https://google.com'),
    ]);
    final directory = '${root.path}/sites/my_package/demo';
    expect(await File('$directory/site.tar.gz').exists(), isFalse);
    expect(
      await File('$directory/redirect.json').readAsString(),
      contains('https://google.com'),
    );
    await store.replace('my_package', root.path, [site]);
    expect(await File('$directory/redirect.json').exists(), isFalse);
    expect(await File('$directory/site.tar.gz').exists(), isTrue);
  });
  for (final hasLive in [false, true]) {
    test('delete clears recovery state with live=$hasLive', () async {
      await store.replace('my_package', root.path, [site]);
      await Directory(
        '${store.rootPath}/my_package',
      ).rename('${store.rootPath}/my_package.backup');
      if (hasLive) {
        await Directory(
          '${store.rootPath}/my_package/demo',
        ).create(recursive: true);
        await File(
          '${store.rootPath}/my_package/demo/redirect.json',
        ).writeAsString('{"url":"https://private.example"}');
      }
      await Directory(
        '${store.rootPath}/my_package.candidate/demo',
      ).create(recursive: true);
      await store.replace('other_package', root.path, [site]);
      await store.deletePackage('my_package');
      await store.deletePackage('my_package');
      await store.open();
      for (final suffix in ['', '.backup', '.candidate']) {
        expect(
          await Directory('${store.rootPath}/my_package$suffix').exists(),
          isFalse,
        );
      }
      expect(
        await Directory('${store.rootPath}/other_package/demo').exists(),
        isTrue,
      );
    });
  }
}
