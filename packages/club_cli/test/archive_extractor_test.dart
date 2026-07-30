import 'dart:convert';
import 'dart:io';

import 'package:club_cli/src/publish/archive_extractor.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('club-extract-test-');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Writes a `.tar.gz` containing [files] (name → content) plus any extra
  /// [entries] and returns its path.
  Future<String> makeArchive(
    Map<String, String> files, {
    List<TarEntry> entries = const [],
  }) async {
    final path = p.join(tmp.path, 'pkg.tar.gz');
    final all = <TarEntry>[
      for (final e in files.entries)
        TarEntry(
          TarHeader(
            name: e.key,
            size: utf8.encode(e.value).length,
            mode: 0x1A4,
            typeFlag: TypeFlag.reg,
          ),
          Stream.value(utf8.encode(e.value)),
        ),
      ...entries,
    ];
    final sink = File(path).openWrite();
    await Stream.fromIterable(all)
        .transform(tarWriterWith(format: OutputFormat.gnuLongName))
        .transform(gzip.encoder)
        .pipe(sink);
    return path;
  }

  test('extracts files into a fresh directory, preserving nesting', () async {
    final archive = await makeArchive({
      'pubspec.yaml': 'name: auth_kit\n',
      'lib/auth_kit.dart': 'void main() {}\n',
      'lib/src/state/auth_state.dart': '// state\n',
      'README.md': '# auth_kit\n',
    });

    final dir = await extractPackageArchive(archive);
    addTearDown(() => dir.deleteSync(recursive: true));

    expect(
      File(p.join(dir.path, 'pubspec.yaml')).readAsStringSync(),
      'name: auth_kit\n',
    );
    expect(
      File(p.join(dir.path, 'lib', 'src', 'state', 'auth_state.dart'))
          .readAsStringSync(),
      '// state\n',
    );
    expect(File(p.join(dir.path, 'README.md')).existsSync(), isTrue);
  });

  test('each call gets its own directory', () async {
    final archive = await makeArchive({'pubspec.yaml': 'name: a\n'});
    final a = await extractPackageArchive(archive);
    final b = await extractPackageArchive(archive);
    addTearDown(() {
      a.deleteSync(recursive: true);
      b.deleteSync(recursive: true);
    });
    expect(a.path, isNot(b.path));
  });

  test('refuses an entry that escapes the extraction root', () async {
    final archive = await makeArchive({
      'pubspec.yaml': 'name: a\n',
      '../escaped.dart': 'gotcha\n',
    });

    await expectLater(
      extractPackageArchive(archive),
      throwsA(isA<ArchiveExtractionError>()),
    );
    expect(File(p.join(tmp.parent.path, 'escaped.dart')).existsSync(), isFalse);
  });

  test('refuses an absolute entry name', () async {
    final archive = await makeArchive({
      'pubspec.yaml': 'name: a\n',
      '/etc/club-probe': 'gotcha\n',
    });

    await expectLater(
      extractPackageArchive(archive),
      throwsA(isA<ArchiveExtractionError>()),
    );
  });

  test('skips symlink entries rather than following them', () async {
    final archive = await makeArchive(
      {'pubspec.yaml': 'name: a\n'},
      entries: [
        TarEntry(
          TarHeader(
            name: 'evil-link',
            size: 0,
            mode: 0x1A4,
            typeFlag: TypeFlag.symlink,
            linkName: '/etc/passwd',
          ),
          const Stream.empty(),
        ),
      ],
    );

    final dir = await extractPackageArchive(archive);
    addTearDown(() => dir.deleteSync(recursive: true));

    expect(Link(p.join(dir.path, 'evil-link')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'evil-link')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'pubspec.yaml')).existsSync(), isTrue);
  });

  test('leaves no scratch directory behind when extraction fails', () async {
    final before = Directory.systemTemp
        .listSync()
        .whereType<Directory>()
        .where((d) => p.basename(d.path).startsWith('club-publish-resolve-'))
        .length;

    final archive = await makeArchive({'../escaped.dart': 'gotcha\n'});
    await expectLater(
      extractPackageArchive(archive),
      throwsA(isA<ArchiveExtractionError>()),
    );

    final after = Directory.systemTemp
        .listSync()
        .whereType<Directory>()
        .where((d) => p.basename(d.path).startsWith('club-publish-resolve-'))
        .length;
    expect(after, before);
  });
}
