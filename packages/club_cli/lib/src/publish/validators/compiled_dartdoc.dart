/// Mirrors dart pub's
/// [`CompiledDartdocValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/compiled_dartdoc.dart):
/// warns when pre-compiled dartdoc artifacts are shipped.
library;

import 'validator.dart';

class CompiledDartdocValidator extends Validator {
  CompiledDartdocValidator(super.context);

  @override
  String get name => 'CompiledDartdocValidator';

  @override
  Future<void> validate() async {
    final hits = context.tarball.files
        .where(
          (f) =>
              f.startsWith('doc/api/') ||
              f.endsWith('.ddc.js') ||
              f.endsWith('.ddc.js.map'),
        )
        .toList();
    if (hits.isNotEmpty) {
      warning(
        'Compiled documentation found (${hits.length} files starting with '
        '`doc/api/` or `.ddc.js`). These are large and regenerated on '
        'pub.dev — exclude them via .pubignore.',
      );
    }
  }
}
