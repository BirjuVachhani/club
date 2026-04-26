/// Mirrors dart pub's
/// [`FlutterPluginFormatValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/flutter_plugin_format.dart):
/// errors when a plugin uses the legacy single-key format, or when the new
/// format is used with a Flutter SDK constraint that allows versions older
/// than 1.10.0.
library;

import 'package:pub_semver/pub_semver.dart';

import 'validator.dart';

const _pluginDocsUrl =
    'https://flutter.dev/docs/development/packages-and-plugins/developing-packages#plugin';

class FlutterPluginFormatValidator extends Validator {
  FlutterPluginFormatValidator(super.context);

  @override
  String get name => 'FlutterPluginFormatValidator';

  @override
  Future<void> validate() async {
    final flutter = context.pubspec.rawMap['flutter'];
    if (flutter is! Map) return;
    final plugin = flutter['plugin'];
    if (plugin is! Map) return;

    final usesOldFormat = const {
      'androidPackage',
      'iosPrefix',
      'pluginClass',
    }.any(plugin.containsKey);
    final usesNewFormat = plugin['platforms'] != null;

    // New format requires Flutter >= 1.10.0. If the Flutter constraint is
    // missing or permits anything below 1.10.0, the plugin is broken on
    // older Flutters.
    final flutterConstraint = context.pubspec.parsed.environment['flutter'];
    if (usesNewFormat &&
        (flutterConstraint == null ||
            flutterConstraint.allowsAny(
              VersionRange(
                min: Version.parse('0.0.0'),
                max: Version.parse('1.10.0'),
                includeMin: true,
              ),
            ))) {
      error(
        'pubspec.yaml allows Flutter SDK version 1.9.x, which does '
        'not support the flutter.plugin.platforms key.\n'
        'Please consider increasing the Flutter SDK requirement to '
        '^1.10.0 (environment.sdk.flutter)\n\nSee $_pluginDocsUrl',
      );
      return;
    }

    if (usesOldFormat) {
      error(
        'In pubspec.yaml the '
        'flutter.plugin.{androidPackage,iosPrefix,pluginClass} keys are '
        'deprecated. Instead use the flutter.plugin.platforms key '
        'introduced in Flutter 1.10.0\n\nSee $_pluginDocsUrl',
      );
    }
  }
}
