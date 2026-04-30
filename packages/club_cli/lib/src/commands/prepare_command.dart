/// `club prepare` command.
///
/// Discovers all publishable packages under the working directory, lets the
/// user pick targets, then rewrites every internal-dep entry in the
/// closure's pubspec.yaml files to a `hosted: <url>, version: ^<ver>` form.
/// This sets up the workspace for a subsequent ordered publish without
/// actually publishing anything.
library;

import 'dart:io';

import '../prepare/conflict_resolver.dart';
import '../prepare/prepare_runner.dart';
import '../prepare/tree_renderer.dart';
import '../util/log.dart';
import 'base/club_command.dart';

class PrepareCommand extends ClubCommand {
  PrepareCommand() {
    argParser
      ..addFlag(
        'dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Show the plan without modifying any pubspec.yaml.',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        negatable: false,
        help: 'Skip the confirmation prompt before applying rewrites.',
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
        help: 'Target server URL written into rewritten dep entries. '
            'Must be a server you have logged in to.',
        valueHelp: 'url',
      )
      ..addOption(
        'on-conflict',
        help: 'How to handle packages whose local version is already '
            'published.',
        valueHelp: 'mode',
        defaultsTo: 'prompt',
        allowed: const ['prompt', 'overwrite', 'skip', 'abort'],
        allowedHelp: const {
          'prompt': 'Ask interactively for each conflict.',
          'overwrite': 'Force-publish, replacing the existing version.',
          'skip': 'Reuse the already-published version (no rewrite).',
          'abort': 'Exit if any conflict is detected.',
        },
      )
      ..addOption(
        'tree',
        help: 'Visual style for the dependency tree section.',
        valueHelp: 'style',
        defaultsTo: 'stacked',
        allowed: const ['stacked', 'nested'],
        allowedHelp: const {
          'stacked': 'Publish-stack list with inline deps + sizes (default).',
          'nested': 'Indented `├──` / `└──` tree.',
        },
      )
      ..addFlag(
        'no-tree',
        negatable: false,
        help: 'Suppress the dependency tree section entirely.',
      );
  }

  @override
  String get name => 'prepare';

  @override
  String get description =>
      'Rewrite path / workspace deps in a monorepo to hosted refs in '
      'publish order.';

  @override
  String get invocation => 'club prepare [options] [<package>...]';

  @override
  Future<void> run() async {
    configureColors();

    final results = argResults!;
    // `defaultsTo` on each option guarantees a non-null value, but the
    // typed parser still validates the string and yields a typed enum.
    final onConflict = parseOnConflictMode(results['on-conflict'] as String) ??
        OnConflictMode.prompt;
    final treeStyle = parseTreeStyle(results['tree'] as String) ??
        TreeStyle.stacked;
    final options = PrepareOptions(
      directory: (results['directory'] as String?) ?? '',
      targets: results.rest,
      dryRun: results['dry-run'] as bool,
      force: results['force'] as bool,
      serverFlag: results['server'] as String?,
      onConflict: onConflict,
      treeStyle: treeStyle,
      showTree: !(results['no-tree'] as bool),
    );

    try {
      exitCode = await PrepareRunner(options).run();
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
