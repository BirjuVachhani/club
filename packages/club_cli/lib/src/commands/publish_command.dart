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

import 'package:path/path.dart' as p;

import '../prepare/conflict_resolver.dart';
import '../prepare/tree_renderer.dart';
import '../publish/auto_publish_runner.dart';
import '../publish/git_source.dart';
import '../publish/pr_version.dart';
import '../publish/publish_runner.dart';
import '../publish/pubspec_reader.dart';
import '../publish/version_prompt.dart';
import '../util/log.dart';
import '../util/prompt.dart';
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
            'Target server host (e.g. myclub.birju.dev). Accepts a full '
            'URL too. Overrides publish_to in pubspec.yaml. Must be a '
            'server you have logged in to.',
        valueHelp: 'host',
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
      )
      ..addFlag(
        'auto',
        negatable: false,
        help:
            'Discover the workspace, rewrite path/workspace deps to '
            'hosted refs, and publish every package in topological order. '
            'Positional args (or an interactive picker if none) select '
            'the leaf targets; transitive workspace deps are pulled in.',
      )
      ..addOption(
        'on-conflict',
        help:
            'How to handle packages whose local version is already '
            'published (only used with --auto).',
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
        help:
            'Visual style for the dependency tree section '
            '(only used with --auto).',
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
        help: 'Suppress the dependency tree section (only used with --auto).',
      )
      ..addOption(
        'from-git',
        help:
            'Clone a git repository and publish it as a package. Accepts '
            'an https or SSH git URL, or a GitHub pull request URL '
            '(https://github.com/<owner>/<repo>/pull/<n>), which publishes '
            'the PR head as a prerelease: 1.2.0 becomes 1.2.0-pr<n>. The '
            'repo is cloned under ~/.club/clones/ and removed after a '
            'successful publish. Combine with --auto for monorepos, or -C '
            'to target a package in a subdirectory of the repo.',
        valueHelp: 'url',
      )
      ..addOption(
        'ref',
        help:
            'Git branch, tag, or commit to check out (only used with '
            '--from-git). Defaults to the remote default branch. Cannot be '
            'combined with a pull request URL, which selects its own ref.',
        valueHelp: 'ref',
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
    final fromGit = results['from-git'] as String?;
    final gitRef = results['ref'] as String?;

    // --ref is meaningless without a repository to check out.
    if (gitRef != null && fromGit == null) {
      error('--ref can only be used together with --from-git.');
      exitCode = ExitCodes.config;
      return;
    }

    // Check --version before anything expensive: a typo should not cost
    // the user a clone and a dependency resolution first.
    final versionFlag = results['version'] as String?;
    if (versionFlag != null) {
      final problem = versionFormatError(versionFlag);
      if (problem != null) {
        error(problem);
        exitCode = ExitCodes.config;
        return;
      }
    }

    // ── --from-git: clone the repo, publish from the clone, clean up ─────
    if (fromGit != null) {
      if (results['from-archive'] != null) {
        error('--from-git cannot be combined with --from-archive.');
        exitCode = ExitCodes.config;
        return;
      }

      // Resolve a PR URL to a repository + PR number before doing any
      // network work, so bad flag combinations fail instantly.
      final GitSource source;
      try {
        source = parseGitSource(fromGit);
      } on GitSourceError catch (e) {
        error(e.message);
        if (e.hint != null) hint(e.hint!);
        exitCode = ExitCodes.config;
        return;
      }

      if (source.isPullRequest && gitRef != null) {
        error('--ref cannot be combined with a pull request URL.');
        hint('The PR URL already selects the commit to publish '
            '(refs/pull/${source.pullRequest}/head).');
        exitCode = ExitCodes.config;
        return;
      }

      final GitClone clone;
      try {
        clone = await prepareGitClone(source: source, ref: gitRef);
      } on GitSourceError catch (e) {
        error(e.message);
        if (e.hint != null) hint(e.hint!);
        exitCode = ExitCodes.unavailable;
        return;
      }

      var succeeded = false;
      try {
        await _runPublish(
          baseDirectory: clone.root,
          pullRequest: clone.pullRequest,
          offerVersionStep: true,
        );
        succeeded = exitCode == ExitCodes.success;
      } finally {
        info('');
        if (succeeded) {
          detail(gray('Removing clone ${clone.root}'));
          deleteGitClone(clone.root);
        } else {
          hint(
            'Clone kept at ${clone.root}. Re-running --from-git reuses it '
            '(hard reset + force checkout, no re-clone).',
          );
        }
      }
      return;
    }

    // ── Plain publish (current directory or -C) ──────────────────────────
    await _runPublish(baseDirectory: null);
  }

  /// Version the single-package flow would publish with if the user
  /// overrides nothing: the pubspec's own version, carrying the `-pr<n>`
  /// suffix when this came from a pull request.
  ///
  /// Returns null when the version cannot be read (no pubspec, no
  /// `version:` field, malformed YAML). The prompt then simply has no
  /// default, and the publish flow reports the real problem shortly after.
  String? _detectVersion(String directory, int? pullRequest) {
    try {
      final dir = directory.isEmpty ? Directory.current.path : directory;
      final version = readPubspec(dir).parsed.version?.toString();
      if (version == null || version.isEmpty) return null;
      return pullRequest == null
          ? version
          : applyPrereleaseSuffix(version, prSuffix(pullRequest));
    } on Exception {
      return null;
    }
  }

  /// Runs the single-package or `--auto` publish flow.
  ///
  /// When [baseDirectory] is set (a `--from-git` clone root) the effective
  /// package directory is that root, with any `-C/--directory` value
  /// resolved relative to it. Otherwise `-C` is used as given.
  ///
  /// [pullRequest] is set when the clone came from a pull request URL; it
  /// makes every package publish as a `-pr<n>` prerelease of its own
  /// version.
  ///
  /// [offerVersionStep] turns on the interactive "publish as which
  /// version?" step, used by `--from-git` where the version in someone
  /// else's pubspec is frequently not the one you want to occupy.
  Future<void> _runPublish({
    required String? baseDirectory,
    int? pullRequest,
    bool offerVersionStep = false,
  }) async {
    final results = argResults!;
    final isAuto = results['auto'] as bool;
    final dirFlag = (results['directory'] as String?) ?? '';
    final directory = baseDirectory == null
        ? dirFlag
        : (dirFlag.isEmpty ? baseDirectory : p.join(baseDirectory, dirFlag));

    // ── Version ──────────────────────────────────────────────────────────
    // --version was already validated in [run]; an explicit value skips
    // the prompt entirely.
    var versionOverride = results['version'] as String?;
    if (versionOverride == null &&
        offerVersionStep &&
        !(results['force'] as bool) &&
        isInteractive &&
        !isCI) {
      // --force means "stop asking me things", and CI has nobody to ask.
      try {
        versionOverride = await promptPublishVersion(
          isAuto: isAuto,
          detected: isAuto ? null : _detectVersion(directory, pullRequest),
          pullRequest: pullRequest,
        );
      } on NonInteractiveError {
        // Terminal disappeared between the check and the prompt; publish
        // with the version the package already declares.
        versionOverride = null;
      }
    }

    // ── --auto branch: multi-package orchestrated publish ────────────────
    if (isAuto) {
      // Reject single-package-only flags so the user gets a clear error
      // rather than silently-ignored options.
      for (final incompatible in const [
        'to-archive',
        'from-archive',
      ]) {
        if (results.wasParsed(incompatible)) {
          error('--$incompatible cannot be combined with --auto.');
          exitCode = ExitCodes.config;
          return;
        }
      }
      final onConflict =
          parseOnConflictMode(results['on-conflict'] as String) ??
              OnConflictMode.prompt;
      final treeStyle = parseTreeStyle(results['tree'] as String) ??
          TreeStyle.stacked;
      final autoOptions = AutoPublishOptions(
        directory: directory,
        targets: results.rest,
        dryRun: results['dry-run'] as bool,
        force: results['force'] as bool,
        skipValidation: results['skip-validation'] as bool,
        ignoreWarnings: results['ignore-warnings'] as bool,
        enhanced: results['enhanced'] as bool,
        serverFlag: results['server'] as String?,
        onConflict: onConflict,
        treeStyle: treeStyle,
        showTree: !(results['no-tree'] as bool),
        pullRequest: pullRequest,
        versionOverride: versionOverride,
      );
      try {
        exitCode = await AutoPublishRunner(autoOptions).run();
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
      return;
    }

    // ── Single-package publish (default) ─────────────────────────────────
    final options = PublishOptions(
      directory: directory,
      dryRun: results['dry-run'] as bool,
      force: results['force'] as bool,
      skipValidation:
          (results['skip-validation'] as bool) ||
          results['from-archive'] != null,
      ignoreWarnings: results['ignore-warnings'] as bool,
      toArchive: results['to-archive'] as String?,
      fromArchive: results['from-archive'] as String?,
      serverFlag: results['server'] as String?,
      versionOverride: versionOverride,
      enhanced: results['enhanced'] as bool,
      pullRequest: pullRequest,
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
