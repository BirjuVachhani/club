/// `club global` — parent subcommand group for managing globally-installed
/// packages sourced from a club server.
///
/// Mirrors `dart pub global`: the subcommands (`activate`, `deactivate`)
/// delegate to the underlying `dart pub global` invocations, wrapping them
/// with club-specific server resolution and token setup.
library;

import 'package:args/command_runner.dart';

import 'global/global_activate_command.dart';
import 'global/global_deactivate_command.dart';

class GlobalCommand extends Command<void> {
  GlobalCommand() {
    addSubcommand(GlobalActivateCommand());
    addSubcommand(GlobalDeactivateCommand());
  }

  @override
  String get name => 'global';

  @override
  String get description =>
      'Manage globally-installed packages from a club server.';
}
