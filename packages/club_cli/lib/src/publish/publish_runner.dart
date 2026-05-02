/// End-to-end orchestration of `club publish`.
///
/// Mirrors dart pub's
/// [`LishCommand.runProtected`](https://github.com/dart-lang/pub/blob/master/lib/src/command/lish.dart):
///   1. Determine the package directory (`-C` flag).
///   2. Resolve the publish target server.
///   3. Build the tarball (or load from `--from-archive`).
///   4. Run validators (skip with `--skip-validation` or `--from-archive`).
///   5. Confirm with the user (skip with `--force` or `--dry-run`).
///   6. Upload (skip if `--dry-run` or `--to-archive`).
///   7. Print result.
///
/// Each step is implemented as a separate method so individual phases can be
/// unit-tested without spinning up the whole pipeline.
library;

import 'dart:io';

import 'package:club_api/club_api.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart' as semver;

import '../util/exit_codes.dart';
import '../util/log.dart';
import '../util/prompt.dart';
import '../util/pub_get.dart';
import '../util/url.dart';
import 'pubspec_reader.dart';
import 'server_resolver.dart';
import 'tarball_builder.dart';
import 'validators/runner.dart';
import 'validators/validator.dart';
import 'workspace_resolver.dart';

export '../util/exit_codes.dart' show ExitCodes;

/// Options consumed by [PublishRunner.run].
class PublishOptions {
  PublishOptions({
    required this.directory,
    this.dryRun = false,
    this.force = false,
    this.skipValidation = false,
    this.ignoreWarnings = false,
    this.toArchive,
    this.fromArchive,
    this.serverFlag,
    this.versionOverride,
    this.enhanced = false,
    this.pubspecOverride,
  });

  /// Package directory (resolves to cwd if null/empty).
  final String directory;
  final bool dryRun;
  final bool force;
  final bool skipValidation;

  /// When true, warnings do not block publish even without `--force`.
  /// Only valid when `--dry-run` is also set.
  final bool ignoreWarnings;

  /// Write the produced `.tar.gz` to this path instead of uploading.
  final String? toArchive;

  /// Upload an existing `.tar.gz` from this path instead of building one.
  final String? fromArchive;

  /// `--server <url>` override.
  final String? serverFlag;

  /// `--version <version>` override. Replaces the version in the tarball's
  /// pubspec.yaml without modifying source files.
  final String? versionOverride;

  /// `--enhanced` / `-e` mode. Baseline matches `dart pub publish`; enhanced
  /// mode layers on club-specific extras (stricter size limit, stricter
  /// analyze, stricter dep rules, additional leak patterns).
  final bool enhanced;

  /// Full pubspec.yaml content to use in place of the on-disk file. When
  /// set, validators see this content and the tarball ships this content;
  /// the source `pubspec.yaml` is never read or modified. Used by
  /// `club publish --auto` to apply dependency rewrites virtually.
  final String? pubspecOverride;
}

/// The orchestrator. Construct once per `club publish` invocation.
class PublishRunner {
  PublishRunner(this.options);

  final PublishOptions options;

  /// Run the publish flow. Returns an exit code (0 on success).
  Future<int> run() async {
    _validateOptions();

    final pkgDir = p.absolute(
      options.directory.isEmpty ? Directory.current.path : options.directory,
    );

    // When [pubspecOverride] is set, parse from the override string instead
    // of disk so every downstream consumer (workspace resolver, validators,
    // tarball builder) sees the post-rewrite shape. The source pubspec
    // file is never read or mutated.
    final pubspec = options.pubspecOverride != null
        ? parsePubspec(
            pkgDir,
            options.pubspecOverride!,
            versionOverride: options.versionOverride,
          )
        : readPubspec(pkgDir, versionOverride: options.versionOverride);

    // Club deliberately diverges from dart pub here: `publish_to: none`,
    // `publish_to` missing, and `publish_to: https://pub.dev/` are all
    // accepted by club publish. The target server is resolved from the
    // user's logins via [ServerResolver]. See server_resolver.dart for
    // the exact rules.

    // ── Workspace resolution ────────────────────────────────────────────────
    // When this package has `resolution: workspace`, find the workspace root
    // above it and verify the root includes us. Matches dart pub's behaviour
    // from `Entrypoint._loadWorkspace`.
    final WorkspaceContext workspace;
    try {
      workspace = resolveWorkspace(
        workPackageDir: pkgDir,
        workPackageResolution: pubspec.resolution,
      );
    } on WorkspaceResolutionError catch (e) {
      error(e.message);
      if (e.hint != null) hint(e.hint!);
      return ExitCodes.config;
    }

    // ── Header ──────────────────────────────────────────────────────────────
    info('');
    if (options.versionOverride != null) {
      info(
        '📦 Publishing ${bold(pubspec.name)} ${cyan(pubspec.version)}'
        ' ${gray('(overridden)')}',
      );
    } else {
      info('📦 Publishing ${bold(pubspec.name)} ${cyan(pubspec.version)}');
    }
    detail('from $pkgDir');
    if (workspace.isWorkspaceMember) {
      detail('workspace root: ${workspace.workspaceRootDir}');
    }

    final resolver = ServerResolver();
    final ResolvedServer server;
    try {
      server = await resolver.resolve(
        serverFlag: options.serverFlag,
        pubspec: pubspec,
      );
    } on ServerResolutionError catch (e) {
      error(e.message);
      if (e.hint != null) hint(e.hint!);
      return ExitCodes.config;
    } on NonInteractiveError catch (e) {
      error(e.message);
      return ExitCodes.config;
    }

    detail(
      'to ${bold(displayServer(server.url))} '
      '${gray("(${describeServerSource(server.source)})")}',
    );

    final client = ClubClient(
      serverUrl: Uri.parse(server.url),
      token: server.token,
    );

    BuiltTarball? builtTarball;
    var weCreatedTempTarball = false;

    try {
      // ── Version collision pre-check ─────────────────────────────────────
      // Club extension over dart pub: refuse to re-publish an existing
      // version unless -f is passed. The server permits re-publishes for
      // operational convenience (CI loops, test builds), but by default
      // the CLI should protect users from overwriting a shipped release.
      final publishedVersions = await _fetchPublishedVersions(
        client,
        pubspec.name,
      );
      if (publishedVersions.contains(pubspec.version)) {
        if (!options.force) {
          error(
            '${pubspec.name} ${pubspec.version} is already published to '
            '${displayServer(server.url)}.',
          );
          hint(
            'Bump the version in pubspec.yaml, or pass -f / --force '
            'to re-publish over the existing version.',
          );
          return ExitCodes.data;
        }

        // -f still requires a human confirmation on an interactive TTY —
        // forcing over a shipped release is rarely what someone actually
        // wants, and the flag is often set by muscle memory. CI jobs and
        // non-interactive shells skip the extra prompt: passing -f from
        // an automation context is consent enough.
        warning(
          '${pubspec.name} ${pubspec.version} is already published to '
          '${displayServer(server.url)}.',
        );
        if (isInteractive && !isCI) {
          info('');
          final ok = await confirm(
            'Overwrite the existing ${cyan(pubspec.version)} on '
            '${bold(displayServer(server.url))}?',
            defaultAnswer: false,
          );
          if (!ok) {
            info('Aborted.');
            return ExitCodes.config;
          }
        } else {
          detail(
            gray(
              isCI
                  ? 'CI environment detected; proceeding with forced '
                        're-publish without a confirmation prompt.'
                  : '--force set in a non-interactive shell; proceeding '
                        'without a confirmation prompt.',
            ),
          );
        }
      }

      // ── Build / load tarball ──────────────────────────────────────────────
      final BuiltTarball tarball;
      if (options.fromArchive != null) {
        tarball = await _loadExistingArchive(options.fromArchive!);
        heading('Using existing archive');
        detail(
          '${tarball.path} '
          '(${_formatBytes(tarball.sizeBytes)}, ${tarball.files.length} files)',
        );
      } else {
        heading('Building package archive');
        final sw = Stopwatch()..start();
        tarball = await TarballBuilder(pkgDir).build(
          outputPath: options.toArchive,
          versionOverride: options.versionOverride,
          pubspecOverride: options.pubspecOverride,
        );
        sw.stop();
        weCreatedTempTarball = options.toArchive == null;
        detail(tarball.path);
        detail(
          '${_formatBytes(tarball.sizeBytes)}, '
          '${tarball.files.length} files '
          '${gray('(${formatDuration(sw.elapsed)})')}',
        );
      }
      builtTarball = tarball;

      // ── Dependency resolution ─────────────────────────────────────────────
      // Mirrors dart pub's `entrypoint.acquireDependencies(SolveType.get)`
      // at lish.dart:327 — resolving before validation surfaces
      // unresolvable constraints (including cross-workspace conflicts)
      // that static validators can't see.
      if (!options.skipValidation && options.fromArchive == null) {
        final resolveDir = workspace.workspaceRootDir ?? pkgDir;
        final ok = await runDartPubGet(
          resolveDir,
          errorHint:
              'Fix the pubspec, or pass --skip-validation to skip this step.',
        );
        if (!ok) return ExitCodes.data;
      }

      // ── Validation ────────────────────────────────────────────────────────
      if (!options.skipValidation && options.fromArchive == null) {
        final sw = Stopwatch()..start();
        final validationContext = ValidationContext(
          pubspec: pubspec,
          tarball: tarball,
          serverUrl: server.url,
          publishedVersions: publishedVersions,
          enhanced: options.enhanced,
          workspaceRootDir: workspace.workspaceRootDir,
          fetchPublishedPubspec: (version) async {
            try {
              final info = await client.getVersion(pubspec.name, version);
              return info.pubspec;
            } catch (_) {
              return null;
            }
          },
        );
        final count = buildValidators(validationContext).length;
        heading('Running $count validators');
        final report = await runAllValidators(validationContext);
        sw.stop();
        _printReport(report, sw.elapsed);

        if (report.hasErrors) {
          info('');
          error(
            'Found ${report.errors.length} error(s). '
            'Fix them or pass --skip-validation.',
          );
          return ExitCodes.data;
        }
        if (report.hasWarnings && !options.ignoreWarnings && !options.force) {
          if (options.dryRun) {
            info('');
            error(
              'Found ${report.warnings.length} warning(s). '
              'Pass --ignore-warnings to allow warnings in --dry-run mode.',
            );
            return ExitCodes.data;
          }
          final ok = await _confirmIgnoreWarnings();
          if (!ok) return ExitCodes.config;
        }
      } else if (options.skipValidation) {
        heading('Validators');
        detail('${yellow('Skipped')}${gray(' (--skip-validation)')}');
      }

      // ── Bail out early for --dry-run / --to-archive ───────────────────────
      if (options.toArchive != null) {
        info('');
        success('Wrote archive to ${tarball.path}');
        return ExitCodes.success;
      }
      if (options.dryRun) {
        box([
          bold('Dry-run complete'),
          '${gray('Package would publish to')} '
              '${bold(displayServer(server.url))}',
        ]);
        return ExitCodes.success;
      }

      // ── Confirm ───────────────────────────────────────────────────────────
      // Skip the prompt when --force is set OR when CI is detected — a
      // CI job running `club publish` on every merge is an explicit
      // (scripted) consent to publish, matching `dart pub publish`'s
      // behaviour of treating CI environments as pre-confirmed.
      if (!options.force && !isCI) {
        final ok = await _confirmPublish(server, pubspec);
        if (!ok) {
          info('Aborted.');
          return ExitCodes.config;
        }
      } else if (isCI && !options.force) {
        detail(
          gray('CI environment detected; skipping confirmation prompt.'),
        );
      }

      // ── Upload ────────────────────────────────────────────────────────────
      heading('Uploading');
      final sw = Stopwatch()..start();
      final message = await client.publishFile(
        tarball.path,
        force: options.force,
      );
      sw.stop();
      detail('${gray('Server:')} $message');
      detail(gray(formatDuration(sw.elapsed)));

      // ── Success summary ───────────────────────────────────────────────────
      final packageUrl =
          '${server.url.replaceAll(RegExp(r'/+$'), '')}'
          '/packages/${pubspec.name}';
      box([
        '🎉 ${bold(pubspec.name)} ${cyan(pubspec.version)} ${green('published')}',
        '${gray('URL')}   ${cyan(packageUrl)}',
        '${gray('Size')}  ${_formatBytes(builtTarball.sizeBytes)}'
            ' (${builtTarball.files.length} files)',
      ]);

      return ExitCodes.success;
    } finally {
      client.close();
      if (weCreatedTempTarball && builtTarball != null) {
        try {
          File(builtTarball.path).deleteSync();
        } catch (_) {
          // Best-effort cleanup; ignore failures.
        }
      }
    }
  }

  // ── Internals ────────────────────────────────────────────────────────────

  void _validateOptions() {
    if (options.dryRun && options.force) {
      throw ArgumentError('--dry-run cannot be combined with --force.');
    }
    if (options.fromArchive != null && options.toArchive != null) {
      throw ArgumentError(
        '--from-archive and --to-archive are mutually exclusive.',
      );
    }
    if (options.fromArchive != null && options.dryRun) {
      throw ArgumentError('--from-archive cannot be combined with --dry-run.');
    }
    if (options.toArchive != null && options.force) {
      throw ArgumentError('--to-archive cannot be combined with --force.');
    }
    if (options.ignoreWarnings && !options.dryRun) {
      throw ArgumentError('--ignore-warnings is only valid with --dry-run.');
    }
    if (options.versionOverride != null && options.fromArchive != null) {
      throw ArgumentError(
        '--version cannot be combined with --from-archive.',
      );
    }
    if (options.versionOverride != null) {
      try {
        semver.Version.parse(options.versionOverride!);
      } on FormatException {
        throw ArgumentError(
          'Invalid version "${options.versionOverride}". '
          'Must be valid semver (e.g. 1.2.3, 1.0.0-beta.1).',
        );
      }
    }
  }

  Future<BuiltTarball> _loadExistingArchive(String path) async {
    final f = File(path);
    if (!f.existsSync()) {
      throw FileSystemException('Archive not found', path);
    }
    return BuiltTarball(
      path: f.absolute.path,
      sizeBytes: await f.length(),
      files: const [],
    );
  }

  Future<List<String>> _fetchPublishedVersions(
    ClubClient client,
    String packageName,
  ) async {
    try {
      final pkg = await client.listVersions(packageName);
      return pkg.versions.map((v) => v.version).toList();
    } catch (_) {
      // Package not found / network error — relative-version validator
      // simply skips its check.
      return const [];
    }
  }

  Future<bool> _confirmIgnoreWarnings() async {
    // In CI we treat the *absence* of `--force` + `--ignore-warnings` as
    // a real signal (the operator didn't opt in), so we still refuse —
    // unlike the top-level publish confirmation, the purpose here is to
    // protect against silently shipping code that validators flagged.
    if (!isInteractive) {
      error(
        'Validators reported warnings. Pass --force to publish anyway, '
        'or fix the warnings first.',
      );
      return false;
    }
    return confirm(
      'Validators reported warnings. Publish anyway?',
      defaultAnswer: false,
    );
  }

  Future<bool> _confirmPublish(
    ResolvedServer server,
    PackagePubspec pubspec,
  ) async {
    if (!isInteractive) {
      error('Refusing to publish in a non-interactive shell without --force.');
      hint('Pass --force to skip this confirmation.');
      return false;
    }
    table(
      ['Package', 'Version', 'Server'],
      [
        [bold(pubspec.name), cyan(pubspec.version), displayServer(server.url)],
      ],
    );
    info('');
    return confirm('Publish?', defaultAnswer: true);
  }

  void _printReport(ValidationReport report, Duration elapsed) {
    for (final f in report.errors) {
      detail('${red('✗ ')}${f.message}');
    }
    for (final f in report.warnings) {
      detail('${yellow('⚠ ')}${f.message}');
    }
    for (final f in report.hints) {
      detail('${cyan('● ')}${f.message}');
    }
    if (report.total == 0) {
      detail(
        '${green('✓ ')}All validators passed. '
        '${gray('(${formatDuration(elapsed)})')}',
      );
    } else {
      detail(
        gray(
          '${report.errors.length} error(s), ${report.warnings.length} '
          'warning(s), ${report.hints.length} hint(s). '
          '(${formatDuration(elapsed)})',
        ),
      );
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '$bytes B';
  }
}
