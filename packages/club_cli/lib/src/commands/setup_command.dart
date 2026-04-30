import 'dart:io';

import 'package:args/command_runner.dart';

import '../config.dart';
import '../credentials.dart';

class SetupCommand extends Command<void> {
  SetupCommand() {
    argParser
      ..addOption('server', abbr: 's', help: 'Server URL')
      ..addOption(
        'env-var',
        help: 'Use environment variable for the token instead of storing it',
      );
  }

  @override
  String get name => 'setup';

  @override
  String get description => 'Configure dart pub to work with your club server.';

  @override
  Future<void> run() async {
    final serverUrl = CliConfig.resolveServer(argResults!['server'] as String?);
    if (serverUrl == null) {
      stderr.writeln('No server specified. Run: club login <server-url>');
      return;
    }

    final envVar = argResults!['env-var'] as String?;

    stdout.writeln('Configuring dart pub for $serverUrl...');

    if (envVar != null) {
      // Use env var mode
      final result = await Process.run(
        'dart',
        ['pub', 'token', 'add', serverUrl, '--env-var', envVar],
      );
      if (result.exitCode != 0) {
        stderr.writeln('Failed: ${result.stderr}');
        return;
      }
      stdout.writeln('Token registered via environment variable $envVar.');
    } else {
      // Store token directly
      final token = CredentialStore.getToken(serverUrl);
      if (token == null) {
        stderr.writeln(
          'Not logged in to $serverUrl. Run: club login $serverUrl',
        );
        return;
      }

      final process = await Process.start(
        'dart',
        ['pub', 'token', 'add', serverUrl],
      );
      process.stdin.writeln(token);
      await process.stdin.close();
      final exitCode = await process.exitCode;

      if (exitCode != 0) {
        stderr.writeln('dart pub token add failed.');
        return;
      }
      stdout.writeln('Token registered with dart pub.');
    }

    stdout.writeln('\nTo use packages from club, add to your pubspec.yaml:\n');
    stdout.writeln('  dependencies:');
    stdout.writeln('    my_package:');
    stdout.writeln('      hosted: $serverUrl');
    stdout.writeln('      version: ^1.0.0\n');
    stdout.writeln('Or set PUB_HOSTED_URL to use club as the default:\n');
    stdout.writeln('  export PUB_HOSTED_URL=$serverUrl');
  }
}
