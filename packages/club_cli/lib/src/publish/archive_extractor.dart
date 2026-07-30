/// Unpacks a package `.tar.gz` into a scratch directory.
///
/// The inverse of [TarballBuilder]. Used by the isolated dependency
/// resolution step so `pub get` runs against exactly the bytes that will be
/// uploaded, rather than against the source tree the archive came from.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

/// Raised when an archive entry cannot be written safely.
class ArchiveExtractionError implements Exception {
  ArchiveExtractionError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Extracts the gzipped tar at [archivePath] into a fresh temporary directory
/// and returns that directory.
///
/// The caller owns the returned directory and must delete it.
///
/// Only regular files are materialised. Symlinks, hardlinks, devices, and
/// directory entries are skipped: pub archives are flat lists of regular
/// files, and honouring links would let an archive write outside the
/// extraction root. Entry names are additionally validated so a crafted
/// `../` or absolute path cannot escape.
Future<Directory> extractPackageArchive(String archivePath) async {
  final dir = await Directory.systemTemp.createTemp('club-publish-resolve-');
  try {
    final reader = TarReader(
      File(archivePath).openRead().transform(gzip.decoder),
    );
    try {
      while (await reader.moveNext()) {
        final entry = reader.current;
        if (entry.header.typeFlag != TypeFlag.reg &&
            entry.header.typeFlag != TypeFlag.regA) {
          continue;
        }
        final target = _safeJoin(dir.path, entry.name);
        final file = File(target);
        await file.parent.create(recursive: true);
        final sink = file.openWrite();
        await entry.contents.pipe(sink);
      }
    } finally {
      await reader.cancel();
    }
    return dir;
  } on Object {
    // Never leave a half-written scratch directory behind.
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup.
    }
    rethrow;
  }
}

/// Resolves [name] against [root], refusing anything that escapes it.
String _safeJoin(String root, String name) {
  final posixName = name.replaceAll(r'\', '/');
  if (p.posix.isAbsolute(posixName) || posixName.startsWith('/')) {
    throw ArchiveExtractionError(
      'Archive entry "$name" uses an absolute path.',
    );
  }
  final joined = p.normalize(p.join(root, p.joinAll(p.posix.split(posixName))));
  if (!p.isWithin(root, joined)) {
    throw ArchiveExtractionError(
      'Archive entry "$name" resolves outside the extraction directory.',
    );
  }
  return joined;
}
