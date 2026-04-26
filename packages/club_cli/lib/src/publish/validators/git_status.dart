/// Mirrors dart pub's
/// [`GitStatusValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/git_status.dart):
/// warns when the working tree has uncommitted changes.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'validator.dart';

class GitStatusValidator extends Validator {
  GitStatusValidator(super.context);

  @override
  String get name => 'GitStatusValidator';

  @override
  Future<void> validate() async {
    final dir = context.pubspec.directory;
    final repoRoot = await _repoRoot(dir);
    if (repoRoot == null) return;

    final ProcessResult result;
    try {
      result = await Process.run(
        'git',
        ['status', '-z', '--no-renames', '--untracked-files=no'],
        workingDirectory: dir,
      );
    } on ProcessException {
      return;
    }
    if (result.exitCode != 0) return;

    final published = context.tarball.files
        .map((rel) => p.normalize(p.join(dir, rel)))
        .toSet();

    // Each git status -z record is: XY SP path\0 (prefix length 3). We split
    // on NUL, drop empty trailing, and strip the 3-byte status prefix from
    // each record.
    final modified = <String>[];
    final stdoutText = result.stdout as String;
    for (final record in stdoutText.split('\x00')) {
      if (record.length <= 3) continue;
      final filename = record.substring(3);
      final fullPath = p.normalize(p.join(repoRoot, filename));
      if (!published.contains(fullPath)) continue;
      modified.add(p.relative(fullPath, from: dir));
    }

    if (modified.isEmpty) return;
    final shown = modified.take(10).join('\n');
    final ellipsis = modified.length > 10 ? '\n...\n' : '\n';
    warning(
      '${modified.length} checked-in '
      '${modified.length == 1 ? 'file is' : 'files are'} modified in git.\n\n'
      'Usually you want to publish from a clean git state.\n\n'
      'Consider committing these files or reverting the changes.\n\n'
      'Modified files:\n\n$shown$ellipsis'
      'Run `git status` for more information.',
    );
  }

  Future<String?> _repoRoot(String dir) async {
    try {
      final r = await Process.run(
        'git',
        ['rev-parse', '--show-toplevel'],
        workingDirectory: dir,
      );
      if (r.exitCode != 0) return null;
      return (r.stdout as String).trim();
    } on ProcessException {
      return null;
    }
  }
}
