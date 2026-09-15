import 'dart:io';
import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:path/path.dart' as p;

/// Local site storage. A backup directory is the recovery journal.
///
/// Promotion states are candidate + old live, candidate + backup, or new live
/// + backup. Recovery restores backup when live is absent, otherwise keeps live.
class FilesystemSiteArchiveStore implements SiteArchiveStore {
  FilesystemSiteArchiveStore({required this.rootPath});
  final String rootPath;

  @override
  Future<void> open() async {
    final root = Directory(rootPath);
    await root.create(recursive: true);
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.backup')) {
        final live = Directory(
          p.join(rootPath, name.substring(0, name.length - 7)),
        );
        if (await live.exists()) {
          await entity.delete(recursive: true);
        } else {
          await entity.rename(live.path);
        }
      }
    }
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory &&
          p.basename(entity.path).endsWith('.candidate')) {
        await entity.delete(recursive: true);
      }
    }
  }

  @override
  Future<void> deletePackage(String package) async {
    if (PackageNameValidator.validate(package) != null) {
      throw const InvalidInputException(
        'Invalid package name for site storage.',
      );
    }
    final live = p.join(rootPath, package);
    // Remove recovery state first: an interrupted delete must never leave a
    // backup that open() can restore after the package name has been released.
    for (final path in ['$live.candidate', '$live.backup', live]) {
      switch (await FileSystemEntity.type(path, followLinks: false)) {
        case FileSystemEntityType.directory:
          await Directory(path).delete(recursive: true);
        case FileSystemEntityType.link:
          await Link(path).delete();
        case FileSystemEntityType.notFound:
          break;
        default:
          await File(path).delete();
      }
    }
  }

  @override
  Future<void> replace(
    String package,
    String sourceDirectory,
    List<SiteUpload> sites,
  ) async {
    if (PackageNameValidator.validate(package) != null) {
      throw const InvalidInputException(
        'Invalid package name for site storage.',
      );
    }
    final live = Directory(p.join(rootPath, package));
    final candidate = Directory('${live.path}.candidate');
    final backup = Directory('${live.path}.backup');
    // A prior successful promotion can leave its backup if cleanup failed.
    if (await backup.exists()) {
      if (!await live.exists()) {
        await backup.rename(live.path);
      } else {
        await backup.delete(recursive: true);
      }
    }
    if (await candidate.exists()) await candidate.delete(recursive: true);
    await candidate.create(recursive: true);
    var movedOld = false;
    try {
      for (final site in sites) {
        if (!SiteUpload.validName(site.name)) {
          throw const InvalidInputException('Invalid site name.');
        }
        if (site.label != null) {
          if (site.label!.trim().isEmpty || site.label!.length > 200) {
            throw const InvalidInputException('Invalid site label.');
          }
          final metadata = File(
            p.join(candidate.path, site.name, 'metadata.json'),
          );
          await metadata.parent.create(recursive: true);
          await metadata.writeAsString(
            jsonEncode({'label': site.label}),
            flush: true,
          );
        }
        if (site.url != null) {
          if (!SiteUpload.validName(site.name) ||
              !SiteUpload.validUrl(site.url!)) {
            throw const InvalidInputException('Invalid URL site target.');
          }
          final file = File(p.join(candidate.path, site.name, 'redirect.json'));
          await file.parent.create(recursive: true);
          await file.writeAsString(jsonEncode({'url': site.url}), flush: true);
          continue;
        }
        if (!SiteUpload.validName(site.name) ||
            !RegExp(r'^site_[0-9]+$').hasMatch(site.part ?? '')) {
          throw const InvalidInputException('Invalid site storage key.');
        }
        final output = File(p.join(candidate.path, site.name, 'site.tar.gz'));
        await output.parent.create(recursive: true);
        await File(
          p.join(sourceDirectory, site.part!),
        ).openRead().pipe(output.openWrite());
      }
      if (await live.exists()) {
        await live.rename(backup.path);
        movedOld = true;
      }
      await candidate.rename(live.path);
    } catch (_) {
      if (movedOld && !await live.exists()) await backup.rename(live.path);
      if (await candidate.exists()) await candidate.delete(recursive: true);
      rethrow;
    }
    // Promotion is committed. Failed garbage collection must not report that
    // the publish failed after the new complete set became active.
    if (await backup.exists()) {
      try {
        await backup.delete(recursive: true);
      } on FileSystemException {
        /* Recovered on next open. */
      }
    }
  }
}
