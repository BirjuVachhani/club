import 'dart:io';

import 'package:args/command_runner.dart';

import '../config.dart';
import '../credentials.dart';

class LogoutCommand extends Command<void> {
  LogoutCommand() {
    argParser
      ..addOption('server', abbr: 's', help: 'Server URL to logout from')
      ..addFlag('all', help: 'Remove credentials for all servers');
  }

  @override
  String get name => 'logout';

  @override
  String get description => 'Remove stored credentials.';

  @override
  Future<void> run() async {
    if (argResults!['all'] as bool) {
      CredentialStore.removeAll();
      stdout.writeln('Logged out from all servers.');
      return;
    }

    final serverUrl = CliConfig.resolveServer(argResults!['server'] as String?);
    if (serverUrl == null) {
      stderr.writeln('No server specified and no default server configured.');
      return;
    }

    CredentialStore.remove(serverUrl);
    stdout.writeln('Logged out from $serverUrl');
  }
}
