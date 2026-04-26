/// `club global activate` command.
///
/// Thin wrapper around `dart pub global activate --hosted-url <server>`.
/// Resolves which logged-in club server hosts the requested package
/// (reusing [HostingServerResolver] — the same resolver used by
/// `club add`), ensures the club token is registered with `dart pub`,
/// then shells out to `dart pub global activate` with stdio inherited so
/// the user sees real-time progress.
library;

import 'dart:io';

import 'package:args/command_runner.dart';

import '../../util/log.dart';
import 'global_activate_options.dart';
import 'global_activate_runner.dart';

class GlobalActivateCommand extends Command<void> {
  GlobalActivateCommand() {
    argParser
      ..addOption(
        'server',
        abbr: 's',
        help:
            'Force a specific club server, skipping the multi-server '
            'picker. Must be a server you are logged in to.',
        valueHelp: 'url',
      )
      ..addFlag(
        'overwrite',
        negatable: false,
        help:
            'Overwrite executables that conflict with already-activated '
            'packages.',
      )
      ..addMultiOption(
        'executable',
        abbr: 'x',
        help:
            'Install only the executable with the given name. Pass '
            'multiple times to install a subset of executables.',
        valueHelp: 'name',
      )
      ..addFlag(
        'no-executables',
        abbr: 'X',
        negatable: false,
        help: 'Skip installing any executables.',
      )
      ..addOption(
        'features',
        help:
            'Comma-separated list of features to enable (forwarded to '
            'dart pub global activate).',
        valueHelp: 'features',
      );
  }

  @override
  String get name => 'activate';

  @override
  String get description =>
      'Install a package from a club server as a global executable.';

  @override
  String get invocation =>
      'club global activate [options] <package> [<version-constraint>]';

  @override
  Future<void> run() async {
    configureColors();

    final results = argResults!;
    final rest = results.rest;
    if (rest.isEmpty) {
      throw UsageException(
        'Missing package name.',
        usage,
      );
    }
    if (rest.length > 2) {
      throw UsageException(
        'Too many positional arguments. Expected: <package> [<constraint>]',
        usage,
      );
    }

    final executables = List<String>.from(results['executable'] as List);
    if (executables.isNotEmpty && results['no-executables'] as bool) {
      throw UsageException(
        '--executable and --no-executables cannot be combined.',
        usage,
      );
    }

    final options = GlobalActivateOptions(
      packageName: rest[0],
      constraint: rest.length == 2 ? rest[1] : null,
      serverFlag: results['server'] as String?,
      overwrite: results['overwrite'] as bool,
      executables: executables,
      noExecutables: results['no-executables'] as bool,
      features: results['features'] as String?,
    );

    exitCode = await GlobalActivateRunner(options).run();
  }
}
