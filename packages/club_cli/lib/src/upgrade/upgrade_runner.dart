/// Orchestrates `club upgrade`.
///
/// The division of labour: this file resolves *what* to install and
/// decides whether it is allowed to, then hands the actual replacement to
/// the installer script that put this binary here in the first place. See
/// `installer_script.dart` for why that split exists.
library;

import 'dart:convert';
import 'dart:io';

import '../util/log.dart';
import '../util/prompt.dart';
import '../version.dart';
import 'homebrew_upgrader.dart';
import 'install_method.dart';
import 'installer_script.dart';
import 'release_resolver.dart';
import 'release_target.dart';
import 'upgrade_decision.dart';
import 'upgrade_options.dart';

class UpgradeRunner {
  UpgradeRunner(
    this.options, {
    ReleaseResolver? resolver,
    InstallerScript? installer,
    InstallLocation? location,
    String? target,
    HomebrewUpgrader? homebrew,
  }) : _resolver = resolver,
       _installer = installer,
       _location = location,
       _target = target,
       _homebrew = homebrew;

  final UpgradeOptions options;
  final ReleaseResolver? _resolver;
  final InstallerScript? _installer;
  final InstallLocation? _location;
  final String? _target;
  final HomebrewUpgrader? _homebrew;

  final _json = <String, Object?>{};

  Future<int> run() async {
    _json['running'] = clubCliVersion;

    final location = _location ?? detectInstall();
    _json['installMethod'] = location.method.name;
    if (location.method == InstallMethod.homebrew) {
      return _runHomebrew(_homebrew ?? HomebrewUpgrader());
    }

    final resolver = _resolver ?? GithubReleaseResolver();
    try {
      return await _runStandalone(resolver, location);
    } finally {
      resolver.close();
    }
  }

  Future<int> _runStandalone(
    ReleaseResolver resolver,
    InstallLocation location,
  ) async {
    final target = _target ?? detectTarget();
    if (target == null) {
      return _fail(
        ExitCodes.config,
        'No club build is published for ${Platform.operatingSystem} on this '
        'CPU architecture.',
      );
    }
    _json['target'] = target;

    // Refuse before doing any network work when we cannot act on the
    // answer anyway.
    final refusal = _refusalFor(location);
    if (refusal != null) return refusal;

    // Resolve the destination early. A root-owned directory should fail
    // here rather than after a 30 MB download.
    final destDir = options.installDir ?? location.destDir;
    if (!options.check && !options.dryRun) {
      final notWritable = _checkWritable(destDir);
      if (notWritable != null) return notWritable;
    }

    // ── Resolve the release ───────────────────────────────────────
    final pinned = options.version;
    final result = pinned != null
        ? await resolver.resolveTag(pinned)
        : await resolver.resolveLatest(includePreReleases: options.pre);

    if (!result.ok) {
      // A missing release is only an error when the user named one. For a
      // bare upgrade there is simply nothing newer to report.
      if (result.failure == ResolveFailure.noRelease && pinned == null) {
        return _upToDate(null);
      }
      return _fail(ExitCodes.unavailable, result.message!);
    }

    final release = result.release!;

    // ── Asset availability gate ───────────────────────────────────
    if (!release.hasAssetsFor(target)) {
      if (pinned != null) {
        return _fail(
          ExitCodes.unavailable,
          'Release ${release.version} has no $target build yet. This usually '
          'means the release was just published and its build is still '
          'running.',
        );
      }
      // Half-published release. Behave as though it does not exist yet,
      // but record it so --json can explain the apparent contradiction
      // with what the user sees on GitHub.
      _json['pendingVersion'] = release.version;
      return _upToDate(release.version, pending: true);
    }

    // ── Decide ────────────────────────────────────────────────────
    final decision = decideUpgrade(
      runningVersion: clubCliVersion,
      pinnedVersion: pinned == null ? null : release.version,
      latestVersion: release.version,
      force: options.force,
    );

    switch (decision.action) {
      case UpgradeAction.refuseDevSource:
        return _refuseDevSource();
      case UpgradeAction.refuseLocalBuild:
        return _refuseLocalBuild(release.version);
      case UpgradeAction.upToDate:
        return _upToDate(release.version);
      case UpgradeAction.upgrade:
      case UpgradeAction.reinstall:
      case UpgradeAction.downgrade:
        break;
    }

    _json['latest'] = release.version;
    _json['updateAvailable'] = decision.action == UpgradeAction.upgrade;

    if (options.check) {
      if (decision.action == UpgradeAction.upgrade) {
        _emitJson();
        if (!options.json) {
          info(
            'A newer club is available: '
            '${gray(clubCliVersion)} → ${green(release.version)}',
          );
          hint('Run: club upgrade');
        }
        return ExitCodes.data;
      }
      _emitJson();
      if (!options.json) {
        success('club $clubCliVersion is the latest release.');
      }
      return ExitCodes.success;
    }

    if (options.dryRun) {
      _emitJson();
      if (!options.json) {
        info('Would install club ${release.version} ($target)');
        detail('from ${release.htmlUrl ?? 'the GitHub release'}');
        detail('into ${destDir ?? 'the installer default directory'}');
      }
      return ExitCodes.success;
    }

    // A downgrade is the one case worth a question: the user pinned an
    // older version, which is easy to do by accident and awkward to undo.
    if (decision.action == UpgradeAction.downgrade && !options.yes) {
      try {
        final ok = await confirm(
          'Downgrade club $clubCliVersion to ${release.version}?',
        );
        if (!ok) return ExitCodes.success;
      } on NonInteractiveError {
        error(
          'Refusing to downgrade $clubCliVersion to ${release.version} '
          'without confirmation.',
        );
        hint('Pass --yes to confirm in a non-interactive shell.');
        return ExitCodes.noInput;
      }
    }

    // ── Hand off to the installer ─────────────────────────────────
    // No "Upgrading X → Y" line here on purpose: install.sh and
    // install.ps1 both detect the existing install and print exactly that,
    // so announcing it here too would just say the same thing twice.
    final installer = _installer ?? InstallerScript();
    try {
      final code = await installer.run(
        version: release.version,
        installDir: destDir,
      );
      if (code != ExitCodes.success) {
        error('The installer exited with code $code.');
        hint(
          'Recover with: '
          '${installOneLiner(version: release.version, installDir: destDir)}',
        );
        return ExitCodes.software;
      }
      return ExitCodes.success;
    } on InstallerScriptException catch (e) {
      error(e.message);
      hint(
        'Recover with: '
        '${installOneLiner(version: release.version, installDir: destDir)}',
      );
      return ExitCodes.unavailable;
    } finally {
      installer.close();
    }
  }

  // ── Homebrew ───────────────────────────────────────────────────

  Future<int> _runHomebrew(HomebrewUpgrader homebrew) async {
    final unsupported = _unsupportedHomebrewOption();
    if (unsupported != null) return unsupported;

    final action = options.check
        ? 'check'
        : options.force
        ? 'reinstall'
        : 'upgrade';
    final commands = <List<String>>[
      ['update'],
      if (options.check)
        ['outdated', '--quiet', '--formula', 'club']
      else
        [
          options.force ? 'reinstall' : 'upgrade',
          if (options.yes) '--yes',
          'club',
        ],
    ];
    _json['homebrewAction'] = action;
    _json['commands'] = [
      for (final command in commands) ['brew', ...command],
    ];

    if (options.dryRun) {
      _json['dryRun'] = true;
      _json['updateAvailable'] = false;
      _emitJson();
      if (!options.json) {
        info(
          options.force
              ? 'Would reinstall this Homebrew installation with:'
              : 'Would upgrade this Homebrew installation with:',
        );
        for (final command in commands) {
          detail('brew ${command.join(' ')}');
        }
      }
      return ExitCodes.success;
    }

    final update = await homebrew.run(
      commands.first,
      captureOutput: options.json,
    );
    final updateFailure = _homebrewFailure('update', update, commands.first);
    if (updateFailure != null) return updateFailure;

    final command = commands.last;
    final result = await homebrew.run(
      command,
      captureOutput: options.json || options.check,
    );
    final failure = _homebrewFailure(action, result, command);
    if (failure != null) return failure;

    if (options.check) {
      final updateAvailable = result.stdout.trim().isNotEmpty;
      _json['updateAvailable'] = updateAvailable;
      _emitJson();
      if (!options.json) {
        if (updateAvailable) {
          info('A newer Homebrew formula for club is available.');
          hint('Run: club upgrade');
        } else {
          success('club $clubCliVersion is the latest Homebrew formula.');
        }
      }
      return updateAvailable ? ExitCodes.data : ExitCodes.success;
    }

    _json['updated'] = true;
    _json['updateAvailable'] = false;
    _recordHomebrewOutput(result);
    _emitJson();
    if (!options.json) {
      success(
        options.force
            ? 'Reinstalled club with Homebrew.'
            : 'Homebrew finished upgrading club.',
      );
    }
    return ExitCodes.success;
  }

  int? _unsupportedHomebrewOption() {
    if (options.version != null) {
      return _fail(
        ExitCodes.config,
        'Homebrew installations cannot upgrade to a pinned Club version.',
        hints: ['Run: brew update && brew upgrade club'],
      );
    }
    if (options.pre) {
      return _fail(
        ExitCodes.config,
        'The Homebrew formula only tracks stable Club releases.',
        hints: ['Install a pre-release with: ${installOneLiner()}'],
      );
    }
    if (options.installDir != null) {
      return _fail(
        ExitCodes.config,
        'Homebrew owns the Club installation directory.',
        hints: ['Remove --install-dir, or use: ${installOneLiner()}'],
      );
    }
    return null;
  }

  int? _homebrewFailure(
    String phase,
    HomebrewResult result,
    List<String> command,
  ) {
    if (result.succeeded) return null;

    _json['homebrewPhase'] = phase;
    _json['homebrewExitCode'] = result.exitCode;
    _recordHomebrewOutput(result);
    final rendered = 'brew ${command.join(' ')}';
    if (result.executableMissing) {
      return _fail(
        ExitCodes.unavailable,
        'Could not run Homebrew. Make sure `brew` is available on PATH.',
        hints: ['Then retry: $rendered'],
      );
    }
    return _fail(
      ExitCodes.software,
      'Homebrew failed during `$rendered` with exit code ${result.exitCode}.',
      hints: ['Retry directly: $rendered'],
    );
  }

  void _recordHomebrewOutput(HomebrewResult result) {
    final out = result.stdout.trim();
    final err = result.stderr.trim();
    if (out.isNotEmpty) _json['homebrewStdout'] = out;
    if (err.isNotEmpty) _json['homebrewStderr'] = err;
  }

  // ── Refusals ────────────────────────────────────────────────────

  int? _refusalFor(InstallLocation location) {
    switch (location.method) {
      case InstallMethod.homebrew:
        return null;
      case InstallMethod.devSource:
        return _refuseDevSource();
      case InstallMethod.pubGlobal:
        return _fail(
          ExitCodes.config,
          'This club was installed with `dart pub global activate`.',
          hints: [
            'Run: dart pub global activate club_cli',
            'Or install a release: ${installOneLiner()}',
          ],
        );
      case InstallMethod.scriptBundleWindows:
        return _fail(
          ExitCodes.config,
          'Self-upgrade is not supported for the Windows bundle layout, '
          'because a running club.exe cannot be moved out of its directory.',
          hints: ['Run: ${installOneLiner()}'],
        );
      case InstallMethod.unknown:
        return _fail(
          ExitCodes.config,
          'Could not work out how this club was installed '
          '(${location.executablePath}).',
          hints: ['Install a release with: ${installOneLiner()}'],
        );
      case InstallMethod.scriptStandalone:
      case InstallMethod.scriptBundle:
      case InstallMethod.scriptStandaloneWindows:
        return null;
    }
  }

  int _refuseDevSource() => _fail(
    ExitCodes.config,
    'You are running club from source (version "dev"), not an installed '
    'release.',
    hints: [
      'Build a local binary: ./scripts/build-cli.sh',
      'Or install a release: ${installOneLiner()}',
    ],
  );

  int _refuseLocalBuild(String latest) {
    if (options.check) {
      // Mirrors how club_server's update checker skips the check entirely
      // for non-stable versions. Never report an update as available here,
      // or --check and upgrade would disagree.
      _json['latest'] = latest;
      _json['updateAvailable'] = false;
      _emitJson();
      if (!options.json) {
        info(
          'Running a local build ($clubCliVersion). '
          'Latest release is $latest.',
        );
      }
      return ExitCodes.success;
    }
    return _fail(
      ExitCodes.config,
      'You are running a local build ($clubCliVersion), not a released '
      'version.',
      hints: [
        'Rebuild locally: ./scripts/build-cli.sh',
        'Or replace it with release $latest: club upgrade --force',
      ],
    );
  }

  // ── Outcomes ────────────────────────────────────────────────────

  int _upToDate(String? latest, {bool pending = false}) {
    _json['latest'] = latest;
    _json['updateAvailable'] = false;
    _emitJson();
    if (options.json) return ExitCodes.success;

    success('club $clubCliVersion is the latest release.');
    if (pending) {
      // Without this, someone looking at a newer tag on GitHub gets a flat
      // contradiction from the CLI and no way to explain it.
      detail(
        'Release $latest is published but its build has not finished '
        'uploading yet.',
      );
    }
    return ExitCodes.success;
  }

  int _fail(int code, String message, {List<String> hints = const []}) {
    if (options.json) {
      _json['error'] = message;
      _json['updateAvailable'] ??= false;
      _emitJson();
      return code;
    }
    error(message);
    for (final h in hints) {
      hint(h);
    }
    return code;
  }

  /// Returns an exit code when [destDir] is not writable, else null.
  ///
  /// Dart has no `access(2)`, so the honest check is to actually create a
  /// file. Doing it up front turns "failed after a 30 MB download" into an
  /// immediate, actionable error. The directory is what matters rather
  /// than the binary, because the installer replaces via a rename within
  /// it.
  int? _checkWritable(String? destDir) {
    if (destDir == null) return null;
    final dir = Directory(destDir);
    if (!dir.existsSync()) return null;
    final probe = File('$destDir/.club-upgrade-probe-$pid');
    try {
      probe.writeAsStringSync('');
      probe.deleteSync();
      return null;
    } on FileSystemException catch (e) {
      return _fail(
        ExitCodes.config,
        'Cannot write to $destDir (${e.osError?.message ?? e.message}).',
        hints: [
          'Install into a directory you own: '
              '${installOneLiner(installDir: r'$HOME/.local/bin')}',
        ],
      );
    }
  }

  void _emitJson() {
    if (!options.json) return;
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(_json));
  }
}
