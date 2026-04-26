/// Based on dart pub's
/// [`LicenseValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/license.dart)
/// with one intentional club divergence: a missing LICENSE is a *warning*
/// by default, not a hard error. Private pub repos routinely host
/// proprietary packages that have no open-source license at all, and
/// blocking publish in that case is wrong for this tool. The pub-parity
/// behaviour (error on missing LICENSE) is still available under
/// `--enhanced`.
library;

import 'package:path/path.dart' as p;

import 'validator.dart';

class LicenseValidator extends Validator {
  LicenseValidator(super.context);

  static final _exactName = RegExp(r'^LICENSE(\.\w+)?$');
  static final _looseName = RegExp(
    r'^(LICENSE|COPYING|UNLICENSE)',
    caseSensitive: false,
  );

  @override
  String get name => 'LicenseValidator';

  @override
  Future<void> validate() async {
    final files = context.tarball.files.where((f) => !f.contains('/')).toList();

    final exact = files.where((f) => _exactName.hasMatch(p.basename(f)));
    if (exact.isNotEmpty) return;

    final loose = files.where((f) => _looseName.hasMatch(p.basename(f)));
    if (loose.isNotEmpty) {
      warning(
        'Found a license file at "${loose.first}". '
        'Consider renaming it to "LICENSE" so pub.dev recognises it.',
      );
      return;
    }

    const message =
        'You do not have a COPYING, LICENSE or UNLICENSE file in the root '
        'directory. Private packages often don\'t need one, but if you '
        'plan to open-source this package, add a license so users know '
        'how they may use your code.';
    if (context.enhanced) {
      error(message);
    } else {
      warning(message);
    }
  }
}
