/// Mirrors dart pub's
/// [`NameValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/name.dart):
/// package names must be valid Dart identifiers, lowercase, not reserved.
library;

import 'validator.dart';

class NameValidator extends Validator {
  NameValidator(super.context);

  // From dart pub.
  static const Set<String> _reservedWords = {
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'covariant',
    'default',
    'deferred',
    'do',
    'dynamic',
    'else',
    'enum',
    'export',
    'extends',
    'extension',
    'external',
    'factory',
    'false',
    'final',
    'finally',
    'for',
    'function',
    'get',
    'hide',
    'if',
    'implements',
    'import',
    'in',
    'interface',
    'is',
    'late',
    'library',
    'mixin',
    'new',
    'null',
    'of',
    'on',
    'operator',
    'part',
    'rethrow',
    'return',
    'set',
    'show',
    'static',
    'super',
    'switch',
    'sync',
    'this',
    'throw',
    'true',
    'try',
    'typedef',
    'var',
    'void',
    'while',
    'with',
    'yield',
  };

  @override
  String get name => 'NameValidator';

  @override
  Future<void> validate() async {
    _checkName(context.pubspec.name);

    // If the package has exactly one public library under lib/ (ignoring
    // lib/src/), warn if its basename doesn't match the package name so
    // consumers know what to import.
    final libraries = _publicLibraries();
    if (libraries.length == 1) {
      final libPath = libraries.first;
      final libName = libPath
          .split('/')
          .last
          .replaceAll(RegExp(r'\.dart$'), '');
      if (libName != context.pubspec.name) {
        warning(
          'The name of "$libPath", "$libName", should match the name of the '
          'package, "${context.pubspec.name}".\n'
          'This helps users know what library to import.',
        );
      }
    }
  }

  void _checkName(String n) {
    final desc = 'Package name "$n"';
    if (n.isEmpty) {
      error('$desc may not be empty.');
      return;
    }
    if (!RegExp(r'^[a-zA-Z0-9_]*$').hasMatch(n)) {
      error(
        '$desc may only contain letters, numbers, and underscores.\n'
        'Using a valid Dart identifier makes the name usable in Dart code.',
      );
    } else if (!RegExp(r'^[a-zA-Z_]').hasMatch(n)) {
      error(
        '$desc must begin with a letter or underscore.\n'
        'Using a valid Dart identifier makes the name usable in Dart code.',
      );
    } else if (_reservedWords.contains(n.toLowerCase())) {
      error(
        '$desc may not be a reserved word in Dart.\n'
        'Using a valid Dart identifier makes the name usable in Dart code.',
      );
    } else if (RegExp(r'[A-Z]').hasMatch(n)) {
      warning('$desc should be lower-case. Maybe use "${_unCamelCase(n)}"?');
    }
  }

  List<String> _publicLibraries() => context.tarball.files
      .where(
        (f) =>
            f.startsWith('lib/') &&
            !f.startsWith('lib/src/') &&
            f.endsWith('.dart'),
      )
      .toList();

  String _unCamelCase(String s) {
    final buf = StringBuffer();
    var last = 0;
    for (final m in RegExp(r'[a-z]([A-Z])').allMatches(s)) {
      buf
        ..write(s.substring(last, m.start + 1))
        ..write('_')
        ..write(m.group(1)!.toLowerCase());
      last = m.end;
    }
    buf.write(s.substring(last));
    return buf.toString().toLowerCase();
  }
}
