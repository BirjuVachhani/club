/// Builds a `.tar.gz` archive of a package directory, ready to upload.
///
/// Mirrors the role of dart pub's
/// [`createTarGz`](https://github.com/dart-lang/pub/blob/master/lib/src/io.dart)
/// — collect the file list (respecting ignore rules), tar them, gzip the
/// stream.
///
/// We use the official `tar` package (the same one club_server uses for
/// extraction) so the on-the-wire format is bit-compatible with what dart
/// pub produces.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

import 'ignore_filter.dart';

/// Result of [TarballBuilder.build].
class BuiltTarball {
  BuiltTarball({
    required this.path,
    required this.sizeBytes,
    required this.files,
  });

  /// Absolute path to the `.tar.gz` file on disk.
  final String path;

  /// Compressed size in bytes (used by SizeValidator).
  final int sizeBytes;

  /// Relative paths of every file included in the archive (sorted).
  final List<String> files;
}

/// Builds package archives.
class TarballBuilder {
  TarballBuilder(this.packageRoot);

  /// Absolute path of the package being archived.
  final String packageRoot;

  /// Build the archive and write it to [outputPath].
  ///
  /// If [outputPath] is null, a temporary file is created and its path is
  /// returned. Caller is responsible for cleanup if they want to delete it.
  Future<BuiltTarball> build({
    String? outputPath,
    String? versionOverride,
  }) async {
    final filter = IgnoreFilter.forPackage(packageRoot);
    // [listFiles] already returns POSIX paths relative to the package root,
    // sorted.
    final relFiles = filter.listFiles();

    final outFile = File(
      outputPath ??
          p.join(
            Directory.systemTemp.path,
            'club-publish-${DateTime.now().microsecondsSinceEpoch}.tar.gz',
          ),
    );

    // Stream of TarEntry objects.
    final entries = Stream<TarEntry>.fromIterable(
      relFiles.map((rel) {
        final abs = p.join(packageRoot, rel);
        final stat = File(abs).statSync();
        final posixName = rel.replaceAll(r'\', '/');

        // When a version override is set, rewrite the version field in
        // pubspec.yaml so the tarball carries the overridden version.
        // Source files on disk are left untouched.
        if (versionOverride != null && posixName == 'pubspec.yaml') {
          final original = File(abs).readAsStringSync();
          final versionPattern = RegExp(r'^version:\s*.+$', multiLine: true);
          if (!versionPattern.hasMatch(original)) {
            throw FormatException(
              'pubspec.yaml does not contain a version: field — '
              'cannot apply --version override.',
            );
          }
          final patched = original.replaceFirst(
            versionPattern,
            'version: $versionOverride',
          );
          final bytes = utf8.encode(patched);
          return TarEntry(
            TarHeader(
              name: posixName,
              size: bytes.length,
              mode: 0x1A4, // 0644
              modified: stat.modified,
              typeFlag: TypeFlag.reg,
            ),
            Stream.value(bytes),
          );
        }

        return TarEntry(
          TarHeader(
            // Use forward slashes on every platform — tar paths are POSIX.
            name: posixName,
            size: stat.size,
            mode: 0x1A4, // 0644
            modified: stat.modified,
            typeFlag: TypeFlag.reg,
          ),
          File(abs).openRead(),
        );
      }),
    );

    // tarWriterWith ensures we set OutputFormat to PAX when needed; gzip
    // happens via dart:io's GZipCodec.
    final sink = outFile.openWrite();
    await entries
        .transform(tarWriterWith(format: OutputFormat.gnuLongName))
        .transform(gzip.encoder)
        .pipe(sink);

    final size = await outFile.length();
    return BuiltTarball(path: outFile.path, sizeBytes: size, files: relFiles);
  }
}
