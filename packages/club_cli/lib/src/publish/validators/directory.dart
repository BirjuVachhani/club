/// Mirrors dart pub's
/// [`DirectoryValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/directory.dart):
/// warns about non-standard top-level directories that pub.dev will ignore.
library;

import 'validator.dart';

class DirectoryValidator extends Validator {
  DirectoryValidator(super.context);

  static const _pluralNames = [
    'benchmarks',
    'docs',
    'examples',
    'tests',
    'tools',
  ];

  static const _docRef = 'See https://dart.dev/tools/pub/package-layout.';

  @override
  String get name => 'DirectoryValidator';

  @override
  Future<void> validate() async {
    final topDirs = <String>{};
    for (final f in context.tarball.files) {
      final segs = f.split('/');
      if (segs.length > 1) topDirs.add(segs.first);
    }

    for (final dirName in topDirs) {
      if (_pluralNames.contains(dirName)) {
        final singular = dirName.substring(0, dirName.length - 1);
        warning(
          'Rename the top-level "$dirName" directory to "$singular".\n'
          'The Pub layout convention is to use singular directory names.\n'
          'Plural names won\'t be correctly identified by Pub and other '
          'tools.\n$_docRef',
        );
      }

      if (RegExp(r'^samples?$').hasMatch(dirName)) {
        warning(
          'Rename the top-level "$dirName" directory to "example".\n'
          'This allows Pub to find your examples and create "packages" '
          'directories for them.\n$_docRef',
        );
      }
    }
  }
}
