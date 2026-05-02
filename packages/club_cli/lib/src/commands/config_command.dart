import 'dart:io';

import 'package:args/command_runner.dart';

import '../credentials.dart';
import '../util/url.dart';

class ConfigCommand extends Command<void> {
  ConfigCommand() {
    addSubcommand(_ConfigShowCommand());
    addSubcommand(_ConfigSetServerCommand());
  }

  @override
  String get name => 'config';

  @override
  String get description => 'Show or update CLI configuration.';

  @override
  Future<void> run() async {
    // Default: show config
    await _ConfigShowCommand().run();
  }
}

class _ConfigShowCommand extends Command<void> {
  @override
  String get name => 'show';

  @override
  String get description => 'Show current configuration.';

  @override
  Future<void> run() async {
    final defaultServer = CredentialStore.getDefaultServer();
    final servers = CredentialStore.listServers();

    stdout.writeln(
      'Default server: '
      '${defaultServer == null ? '(not set)' : displayServer(defaultServer)}',
    );
    stdout.writeln();

    if (servers.isEmpty) {
      stdout.writeln('No configured servers. Run: club login <host>');
    } else {
      stdout.writeln('Configured servers:');
      for (final entry in servers.entries) {
        final isDefault = entry.key == defaultServer ? ' (default)' : '';
        final email = entry.value['email'] ?? 'unknown';
        stdout.writeln('  ${displayServer(entry.key)}$isDefault — $email');
      }
    }
  }
}

class _ConfigSetServerCommand extends Command<void> {
  @override
  String get name => 'set-server';

  @override
  String get description => 'Set the default server.';

  @override
  String get invocation => 'club config set-server <host>';

  @override
  Future<void> run() async {
    if (argResults!.rest.isEmpty) {
      usageException('Server host is required (e.g. myclub.birju.dev).');
    }
    final String url;
    try {
      url = parseServerInput(argResults!.rest.first);
    } on FormatException catch (e) {
      usageException(e.message);
    }
    CredentialStore.setDefaultServer(url);
    stdout.writeln('Default server set to ${displayServer(url)}');
  }
}
