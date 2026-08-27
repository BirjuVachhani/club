import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Directory createWorkspace(Map<String, String> manifests) {
  final root = Directory.systemTemp.createTempSync('club-set-version-test-');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  for (final entry in manifests.entries) {
    final file = File(p.join(root.path, entry.key));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  return root;
}

String readManifest(Directory root, String relativePath) =>
    File(p.join(root.path, relativePath)).readAsStringSync();
