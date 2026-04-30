/// Mirrors dart pub's
/// [`FlutterConstraintValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/flutter_constraint.dart):
/// warns when the Flutter SDK constraint has an upper bound (Flutter does
/// not use semver for breaking releases, so upper bounds are deprecated).
library;

import 'package:pub_semver/pub_semver.dart';

import 'validator.dart';

const _explanationUrl = 'https://dart.dev/go/flutter-upper-bound-deprecation';

class FlutterConstraintValidator extends Validator {
  FlutterConstraintValidator(super.context);

  @override
  String get name => 'FlutterConstraintValidator';

  @override
  Future<void> validate() async {
    final env = context.pubspec.rawMap['environment'];
    if (env is! Map) return;
    final flutterRaw = env['flutter'];
    if (flutterRaw is! String) return;

    final VersionConstraint constraint;
    try {
      constraint = VersionConstraint.parse(flutterRaw);
    } on FormatException {
      return; // Malformed; let other validators handle.
    }
    if (constraint is! VersionRange || constraint.max == null) return;

    final replacement = constraint.min == null
        ? 'You can replace the constraint with `any`.'
        : 'You can replace that with just the lower bound: '
              '`>=${constraint.min}`.';

    warning(
      'The Flutter constraint should not have an upper bound.\n'
      'In your pubspec.yaml the constraint is currently `$flutterRaw`.\n\n'
      '$replacement\n\n'
      'See $_explanationUrl',
    );
  }
}
