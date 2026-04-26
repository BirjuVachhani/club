import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:club_core/club_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('SdkManager');

/// Flutter git repository URL used for cloning SDKs.
const _flutterGitUrl = 'https://github.com/flutter/flutter.git';

/// A single Flutter release from the Flutter release API.
class FlutterRelease {
  const FlutterRelease({
    required this.version,
    required this.channel,
    required this.dartVersion,
  });

  final String version;
  final String channel;
  final String dartVersion;

  Map<String, dynamic> toJson() => {
    'version': version,
    'channel': channel,
    'dartVersion': dartVersion,
  };
}

/// Install progress for an in-flight SDK install.
class InstallProgress {
  InstallProgress({
    required this.installId,
    required this.phase,
    this.error,
  });

  final String installId;
  String phase; // cloning | settingUp | ready | failed
  String? error;

  /// Log lines captured from git clone and flutter setup.
  final logs = <String>[];

  Map<String, dynamic> toJson() => {
    'installId': installId,
    'phase': phase,
    'error': error,
    'logs': logs,
  };
}

/// Manages Flutter SDK installations via git clone and lifecycle.
///
/// SDKs are stored at `<sdkBaseDir>/<version>/flutter/`.
class SdkManager {
  SdkManager({
    required SettingsStore settingsStore,
    required this.sdkBaseDir,
    required String Function() generateId,
  }) : _settings = settingsStore,
       _generateId = generateId;

  final SettingsStore _settings;
  final String sdkBaseDir;
  final String Function() _generateId;

  /// In-flight install progress keyed by install ID.
  final _inFlight = <String, InstallProgress>{};

  /// Detected platform string (e.g. `linux_x64`, `macos_arm64`).
  late final String platform;

  /// Detected OS name for the Flutter release API (`linux` or `macos`).
  late final String _os;

  /// The error message from the most recent [discoverOrphanedSdks] run,
  /// or null if the last run (or no run) succeeded. Surfaced in the
  /// admin UI so operators notice startup reconciliation failures
  /// without reading server logs. Per-SDK rebuild failures are tracked
  /// on the `sdk_installs` rows themselves, not here.
  String? _lastDiscoveryError;
  DateTime? _lastDiscoveryAt;

  String? get lastDiscoveryError => _lastDiscoveryError;
  DateTime? get lastDiscoveryAt => _lastDiscoveryAt;

  // ── Initialization ──────────────────────────────────────────

  /// Called at server startup. Detects platform, cleans up incomplete
  /// installs, verifies existing installs.
  Future<void> initialize() async {
    await _detectPlatform();

    // Ensure directories exist.
    await Directory(sdkBaseDir).create(recursive: true);

    // Clean up incomplete installs from a previous crash.
    final incomplete = await _settings.listIncompleteInstalls();
    for (final install in incomplete) {
      _log.info(
        'Cleaning up incomplete install: ${install.version} (${install.status.name})',
      );
      await _settings.updateSdkInstallStatus(
        install.id,
        status: SdkInstallStatus.failed,
        errorMessage: 'Server restarted during ${install.status.name}.',
      );
      // Delete partial install directory.
      _cleanupFiles(install);
    }

    // Verify 'ready' installs actually exist on disk.
    final installs = await _settings.listSdkInstalls();
    for (final install in installs) {
      if (install.status != SdkInstallStatus.ready) continue;
      if (!await Directory(install.installPath).exists()) {
        _log.warning(
          'SDK directory missing for ${install.version}, marking as failed',
        );
        await _settings.updateSdkInstallStatus(
          install.id,
          status: SdkInstallStatus.failed,
          errorMessage: 'SDK directory was removed.',
        );
      }
    }

    _log.info(
      'SDK manager initialized (platform: $platform, sdkDir: $sdkBaseDir)',
    );

    // Pick up any SDK directories that exist on disk but aren't in the DB.
    // Covers the "fresh container, existing /data volume" restore scenario.
    // Fire-and-forget: each directory probe runs `flutter --version`, so a
    // multi-SDK scan can take tens of seconds. Startup must not wait on it.
    // Errors are already logged + stashed on [lastDiscoveryError] by
    // [discoverOrphanedSdks]; the catchError below just absorbs the
    // rethrown exception so the unawaited future doesn't surface as an
    // uncaught async error.
    // ignore: unawaited_futures
    discoverOrphanedSdks().catchError((Object _) => const <SdkInstall>[]);
  }

  Future<void> _detectPlatform() async {
    _os = Platform.operatingSystem; // 'linux' or 'macos'
    final result = await Process.run('uname', ['-m']);
    final arch = result.stdout.toString().trim();
    final normArch = (arch == 'aarch64' || arch == 'arm64') ? 'arm64' : 'x64';
    platform = '${_os}_$normArch';
  }

  // ── Available versions ──────────────────────────────────────

  /// Fetch available Flutter releases from the official API.
  Future<List<FlutterRelease>> fetchAvailableVersions({
    String? channel,
  }) async {
    final url =
        'https://storage.googleapis.com/flutter_infra_release/'
        'releases/releases_$_os.json';

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception(
          'Failed to fetch Flutter releases: HTTP ${response.statusCode}',
        );
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final releases = (json['releases'] as List).cast<Map<String, dynamic>>();

      return releases
          .where((r) {
            if (channel != null && r['channel'] != channel) return false;
            return true;
          })
          .map(
            (r) => FlutterRelease(
              version: r['version'] as String,
              channel: r['channel'] as String,
              dartVersion: (r['dart_sdk_version'] as String?) ?? '',
            ),
          )
          .toList();
    } finally {
      client.close();
    }
  }

  // ── Install ─────────────────────────────────────────────────

  /// Start installing a Flutter SDK version via git clone.
  ///
  /// If the version is already installed and ready, returns the existing
  /// record. If an install is already in progress, returns it (idempotent).
  Future<SdkInstall> startInstall({
    required String version,
    required String channel,
  }) async {
    // Check for existing install.
    final existing = await _settings.lookupSdkInstallByVersion(
      version,
      channel,
    );
    if (existing != null) {
      if (existing.status == SdkInstallStatus.ready) return existing;
      if (existing.status == SdkInstallStatus.cloning ||
          existing.status == SdkInstallStatus.settingUp) {
        return existing; // Already in progress.
      }
      // Failed — delete and retry.
      await _settings.deleteSdkInstall(existing.id);
      _cleanupFiles(existing);
    }

    final id = _generateId();
    final installPath = '$sdkBaseDir/$version';

    final install = await _settings.createSdkInstall(
      SdkInstallCompanion(
        id: id,
        channel: channel,
        version: version,
        installPath: installPath,
        status: SdkInstallStatus.cloning,
      ),
    );

    // Track progress in memory.
    final progress = InstallProgress(
      installId: id,
      phase: 'cloning',
    );
    _inFlight[id] = progress;

    // Run install in background (fire-and-forget).
    // ignore: unawaited_futures
    _runInstall(install, progress).catchError((e) {
      _log.severe('Install failed for $version: $e');
    });

    return install;
  }

  /// Scans [sdkBaseDir] for valid Flutter SDK directories that have no
  /// matching DB row, registers each one, and fires the setup re-run in
  /// the background (same as [rebuild]). Returns the newly-created
  /// installs.
  ///
  /// Used on startup to rehydrate state after the container is recreated
  /// against an existing `/data` volume, and by the admin "Scan" button.
  /// Directories that fail the validity heuristic are skipped silently —
  /// cleanup of orphan files is a separate concern.
  Future<List<SdkInstall>> discoverOrphanedSdks() async {
    _lastDiscoveryAt = DateTime.now().toUtc();
    try {
      final discovered = await _discoverOrphanedSdks();
      _lastDiscoveryError = null;
      return discovered;
    } catch (e) {
      _lastDiscoveryError = '$e';
      _log.severe('SDK discovery failed: $e');
      rethrow;
    }
  }

  Future<List<SdkInstall>> _discoverOrphanedSdks() async {
    final baseDir = Directory(sdkBaseDir);
    if (!await baseDir.exists()) return const [];

    final existing = await _settings.listSdkInstalls();
    final knownVersions = {for (final i in existing) i.version};

    // The `default_sdk_version` setting survives across restores. When a
    // matching version is rediscovered we re-apply its is_default flag so
    // the "first rebuild to finish wins" race in _runSetupSteps doesn't
    // hand the default to an arbitrary SDK.
    final preservedDefault = await _settings.getDefaultSdkVersion();

    final discovered = <SdkInstall>[];

    await for (final entry in baseDir.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final version = p.basename(entry.path);
      if (knownVersions.contains(version)) continue;

      if (!await _isValidSdkDir(entry.path)) {
        _log.info('Skipping non-SDK path in sdkBaseDir: ${entry.path}');
        continue;
      }

      final channel = await _resolveChannel(version);
      final id = _generateId();
      final install = await _settings.createSdkInstall(
        SdkInstallCompanion(
          id: id,
          channel: channel,
          version: version,
          installPath: entry.path,
          status: SdkInstallStatus.settingUp,
        ),
      );

      if (preservedDefault != null && preservedDefault == version) {
        await _settings.setDefaultSdkInstall(id);
        _log.info(
          'Restored $version as default SDK (preserved from settings).',
        );
      }

      discovered.add(install);
      _log.info(
        'Discovered orphaned SDK $version ($channel); queuing rebuild.',
      );

      final progress = InstallProgress(installId: id, phase: 'settingUp');
      _inFlight[id] = progress;
      // Fire-and-forget: rebuild runs `flutter --version` + `flutter
      // precache` and can take minutes. Startup must not block on it.
      // ignore: unawaited_futures
      _runSetup(install, progress).catchError((e) {
        _log.severe('Orphan rebuild failed for $version: $e');
      });
    }

    return discovered;
  }

  /// Validity heuristic: the Flutter launcher and the bundled Dart SDK
  /// version file must both be present, and the launcher must execute
  /// with a zero exit code. Confirms we're looking at a real Flutter
  /// checkout and not a stray file or a half-extracted clone.
  Future<bool> _isValidSdkDir(String path) async {
    final flutterBin = File('$path/flutter/bin/flutter');
    final dartVersion = File('$path/flutter/bin/cache/dart-sdk/version');
    if (!await flutterBin.exists()) return false;
    if (!await dartVersion.exists()) return false;
    try {
      final result = await Process.run(flutterBin.path, ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Resolve the channel for a discovered SDK by looking the version up
  /// in the Flutter release API. Falls back to `stable` when the API is
  /// unreachable — the channel is cosmetic metadata and the scoring
  /// pipeline only needs the installed binary.
  Future<String> _resolveChannel(String version) async {
    try {
      final releases = await fetchAvailableVersions();
      for (final r in releases) {
        if (r.version == version) return r.channel;
      }
    } catch (e) {
      _log.warning(
        'Flutter release API unreachable; defaulting channel to stable for $version: $e',
      );
    }
    return 'stable';
  }

  /// Rebuild an existing SDK install by re-running setup steps
  /// (flutter --version, flutter precache) without re-cloning.
  Future<SdkInstall> rebuild(String installId) async {
    final install = await _settings.lookupSdkInstall(installId);
    if (install == null) {
      throw NotFoundException('SDK install \'$installId\' was not found.');
    }
    if (install.status == SdkInstallStatus.cloning ||
        install.status == SdkInstallStatus.settingUp) {
      throw InvalidInputException(
        'SDK ${install.version} is already being set up.',
      );
    }

    // Verify the clone exists on disk.
    final flutterDir = Directory('${install.installPath}/flutter');
    if (!flutterDir.existsSync()) {
      throw InvalidInputException(
        'Flutter directory missing at ${install.installPath}/flutter. '
        'Delete and reinstall this SDK.',
      );
    }

    await _settings.updateSdkInstallStatus(
      install.id,
      status: SdkInstallStatus.settingUp,
    );

    final progress = InstallProgress(
      installId: install.id,
      phase: 'settingUp',
    );
    _inFlight[install.id] = progress;

    // Run setup in background.
    // ignore: unawaited_futures
    _runSetup(install, progress).catchError((e) {
      _log.severe('Rebuild failed for ${install.version}: $e');
    });

    return (await _settings.lookupSdkInstall(install.id))!;
  }

  Future<void> _runInstall(SdkInstall install, InstallProgress progress) async {
    try {
      // ── Clone ───────────────────────────────────────────────
      final installDir = Directory(install.installPath);
      if (await installDir.exists()) {
        await installDir.delete(recursive: true);
      }
      await installDir.create(recursive: true);

      progress.logs.add(
        'Cloning Flutter ${install.version} from $_flutterGitUrl ...',
      );

      await _runProcess(
        'git',
        [
          'clone',
          '-b',
          install.version,
          '--depth',
          '1',
          _flutterGitUrl,
          'flutter',
        ],
        workingDirectory: install.installPath,
        progress: progress,
      );

      // ── Setup ───────────────────────────────────────────────
      await _runSetupSteps(install, progress);
    } catch (e) {
      final error = '$e';
      _log.warning('SDK install failed for ${install.version}: $error');
      progress.phase = 'failed';
      progress.error = error;
      progress.logs.add('');
      progress.logs.add('ERROR: $error');

      await _settings.updateSdkInstallStatus(
        install.id,
        status: SdkInstallStatus.failed,
        errorMessage: error,
      );
    } finally {
      Future.delayed(const Duration(minutes: 5), () {
        _inFlight.remove(install.id);
      });
    }
  }

  /// Runs setup on an already-cloned SDK (used by both install and rebuild).
  Future<void> _runSetup(SdkInstall install, InstallProgress progress) async {
    try {
      await _runSetupSteps(install, progress);
    } catch (e) {
      final error = '$e';
      _log.warning('SDK setup failed for ${install.version}: $error');
      progress.phase = 'failed';
      progress.error = error;
      progress.logs.add('');
      progress.logs.add('ERROR: $error');

      await _settings.updateSdkInstallStatus(
        install.id,
        status: SdkInstallStatus.failed,
        errorMessage: error,
      );
    } finally {
      Future.delayed(const Duration(minutes: 5), () {
        _inFlight.remove(install.id);
      });
    }
  }

  /// The shared setup steps: flutter --version, flutter precache, finalize.
  Future<void> _runSetupSteps(
    SdkInstall install,
    InstallProgress progress,
  ) async {
    progress.phase = 'settingUp';
    await _settings.updateSdkInstallStatus(
      install.id,
      status: SdkInstallStatus.settingUp,
    );

    final flutterBin = '${install.installPath}/flutter/bin/flutter';
    final flutterEnv = {'CI': 'true'};

    progress.logs.add('');
    progress.logs.add('Running flutter --version to download Dart SDK...');

    await _runProcess(
      flutterBin,
      ['--version'],
      workingDirectory: install.installPath,
      progress: progress,
      environment: flutterEnv,
    );

    progress.logs.add('');
    progress.logs.add(
      'Running flutter precache to download internal packages...',
    );

    await _runProcess(
      flutterBin,
      ['precache'],
      workingDirectory: install.installPath,
      progress: progress,
      environment: flutterEnv,
    );

    // Detect Dart version.
    final dartVersionFile = File(
      '${install.installPath}/flutter/bin/cache/dart-sdk/version',
    );
    String? dartVersion;
    if (await dartVersionFile.exists()) {
      dartVersion = (await dartVersionFile.readAsString()).trim();
    }

    // ── Finalize ────────────────────────────────────────────
    final installDir = Directory(install.installPath);
    final sizeBytes = await _directorySize(installDir);

    await _settings.updateSdkInstallStatus(
      install.id,
      status: SdkInstallStatus.ready,
      dartVersion: dartVersion,
      sizeBytes: sizeBytes,
      installedAt: DateTime.now().toUtc(),
    );

    // Auto-set as default if this is the only ready SDK.
    final allInstalls = await _settings.listSdkInstalls();
    final readyCount = allInstalls
        .where((i) => i.status == SdkInstallStatus.ready)
        .length;
    if (readyCount == 1) {
      await _settings.setDefaultSdkInstall(install.id);
      _log.info('Auto-set ${install.version} as default (only installed SDK)');
    }

    progress.phase = 'ready';
    progress.logs.add('');
    progress.logs.add('SDK ${install.version} setup completed successfully.');
    _log.info(
      'SDK ${install.version} setup completed at ${install.installPath}',
    );
  }

  /// Run a process, streaming stdout and stderr into [progress.logs].
  Future<void> _runProcess(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required InstallProgress progress,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );

    // Stream stdout and stderr into logs.
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => progress.logs.add(line))
        .asFuture<void>();

    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => progress.logs.add(line))
        .asFuture<void>();

    await Future.wait([stdoutDone, stderrDone]);
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      throw Exception(
        '`$executable ${arguments.join(' ')}` exited with code $exitCode',
      );
    }
  }

  // ── Progress ────────────────────────────────────────────────

  /// Get install progress for an in-flight install.
  InstallProgress? getProgress(String installId) => _inFlight[installId];

  // ── Management ──────────────────────────────────────────────

  /// Mark a version as the default SDK used for scoring.
  Future<void> setDefault(String installId) async {
    final install = await _settings.lookupSdkInstall(installId);
    if (install == null) {
      throw NotFoundException('SDK install \'$installId\' was not found.');
    }
    if (install.status != SdkInstallStatus.ready) {
      throw InvalidInputException('SDK ${install.version} is not ready.');
    }
    await _settings.setDefaultSdkInstall(installId);
    _log.info('Default SDK set to ${install.version}');
  }

  /// Delete an installed SDK version.
  Future<void> deleteInstall(String installId) async {
    final install = await _settings.lookupSdkInstall(installId);
    if (install == null) {
      throw NotFoundException('SDK install \'$installId\' was not found.');
    }

    // Remove from DB first.
    await _settings.deleteSdkInstall(installId);

    // Clean up files.
    _cleanupFiles(install);
    _inFlight.remove(installId);
    _log.info('SDK ${install.version} deleted');
  }

  /// List all installed SDK versions.
  Future<List<SdkInstall>> listInstalled() => _settings.listSdkInstalls();

  /// Path to the default Flutter SDK, or null if none configured.
  Future<String?> getDefaultFlutterSdkPath() async {
    final installs = await _settings.listSdkInstalls();
    final defaultInstall = installs
        .where((i) => i.isDefault && i.status == SdkInstallStatus.ready)
        .firstOrNull;
    if (defaultInstall == null) return null;
    return '${defaultInstall.installPath}/flutter';
  }

  /// Path to the default Dart SDK (inside Flutter), or null.
  Future<String?> getDefaultDartSdkPath() async {
    final flutterPath = await getDefaultFlutterSdkPath();
    if (flutterPath == null) return null;
    return '$flutterPath/bin/cache/dart-sdk';
  }

  /// Check available disk space. Throws if insufficient.
  Future<int> getAvailableDiskSpace() async {
    final result = await Process.run('df', ['-k', sdkBaseDir]);
    if (result.exitCode != 0) return -1;
    final lines = (result.stdout as String).split('\n');
    if (lines.length < 2) return -1;
    final parts = lines[1].split(RegExp(r'\s+'));
    if (parts.length < 4) return -1;
    final availableKb = int.tryParse(parts[3]);
    if (availableKb == null) return -1;
    return availableKb * 1024; // Return bytes.
  }

  // ── Internal ────────────────────────────────────────────────

  void _cleanupFiles(SdkInstall install) {
    try {
      final dir = Directory(install.installPath);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (e) {
      _log.warning('Failed to clean up ${install.installPath}: $e');
    }
  }

  Future<int> _directorySize(Directory dir) async {
    int total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }
}
