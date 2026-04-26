/// Mirrors dart pub's
/// [`ReadmeValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/readme.dart):
/// a README file should exist and be valid UTF-8. Picks the same primary
/// README as pub.dev when multiple are present.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'validator.dart';

final _readmeRegexp = RegExp(r'^README($|\.)', caseSensitive: false);

class ReadmeValidator extends Validator {
  ReadmeValidator(super.context);

  @override
  String get name => 'ReadmeValidator';

  @override
  Future<void> validate() async {
    final readmes = context.tarball.files
        .where((f) => !f.contains('/'))
        .where((f) => _readmeRegexp.hasMatch(p.basename(f)))
        .toList();

    if (readmes.isEmpty) {
      warning('Please add a README.md file that describes your package.');
      return;
    }

    final readme = readmes.reduce((a, b) {
      final extA = '.'.allMatches(p.basename(a)).length;
      final extB = '.'.allMatches(p.basename(b)).length;
      var cmp = extA.compareTo(extB);
      if (cmp == 0) cmp = a.compareTo(b);
      return cmp <= 0 ? a : b;
    });

    if (p.basename(readme) != 'README.md') {
      warning(
        'Please consider renaming $readme to `README.md`. '
        'See https://dart.dev/tools/pub/publishing#important-files.',
      );
    }

    final file = File(p.join(context.pubspec.directory, readme));
    if (!file.existsSync()) return;
    try {
      utf8.decode(file.readAsBytesSync());
    } on FormatException {
      warning(
        '$readme contains invalid UTF-8.\n'
        'This will cause it to be displayed incorrectly on '
        'the Pub site (https://pub.dev).',
      );
    }
  }
}
