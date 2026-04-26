/// `club global deactivate` command.
///
/// Thin passthrough to `dart pub global deactivate <package>`. Deactivation
/// works against the local dart pub cache — it doesn't need a club server
/// or a token, so there's no server resolution to do here.
library;

import 'dart:io';

import 'package:args/command_runner.dart';

import '../../util/log.dart';
import '../../util/pub_global.dart';

class GlobalDeactivateCommand extends Command<void> {
  @override
  String get name => 'deactivate';

  @override
  String get description =>
      'Uninstall a globally-activated package. '
      'Delegates to `dart pub global deactivate`.';

  @override
  String get invocation => 'club global deactivate <package>';

  @override
  Future<void> run() async {
    configureColors();

    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException('Missing package name.', usage);
    }
    if (rest.length > 1) {
      throw UsageException(
        'Too many positional arguments. Expected: <package>',
        usage,
      );
    }

    exitCode = await runDartPubGlobalDeactivate(rest.first);
  }
}
