/// `club add` command.
///
/// Adds package dependencies to `pubspec.yaml`, pulled from one of the
/// club servers the user is logged in to. Mirrors the positional-argument
/// grammar of `dart pub add`:
///
///   club add foo
///   club add dev:foo override:bar
///   club add foo:^1.2.3
///   club add "foo:{hosted: https://my-club.example.com}"
///
/// For `path`, `git`, and `sdk` dependencies, fall back to `dart pub add` —
/// this command is scoped to hosted packages served from a club registry.
library;

import 'dart:io';

import '../add/add_options.dart';
import '../add/add_runner.dart';
import '../util/log.dart';
import 'base/club_command.dart';

class AddCommand extends ClubCommand {
  AddCommand() {
    argParser
      ..addFlag(
        'dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Report what would change without modifying pubspec.yaml.',
      )
      ..addOption(
        'directory',
        abbr: 'C',
        help: 'Run this in the directory <dir>.',
        valueHelp: 'dir',
      )
      ..addOption(
        'server',
        abbr: 's',
        help:
            'Force a specific club server (e.g. myclub.birju.dev), '
            'skipping the multi-server picker. Accepts a full URL too. '
            'Must be a server you are logged in to.',
        valueHelp: 'host',
      );
  }

  @override
  String get name => 'add';

  @override
  String get description =>
      'Add package dependencies to pubspec.yaml from a logged-in club server.';

  @override
  String get invocation =>
      'club add [options] [<section>:]<package>[:<descriptor>] ...';

  @override
  Future<void> run() async {
    configureColors();

    final results = argResults!;
    final options = AddOptions(
      args: results.rest,
      directory: (results['directory'] as String?) ?? '',
      dryRun: results['dry-run'] as bool,
      serverFlag: results['server'] as String?,
    );

    try {
      exitCode = await AddRunner(options).run();
    } on ArgumentError catch (e) {
      error(e.message.toString());
      exitCode = ExitCodes.config;
    } on FileSystemException catch (e) {
      error(e.message);
      if (e.path != null) hint('Path: ${e.path}');
      exitCode = ExitCodes.noInput;
    } on FormatException catch (e) {
      error(e.message);
      exitCode = ExitCodes.data;
    }
  }
}
