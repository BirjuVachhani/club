import 'dart:io';

import 'package:args/command_runner.dart';

import '../upgrade/upgrade_decision.dart';
import '../upgrade/upgrade_options.dart';
import '../upgrade/upgrade_runner.dart';
import '../util/log.dart';

/// `club upgrade` — replace this CLI with a newer release.
///
/// Plain [Command] rather than `ClubCommand`: upgrading talks to GitHub,
/// not to a club server, so it needs neither a login nor a server URL.
class UpgradeCommand extends Command<void> {
  UpgradeCommand() {
    argParser
      ..addFlag(
        'check',
        negatable: false,
        help: 'Report whether a newer release exists, then exit.',
      )
      // Deliberately no `abbr: 'v'`: -v is the top-level version flag, and
      // `club upgrade -v` should be a usage error rather than ambiguous.
      ..addOption(
        'version',
        help: 'Install this exact version instead of the latest.',
        valueHelp: '0.4.2',
      )
      ..addFlag(
        'pre',
        negatable: false,
        help: 'Consider pre-release tags when resolving the latest version.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Reinstall when already current, and proceed on a local build.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print what would happen, then exit.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Skip the downgrade confirmation.',
      )
      ..addOption(
        'install-dir',
        help: 'Override the auto-detected install directory.',
        valueHelp: 'path',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Machine-readable output.',
      );
  }

  @override
  String get name => 'upgrade';

  @override
  String get description => 'Upgrade the club CLI to the latest release.';

  @override
  String get invocation => 'club upgrade [options]';

  @override
  Future<void> run() async {
    configureColors();
    final args = argResults!;

    final check = args['check'] as bool;
    final dryRun = args['dry-run'] as bool;
    if (check && dryRun) {
      usageException('--check and --dry-run cannot be combined.');
    }

    // Accepts `0.4.2` or `v0.4.2`. Validate here so a typo fails instantly
    // rather than after a round trip to GitHub.
    final version = args['version'] as String?;
    if (version != null) {
      if (version.isEmpty) usageException('--version requires a value.');
      if (tryParseVersion(version) == null) {
        usageException('"$version" is not a valid version.');
      }
    }

    if (version != null && args['pre'] as bool) {
      usageException(
        '--pre has no effect with --version, which names an exact release.',
      );
    }

    exitCode = await UpgradeRunner(
      UpgradeOptions(
        check: check,
        version: version,
        pre: args['pre'] as bool,
        force: args['force'] as bool,
        dryRun: dryRun,
        yes: args['yes'] as bool,
        installDir: args['install-dir'] as String?,
        json: args['json'] as bool,
      ),
    ).run();
  }
}
