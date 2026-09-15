import 'dart:io';
import 'package:club_core/club_core.dart';
import 'package:club_server/src/sites/archive_validator.dart';
import 'package:tar/tar.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('site-validation-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  Future<File> archive(List<String> names) async {
    final file = File('${dir.path}/site.tar.gz');
    await Stream.fromIterable(
      names.map(
        (name) => TarEntry(
          TarHeader(name: name, size: 2, mode: 420, typeFlag: TypeFlag.reg),
          Stream.value([104, 105]),
        ),
      ),
    ).transform(tarWriter).transform(gzip.encoder).pipe(file.openWrite());
    return file;
  }

  test('accepts root index and nested files', () async {
    await validateSiteArchive(
      await archive(['index.html', 'assets/a.js']),
      const SiteLimits(),
    );
  });
  for (final names in [
    ['other.html'],
    ['../index.html'],
    ['/index.html'],
    ['index.html', 'index.html'],
    ['index.html', 'a', 'a/b'],
    ['index.html', r'a\b'],
  ]) {
    test('rejects unsafe archive $names', () async {
      await expectLater(
        validateSiteArchive(await archive(names), const SiteLimits()),
        throwsA(isA<InvalidInputException>()),
      );
    });
  }
  test('enforces expansion limit during decompression', () async {
    await expectLater(
      validateSiteArchive(
        await archive(['index.html']),
        const SiteLimits(expandedBytes: 100),
      ),
      throwsA(isA<InvalidInputException>()),
    );
  });
}
