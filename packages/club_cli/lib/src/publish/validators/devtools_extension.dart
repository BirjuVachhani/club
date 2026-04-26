/// Mirrors dart pub's
/// [`DevtoolsExtensionValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/devtools_extension.dart):
/// when an `extension/devtools/` folder is shipped, verify it contains
/// `config.yaml` and a non-empty `build/` subdirectory.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'validator.dart';

const _docUrl = 'https://docs.flutter.dev/tools/devtools/extensions';

class DevtoolsExtensionValidator extends Validator {
  DevtoolsExtensionValidator(super.context);

  @override
  String get name => 'DevtoolsExtensionValidator';

  @override
  Future<void> validate() async {
    final devtoolsDir = Directory(
      p.join(context.pubspec.directory, 'extension', 'devtools'),
    );
    if (!devtoolsDir.existsSync()) return;

    final hasConfig = context.tarball.files.any(
      (f) => f == 'extension/devtools/config.yaml',
    );
    final hasBuild = context.tarball.files.any(
      (f) => f.startsWith('extension/devtools/build/'),
    );

    if (!hasConfig || !hasBuild) {
      warning('''
It looks like you are making a devtools extension!

The folder `extension/devtools` should contain both a
* `config.yaml` file and a
* non-empty `build` directory'

See $_docUrl.''');
    }

    // Enhanced: additionally validate config.yaml content.
    if (context.enhanced && hasConfig) {
      final config = File(p.join(devtoolsDir.path, 'config.yaml'));
      try {
        final parsed = loadYaml(config.readAsStringSync());
        if (parsed is! Map || parsed['name'] == null) {
          warning(
            'extension/devtools/config.yaml is missing the `name` field.',
          );
        }
      } catch (e) {
        warning('extension/devtools/config.yaml is invalid YAML: $e');
      }
    }
  }
}
