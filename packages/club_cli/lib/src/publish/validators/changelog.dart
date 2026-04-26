/// Mirrors dart pub's
/// [`ChangelogValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/changelog.dart):
/// a CHANGELOG should exist and mention the version being published.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'validator.dart';

final _changelogRegexp = RegExp(r'^CHANGELOG($|\.)', caseSensitive: false);

class ChangelogValidator extends Validator {
  ChangelogValidator(super.context);

  @override
  String get name => 'ChangelogValidator';

  @override
  Future<void> validate() async {
    final changelog = context.tarball.files
        .where((f) => !f.contains('/'))
        .firstWhere(
          (f) => _changelogRegexp.hasMatch(p.basename(f)),
          orElse: () => '',
        );

    if (changelog.isEmpty) {
      warning(
        'Please add a `CHANGELOG.md` to your package. '
        'See https://dart.dev/tools/pub/publishing#important-files.',
      );
      return;
    }

    if (p.basename(changelog) != 'CHANGELOG.md') {
      warning(
        'Please consider renaming $changelog to `CHANGELOG.md`. '
        'See https://dart.dev/tools/pub/publishing#important-files.',
      );
    }

    final file = File(p.join(context.pubspec.directory, changelog));
    if (!file.existsSync()) return;
    final bytes = file.readAsBytesSync();
    final String contents;
    try {
      contents = utf8.decode(bytes);
    } on FormatException {
      warning(
        '$changelog contains invalid UTF-8.\n'
        'This will cause it to be displayed incorrectly on '
        'the Pub site (https://pub.dev).',
      );
      return;
    }

    final ver = context.pubspec.version;
    if (ver.isEmpty) return;
    if (!contents.contains(ver)) {
      warning(
        "$changelog doesn't mention current version ($ver).\n"
        'Consider updating it with notes on this version prior to '
        'publication.',
      );
    }
  }
}
