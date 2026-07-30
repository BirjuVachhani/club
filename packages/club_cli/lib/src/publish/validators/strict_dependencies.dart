/// Mirrors dart pub's
/// [`StrictDependenciesValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/strict_dependencies.dart):
/// `lib/`, `bin/`, `hook/` files may only import packages from
/// `dependencies`, never from `dev_dependencies`.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

import 'validator.dart';

class StrictDependenciesValidator extends Validator {
  StrictDependenciesValidator(super.context);

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

      // Read from the resolved scratch copy when available — those are the
      // exact bytes in the archive, which is what consumers compile.
      final source = File(p.join(context.sourceDir, rel)).readAsStringSync();
      for (final imported in _collectPackageImports(source)) {
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

  /// Set of package names referenced by `import`/`export` directives in
  /// [source], including conditional `if (...) '...'` URIs. Uses the
  /// analyzer's AST so URIs inside comments, dartdoc code blocks, and
  /// ordinary string literals are not matched.
  Set<String> _collectPackageImports(String source) {
    final result = parseString(content: source, throwIfDiagnostics: false);
    final names = <String>{};
    for (final directive in result.unit.directives) {
      if (directive is! NamespaceDirective) continue;
      _addIfPackage(names, directive.uri);
      for (final config in directive.configurations) {
        _addIfPackage(names, config.uri);
      }
    }
    return names;
  }

  void _addIfPackage(Set<String> out, StringLiteral uri) {
    final value = uri.stringValue;
    if (value == null || !value.startsWith('package:')) return;
    final rest = value.substring('package:'.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return;
    out.add(rest.substring(0, slash));
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
