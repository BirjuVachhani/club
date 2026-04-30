// Extracts a cached pub.dev tarball into work/, runs `dart pub get`, then
// `dart doc` to produce the baseline (un-themed) static site at
// work/<package>/doc/api/.
//
// Usage: dart run bin/setup.dart [package_name] [version]
// Defaults: go_router 17.2.2 — already cached under
// ../../dummy_data/.tarball_cache/.

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final pkg = args.isNotEmpty ? args[0] : 'go_router';
  final version = args.length > 1 ? args[1] : '17.2.2';

  final scriptDir = p.dirname(Platform.script.toFilePath());
  final root = p.normalize(p.join(scriptDir, '..'));
  final repoRoot = p.normalize(p.join(root, '..', '..'));

  final tarball = File(p.join(
    repoRoot,
    'dummy_data',
    '.tarball_cache',
    '$pkg-$version.tar.gz',
  ));
  if (!tarball.existsSync()) {
    stderr.writeln('Tarball not found: ${tarball.path}');
    stderr.writeln('Either download it manually or pick a cached version.');
    exit(1);
  }

  final workDir = Directory(p.join(root, 'work', '$pkg-$version'));
  if (workDir.existsSync()) {
    stdout.writeln('Cleaning existing work dir: ${workDir.path}');
    workDir.deleteSync(recursive: true);
  }
  workDir.createSync(recursive: true);

  stdout.writeln('Extracting ${tarball.path} → ${workDir.path}');
  await extractFileToDisk(tarball.path, workDir.path);

  stdout.writeln('\nRunning `dart pub get`...');
  final pubGet = await Process.start(
    'dart',
    ['pub', 'get'],
    workingDirectory: workDir.path,
    mode: ProcessStartMode.inheritStdio,
  );
  final pubExit = await pubGet.exitCode;
  if (pubExit != 0) {
    stderr.writeln('`dart pub get` failed.');
    exit(pubExit);
  }

  stdout.writeln('\nRunning `dart doc`...');
  final doc = await Process.start(
    'dart',
    ['doc', '--output', 'doc/api'],
    workingDirectory: workDir.path,
    mode: ProcessStartMode.inheritStdio,
  );
  final docExit = await doc.exitCode;
  if (docExit != 0) {
    stderr.writeln('`dart doc` failed.');
    exit(docExit);
  }

  final apiDir = p.join(workDir.path, 'doc', 'api');
  stdout.writeln('\n✓ Baseline dartdoc generated at: $apiDir');
  stdout.writeln('  Serve with: dart run bin/serve.dart baseline');
  stdout.writeln('  Theme it with: dart run bin/theme.dart');
}
