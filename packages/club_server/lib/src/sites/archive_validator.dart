import 'dart:io';

import 'package:club_core/club_core.dart';
import 'package:tar/tar.dart';

/// Checks untrusted tar.gz bytes without extracting or executing site content.
Future<void> validateSiteArchive(File archive, SiteLimits limits) async {
  var expanded = 0;
  Stream<List<int>> bounded(Stream<List<int>> input) async* {
    await for (final chunk in input) {
      expanded += chunk.length;
      if (expanded > limits.expandedBytes) {
        throw const InvalidInputException(
          'Expanded site archive exceeds limit.',
        );
      }
      yield chunk;
    }
  }

  final reader = TarReader(bounded(archive.openRead().transform(gzip.decoder)));
  final paths = <String>{};
  final files = <String>{};
  var hasIndex = false;
  try {
    while (await reader.moveNext()) {
      final entry = reader.current;
      final directory = entry.header.typeFlag == TypeFlag.dir;
      var name = entry.name;
      if (directory && name.endsWith('/')) {
        name = name.substring(0, name.length - 1);
      }
      if (name.isEmpty ||
          name.contains('\\') ||
          name.contains(':') ||
          name.contains('\x00') ||
          name.split('/').any((s) => s.isEmpty || s == '.' || s == '..') ||
          !paths.add(name) ||
          paths.length > limits.entries) {
        throw const InvalidInputException(
          'Unsafe or duplicate site archive path.',
        );
      }
      if (!directory &&
          entry.header.typeFlag != TypeFlag.reg &&
          entry.header.typeFlag != TypeFlag.regA) {
        throw const InvalidInputException(
          'Site archives may only contain regular files and directories.',
        );
      }
      if (!directory) files.add(name);
      if (name == 'index.html' && !directory) hasIndex = true;
      if (entry.header.size > limits.expandedBytes) {
        throw const InvalidInputException(
          'Site archive entry exceeds size limit.',
        );
      }
      await entry.contents.drain<void>();
    }
    for (final path in paths) {
      final segments = path.split('/');
      for (var i = 1; i < segments.length; i++) {
        if (files.contains(segments.take(i).join('/'))) {
          throw const InvalidInputException(
            'Site archive contains conflicting file paths.',
          );
        }
      }
    }
    if (!hasIndex) {
      throw const InvalidInputException(
        'Site archive requires a root index.html.',
      );
    }
  } finally {
    await reader.cancel();
  }
}
