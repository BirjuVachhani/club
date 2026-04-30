/// Pre-flight tarball sizer used by `club prepare` and
/// `club publish --auto`.
///
/// For each package in the publish closure (excluding skip-marked ones),
/// builds the would-be `.tar.gz` to a temp file, captures the compressed
/// size + file count, then deletes the temp file. The numbers feed into
/// the plan preview so the user can spot a package that will hit the
/// server's archive-size limit *before* committing to a publish.
///
/// Building a tarball is not free — it walks the package tree, applies
/// `.pubignore` / `.gitignore` filters, and gzips the result. For typical
/// monorepos (a handful of small packages) it adds < 1s. For large
/// workspaces the caller may want to surface progress via [onProgress].
library;

import 'dart:io';

import '../publish/tarball_builder.dart';
import 'package_discovery.dart';

/// Compressed-size measurement for a single package.
class TarballSize {
  TarballSize({
    required this.packageName,
    required this.bytes,
    required this.fileCount,
    this.error,
  });

  final String packageName;
  final int bytes;
  final int fileCount;

  /// Set when the build failed (couldn't archive the package). [bytes] /
  /// [fileCount] are 0 in that case.
  final String? error;

  bool get failed => error != null;
}

/// Build a tarball-to-tempfile for each [package] and return the resulting
/// sizes. Temp files are deleted before return; partial failures surface as
/// [TarballSize.error] rather than throwing.
///
/// [pubspecOverrides], when provided, supplies a per-package full-pubspec
/// replacement string (keyed by package name). The on-disk pubspec is not
/// read for any package that has an override entry. Used by
/// `club publish --auto` so the size measurement matches the bytes that
/// will actually upload, even though no rewrite has been written to disk.
///
/// [onProgress] is invoked once per package before the build starts so the
/// caller can render a "measuring …" line.
Future<List<TarballSize>> measureTarballs({
  required List<DiscoveredPackage> packages,
  Map<String, String>? pubspecOverrides,
  void Function(String packageName)? onProgress,
}) async {
  final results = <TarballSize>[];
  for (final pkg in packages) {
    onProgress?.call(pkg.name);
    String? builtPath;
    try {
      final built = await TarballBuilder(pkg.directory).build(
        pubspecOverride: pubspecOverrides?[pkg.name],
      );
      builtPath = built.path;
      results.add(
        TarballSize(
          packageName: pkg.name,
          bytes: built.sizeBytes,
          fileCount: built.files.length,
        ),
      );
    } catch (e) {
      results.add(
        TarballSize(
          packageName: pkg.name,
          bytes: 0,
          fileCount: 0,
          error: e.toString(),
        ),
      );
    } finally {
      if (builtPath != null) {
        try {
          File(builtPath).deleteSync();
        } catch (_) {
          // Best-effort cleanup; the OS clears systemTemp eventually.
        }
      }
    }
  }
  return results;
}

/// Format an integer byte count as a short human-readable string. Mirrors
/// the formatter in publish_runner so size lines look identical across the
/// CLI.
String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '$bytes B';
}

/// Render a compact size table for the prepare/auto-publish plan preview.
/// Two columns: package name (left-aligned), then `<files> files / <size>`
/// (right-aligned). Failed measurements are flagged in red.
void printTarballSizeTable(
  List<TarballSize> sizes, {
  required void Function(String) write,
  String Function(String)? red,
  String Function(String)? gray,
  String Function(String)? bold,
}) {
  String identity(String s) => s;
  final r = red ?? identity;
  final g = gray ?? identity;
  final b = bold ?? identity;

  final widestName =
      sizes.map((s) => s.packageName.length).fold<int>(0, (m, l) => l > m ? l : m);
  final widestFiles = sizes
      .map((s) => '${s.fileCount}'.length)
      .fold<int>(0, (m, l) => l > m ? l : m);
  final widestSize = sizes
      .map((s) => formatBytes(s.bytes).length)
      .fold<int>(0, (m, l) => l > m ? l : m);

  for (final s in sizes) {
    final name = s.packageName.padRight(widestName);
    if (s.failed) {
      write('   $name  ${r('build failed: ${s.error}')}');
      continue;
    }
    final files = '${s.fileCount}'.padLeft(widestFiles);
    final size = formatBytes(s.bytes).padLeft(widestSize);
    write('   $name  ${g('$files files')}  $size');
  }

  final totalBytes = sizes.fold<int>(0, (sum, s) => sum + s.bytes);
  final totalFiles = sizes.fold<int>(0, (sum, s) => sum + s.fileCount);
  if (sizes.length > 1) {
    write(
      '   ${g('─' * widestName)}  ${g('${'$totalFiles'.padLeft(widestFiles)} files')}'
      '  ${b(formatBytes(totalBytes).padLeft(widestSize))}',
    );
  }
}
