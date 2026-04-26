/// `club publish` command.
///
/// Drop-in replacement for `dart pub publish` with one extra superpower:
/// you do **not** need to set `publish_to:` in your pubspec.yaml. The CLI
/// resolves the target server from your logged-in credentials.
///
/// Flag set, exit codes, and behaviour are kept as close as possible to
/// dart pub publish so future SDK updates are easy to mirror. See
/// `lib/src/publish/publish_runner.dart` for the full flow with references
/// to the upstream Dart pub source.
library;

import 'dart:io';

import '../publish/publish_runner.dart';
import '../util/log.dart';
import 'base/club_command.dart';

class PublishCommand extends ClubCommand {
  PublishCommand() {
    argParser
      ..addFlag(
        'dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Validate but do not publish the package.',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        negatable: false,
        help: 'Publish without confirmation if there are no errors.',
      )
      ..addFlag(
        'skip-validation',
        negatable: false,
        help:
            'Publish without validation and resolution '
            '(this will ignore errors).',
      )
      ..addOption(
        'directory',
        abbr: 'C',
        help: 'Run this in the directory <dir>.',
        valueHelp: 'dir',
      )
      ..addFlag(
        'ignore-warnings',
        negatable: false,
        help: 'Do not treat warnings as fatal.',
      )
      ..addOption(
        'to-archive',
        help: 'Write the package archive to this file instead of uploading.',
        valueHelp: 'path',
      )
      ..addOption(
        'from-archive',
        help:
            'Upload an existing archive instead of building one. '
            'Implies --skip-validation.',
        valueHelp: 'path',
      )
      ..addOption(
        'server',
        abbr: 's',
        help:
            'Target server URL. Overrides publish_to in pubspec.yaml. '
            'Must be a server you have logged in to.',
        valueHelp: 'url',
      )
      ..addOption(
        'version',
        help:
            'Override the version being published. Must be valid semver. '
            'Rewrites the version in the tarball pubspec.yaml without '
            'modifying source files.',
        valueHelp: 'version',
      )
      ..addFlag(
        'enhanced',
        abbr: 'e',
        negatable: false,
        help:
            'Club extras on top of dart pub parity: stricter size limit, '
            '`dart analyze --fatal-warnings`, git deps as errors, extended '
            'leak patterns, DevTools config.yaml content checks, every '
            'file-case collision reported.',
      );
  }

  @override
  String get name => 'publish';

  @override
  String get description => 'Publish the current package to a club server.';

  @override
  String get invocation => 'club publish [options]';

  @override
  Future<void> run() async {
    configureColors();

    final results = argResults!;
    final options = PublishOptions(
      directory: (results['directory'] as String?) ?? '',
      dryRun: results['dry-run'] as bool,
      force: results['force'] as bool,
      skipValidation:
          (results['skip-validation'] as bool) ||
          results['from-archive'] != null,
      ignoreWarnings: results['ignore-warnings'] as bool,
      toArchive: results['to-archive'] as String?,
      fromArchive: results['from-archive'] as String?,
      serverFlag: results['server'] as String?,
      versionOverride: results['version'] as String?,
      enhanced: results['enhanced'] as bool,
    );

    try {
      final code = await PublishRunner(options).run();
      exitCode = code;
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
