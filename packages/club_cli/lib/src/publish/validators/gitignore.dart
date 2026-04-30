/// Mirrors dart pub's
/// [`GitignoreValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/gitignore.dart):
/// warns about files that are both checked into git *and* ignored by a
/// `.gitignore` — previous pub versions published those files, so the
/// ambiguity is worth flagging.
library;

import 'dart:io';

import 'validator.dart';

class GitignoreValidator extends Validator {
  GitignoreValidator(super.context);

  @override
  String get name => 'GitignoreValidator';

  @override
  Future<void> validate() async {
    final dir = context.pubspec.directory;

    // `git ls-files -i -c --exclude-standard` lists files that are cached
    // (checked in) and also match a gitignore pattern. That is exactly
    // pub's intent, computed natively by git.
    final ProcessResult result;
    try {
      result = await Process.run(
        'git',
        [
          '-c',
          'core.quotePath=false',
          'ls-files',
          '-i',
          '-c',
          '--exclude-standard',
          '--recurse-submodules',
        ],
        workingDirectory: dir,
      );
    } on ProcessException {
      return;
    }
    if (result.exitCode != 0) return;

    final ignoredCheckedIn = (result.stdout as String)
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (ignoredCheckedIn.isEmpty) return;

    final shown = ignoredCheckedIn.take(10).join('\n');
    final ellipsis = ignoredCheckedIn.length > 10 ? '\n...' : '';
    warning(
      '${ignoredCheckedIn.length} checked-in '
      '${ignoredCheckedIn.length == 1 ? 'file is' : 'files are'} '
      'ignored by a `.gitignore`.\n'
      'Previous versions of Pub would include those in the published '
      'package.\n\n'
      'Consider adjusting your `.gitignore` files to not ignore those '
      'files, and if you do not wish to publish these files use '
      '`.pubignore`. See also dart.dev/go/pubignore\n\n'
      'Files that are checked in while gitignored:\n\n$shown$ellipsis',
    );
  }
}
