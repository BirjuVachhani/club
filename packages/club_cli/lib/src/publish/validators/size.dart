/// Mirrors dart pub's
/// [`SizeValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/size.dart):
/// archives must be smaller than 100 MiB.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'validator.dart';

class SizeValidator extends Validator {
  SizeValidator(super.context);

  static const int maxBytes = 100 * 1024 * 1024;

  @override
  String get name => 'SizeValidator';

  @override
  Future<void> validate() async {
    if (context.tarball.sizeBytes <= maxBytes) return;

    final buf = StringBuffer(
      'Your package is ${_format(context.tarball.sizeBytes)}.\n\n'
      'Consider the impact large downloads can have on the package consumer.',
    );

    final ignoreExists = File(
      p.join(context.pubspec.directory, '.gitignore'),
    ).existsSync();
    final inGitRepo = Directory(
      p.join(context.pubspec.directory, '.git'),
    ).existsSync();

    if (ignoreExists && !inGitRepo) {
      buf.write(
        '\nYour .gitignore has no effect since your project '
        'does not appear to be in version control.',
      );
    } else if (!ignoreExists && inGitRepo) {
      buf.write(
        '\nConsider adding a .gitignore to avoid including '
        'temporary files.',
      );
    }

    // Enhanced mode treats oversized archives as a hard block; baseline
    // only hints (matches dart pub publish).
    if (context.enhanced) {
      error(buf.toString());
    } else {
      hint(buf.toString());
    }
  }

  String _format(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '$bytes B';
  }
}
