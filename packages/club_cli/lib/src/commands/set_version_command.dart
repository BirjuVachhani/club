/// `club set-version` command.
library;

import 'dart:io';

import 'package:args/command_runner.dart';

import '../publish/version_prompt.dart';
import '../set_version/set_version_runner.dart';
import '../util/exit_codes.dart';
import '../util/log.dart';

class SetVersionCommand extends Command<void> {
  SetVersionCommand() {
    argParser.addOption(
      'directory',
      abbr: 'C',
      help: 'Run this in the directory <dir>.',
      valueHelp: 'dir',
    );
  }

  @override
  String get name => 'set-version';

  @override
  String get description =>
      'Set selected package versions and their hosted dependency constraints.';

  @override
  String get invocation => 'club set-version [options] <version_tag>';

  @override
  Future<void> run() async {
    configureColors();
    final results = argResults!;
    final positional = results.rest;
    if (positional.isEmpty) {
      usageException('Missing version tag.');
    }
    if (positional.length > 1) {
      usageException('Expected exactly one version tag.');
    }

    final version = positional.single.trim();
    final versionProblem = versionFormatError(version);
    if (versionProblem != null) usageException(versionProblem);

    try {
      exitCode = await SetVersionRunner(
        SetVersionOptions(
          version: version,
          directory: (results['directory'] as String?) ?? '',
        ),
      ).run();
    } on ArgumentError catch (exception) {
      error(exception.message.toString());
      exitCode = ExitCodes.config;
    } on FileSystemException catch (exception) {
      error(exception.message);
      if (exception.path != null) hint('Path: ${exception.path}');
      exitCode = ExitCodes.noInput;
    } on FormatException catch (exception) {
      error(exception.message);
      exitCode = ExitCodes.data;
    }
  }
}
