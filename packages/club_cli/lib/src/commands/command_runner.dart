import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../version.dart';
import 'add_command.dart';
import 'config_command.dart';
import 'global_command.dart';
import 'login_command.dart';
import 'logout_command.dart';
import 'publish_command.dart';
import 'setup_command.dart';

/// The club CLI command runner.
///
/// The CLI is deliberately narrow: log in, configure the dart pub
/// toolchain, publish packages. Server administration (user management,
/// package moderation, ownership transfer, API key create/list/revoke)
/// lives in the web admin dashboard — there, humans can see prefixes,
/// scopes, and last-used data while deciding. The CLI consumes keys
/// (via `club login --key` or `CLUB_TOKEN`) but doesn't mint them.
CommandRunner<void> buildCommandRunner() {
  final runner = _ClubRunner();
  runner.addCommand(LoginCommand());
  runner.addCommand(LogoutCommand());
  runner.addCommand(ConfigCommand());
  runner.addCommand(SetupCommand());
  runner.addCommand(PublishCommand());
  runner.addCommand(AddCommand());
  runner.addCommand(GlobalCommand());
  return runner;
}

/// Custom runner so we can intercept `--version` before any subcommand
/// dispatch happens. The base [CommandRunner] doesn't ship with a
/// version flag.
class _ClubRunner extends CommandRunner<void> {
  _ClubRunner()
    : super(
        'club',
        'CLI tool for club — a self-hosted Dart package repository.',
      ) {
    argParser.addFlag(
      'version',
      abbr: 'v',
      negatable: false,
      help: 'Print the CLI version and exit.',
    );
  }

  @override
  Future<void> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults['version'] as bool) {
      stdout.writeln(clubCliVersion);
      return;
    }
    return super.runCommand(topLevelResults);
  }
}
