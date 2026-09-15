import 'dart:io';

import 'package:club_api/club_api.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

import 'club_configs.dart';

/// Owns temporary site archives for one package publish.
class PreparedSites {
  PreparedSites(this.directory, this.attachments);

  final Directory directory;
  final List<SiteAttachment> attachments;

  Future<void> dispose() => directory.delete(recursive: true);
}

/// Builds all targets before validating and archiving their final output.
Future<PreparedSites> prepareSites(
  String packageRoot,
  ClubConfigs config,
) async {
  if (config.sites.length > 20) {
    throw const FormatException('A package can publish at most 20 sites.');
  }
  final scratch = await Directory.systemTemp.createTemp('club-sites-');
  try {
    for (final site in config.sites) {
      if (site.url != null || !site.requiresBuild) continue;
      stdout.writeln('Building site ${site.name}...');
      final shell =
          Platform.environment['SHELL'] ??
          (Platform.isWindows
              ? Platform.environment['COMSPEC'] ?? 'cmd.exe'
              : '/bin/sh');
      final script = site.build!;
      final shellName = p.basenameWithoutExtension(shell).toLowerCase();
      final List<String> args;
      if (Platform.isWindows && shellName == 'cmd') {
        final batch = File(p.join(scratch.path, '${site.name}.cmd'));
        await batch.writeAsString(
          '@echo off\r\n${script.replaceAll('\r\n', '\n').split('\n').map(
            (line) => '$line\r\nif errorlevel 1 exit /b %errorlevel%',
          ).join('\r\n')}',
        );
        args = ['/d', '/s', '/c', '"${batch.path}"'];
      } else if (shellName == 'pwsh' || shellName == 'powershell') {
        args = [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "\$ErrorActionPreference = 'Stop';\n$script\nif (\$LASTEXITCODE) { exit \$LASTEXITCODE }",
        ];
      } else if (['sh', 'bash', 'zsh', 'dash', 'ksh'].contains(shellName)) {
        args = ['-e', '-c', script];
      } else {
        throw FormatException(
          'Unsupported build shell "$shell". Set SHELL to a POSIX shell.',
        );
      }
      final process = await Process.start(
        shell,
        args,
        workingDirectory: packageRoot,
        mode: ProcessStartMode.inheritStdio,
      );
      final code = await process.exitCode;
      if (code != 0) {
        throw ProcessException(
          shell,
          args,
          'Site ${site.name} build failed.',
          code,
        );
      }
    }
    final attachments = <SiteAttachment>[];
    var compressedTotal = 0;
    for (final site in config.sites) {
      if (site.url != null) {
        attachments.add(SiteAttachment(name: site.name, url: site.url, label: site.label));
        continue;
      }
      final output = p.normalize(p.absolute(packageRoot, site.output!));
      if (await FileSystemEntity.type(output, followLinks: false) !=
              FileSystemEntityType.directory ||
          await FileSystemEntity.type(
                p.join(output, 'index.html'),
                followLinks: false,
              ) !=
              FileSystemEntityType.file) {
        throw FormatException(
          'Site ${site.name} output must be a directory containing a regular index.html: $output',
        );
      }
      final files = <File>[];
      var expanded = 0;
      await for (final entity in Directory(
        output,
      ).list(recursive: true, followLinks: false)) {
        if (entity is Directory) continue;
        if (entity is! File ||
            await FileSystemEntity.type(entity.path, followLinks: false) !=
                FileSystemEntityType.file) {
          throw FormatException(
            'Site ${site.name} contains a link or special file: ${entity.path}',
          );
        }
        expanded += await entity.length();
        files.add(entity);
        if (files.length > 10000 || expanded > 500 * 1024 * 1024) {
          throw FormatException(
            'Site ${site.name} exceeds the expanded size or file count limit.',
          );
        }
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      final archive = File(p.join(scratch.path, '${site.name}.tar.gz'));
      final entries = Stream.fromIterable(files).asyncMap((file) async {
        final stat = await file.stat();
        final name = p
            .relative(file.path, from: output)
            .split(p.separator)
            .join('/');
        if (name.contains('\\') || name.contains(':')) {
          throw FormatException('Unsafe site archive path: $name');
        }
        return TarEntry(
          TarHeader(
            name: name,
            size: stat.size,
            mode: 0x1a4,
            modified: stat.modified,
            typeFlag: TypeFlag.reg,
          ),
          file.openRead(),
        );
      });
      await entries
          .transform(tarWriterWith(format: OutputFormat.gnuLongName))
          .transform(gzip.encoder)
          .pipe(archive.openWrite());
      final size = await archive.length();
      compressedTotal += size;
      if (size > 100 * 1024 * 1024 || compressedTotal > 500 * 1024 * 1024) {
        throw FormatException(
          'Site ${site.name} exceeds the compressed archive limit.',
        );
      }
      attachments.add(SiteAttachment(name: site.name, file: archive, label: site.label));
    }
    return PreparedSites(scratch, attachments);
  } catch (_) {
    await scratch.delete(recursive: true);
    rethrow;
  }
}
