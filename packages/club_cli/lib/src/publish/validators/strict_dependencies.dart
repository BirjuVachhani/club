/// Mirrors dart pub's
/// [`StrictDependenciesValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/strict_dependencies.dart):
/// `lib/`, `bin/`, `hook/` files may only import packages from
/// `dependencies`, never from `dev_dependencies`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'validator.dart';

class StrictDependenciesValidator extends Validator {
  StrictDependenciesValidator(super.context);

  static final _importRegex = RegExp(
    r'''(?:import|export)\s+['"]package:(\w+)/''',
  );

  @override
  String get name => 'StrictDependenciesValidator';

  @override
  Future<void> validate() async {
    final pubspec = context.pubspec;
    final declaredDeps = {
      pubspec.name,
      ...pubspec.parsed.dependencies.keys,
    };
    final devDeps = pubspec.parsed.devDependencies.keys.toSet();

    for (final rel in context.tarball.files) {
      if (!rel.endsWith('.dart')) continue;

      final category = _categoryFor(rel);
      if (category == _Category.ignore) continue;

      final source = File(p.join(pubspec.directory, rel)).readAsStringSync();
      for (final m in _importRegex.allMatches(source)) {
        final imported = m.group(1)!;
        if (declaredDeps.contains(imported)) continue;

        if (category == _Category.publicCode) {
          if (devDeps.contains(imported)) {
            final shortFile = rel.split('/').first;
            error(
              '$imported is in the `dev_dependencies` section of '
              '`pubspec.yaml`. Packages used in $shortFile/ must be declared '
              'in the `dependencies` section.\n($rel)',
            );
          } else {
            error(
              'This package does not have $imported in the `dependencies` '
              'section of `pubspec.yaml`.\n($rel)',
            );
          }
        } else {
          // benchmark / test / tool
          if (!devDeps.contains(imported)) {
            warning(
              'This package does not have $imported in the `dependencies` '
              'or `dev_dependencies` section of `pubspec.yaml`.\n($rel)',
            );
          }
        }
      }
    }
  }

  _Category _categoryFor(String rel) {
    // Public code: lib/**, bin/**, hook/build.dart, hook/link.dart
    if (rel.startsWith('lib/') || rel.startsWith('bin/')) {
      return _Category.publicCode;
    }
    if (rel == 'hook/build.dart' || rel == 'hook/link.dart') {
      return _Category.publicCode;
    }
    if (rel.startsWith('benchmark/') ||
        rel.startsWith('test/') ||
        rel.startsWith('tool/')) {
      return _Category.testCode;
    }
    return _Category.ignore;
  }
}

enum _Category { publicCode, testCode, ignore }
