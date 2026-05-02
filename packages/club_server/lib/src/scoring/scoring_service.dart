import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:club_core/club_core.dart';
import 'package:club_indexed_blob/club_indexed_blob.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart' show DartdocBackend;
import 'sandbox.dart';
import 'scoring_logger.dart';
import 'scoring_worker.dart';

/// Runtime-resolved scoring configuration.
///
/// Unlike the old env-var based `ScoringConfig`, this is produced on-demand
/// by querying the settings store and SDK manager, allowing the admin to
/// enable/disable scoring and switch SDK versions without a server restart.
class ScoringConfig {
  const ScoringConfig({
    required this.enabled,
    this.dartSdkPath,
    this.flutterSdkPath,
    this.pubCacheDir,
    this.licenseDataDir,
    this.workerCount = 1,
    this.sandbox = SandboxConfig.none,
    this.subprocessBinary,
  });

  const ScoringConfig.disabled()
    : enabled = false,
      dartSdkPath = null,
      flutterSdkPath = null,
      pubCacheDir = null,
      licenseDataDir = null,
      workerCount = 1,
      sandbox = SandboxConfig.none,
      subprocessBinary = null;

  final bool enabled;
  final String? dartSdkPath;
  final String? flutterSdkPath;
  final String? pubCacheDir;
  final String? licenseDataDir;
  final int workerCount;

  /// OS-level hardening applied to every pana subprocess.
  final SandboxConfig sandbox;

  /// Absolute path to the AOT-compiled scoring subprocess binary. Required
  /// in production (Docker images set this via `SCORING_SUBPROCESS_BINARY`
  /// env var). If null, the service falls back to running pana via
  /// `dart run club_server:scoring_subprocess` — fine for development, too
  /// slow for prod cold-starts.
  final String? subprocessBinary;

  String get status {
    if (!enabled) return 'disabled';
    return flutterSdkPath != null ? 'full' : 'dart-only';
  }
}

/// One in-flight scoring subprocess, surfaced to the admin API so operators
/// can target a specific stuck job (or correlate with `ps` output by pid).
class ScoringInFlightJob {
  const ScoringInFlightJob({
    required this.packageName,
    required this.version,
    required this.pid,
  });

  final String packageName;
  final String version;
  final int pid;

  Map<String, dynamic> toJson() => {
    'packageName': packageName,
    'version': version,
    'pid': pid,
  };
}

/// Status snapshot of the scoring system for the admin API.
class ScoringSystemStatus {
  const ScoringSystemStatus({
    required this.enabled,
    this.dartSdkPath,
    this.flutterSdkPath,
    required this.workerCount,
    required this.queueDepth,
    required this.activeJobs,
    this.inFlightJobs = const [],
  });

  final bool enabled;
  final String? dartSdkPath;
  final String? flutterSdkPath;
  final int workerCount;
  final int queueDepth;
  final int activeJobs;
  final List<ScoringInFlightJob> inFlightJobs;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'status': !enabled
        ? 'disabled'
        : flutterSdkPath != null
        ? 'full'
        : 'dart-only',
    'dartSdkPath': dartSdkPath,
    'flutterSdkPath': flutterSdkPath,
    'workerCount': workerCount,
    'queueDepth': queueDepth,
    'activeJobs': activeJobs,
    'inFlightJobs': inFlightJobs.map((j) => j.toJson()).toList(),
  };
}

/// Manages background pana analysis via a pool of subprocess workers.
///
/// Subprocess-per-job, not an isolate pool: pana executes uploader-authored
/// code (build hooks, analyzer plugins) so we isolate it from the server
/// process entirely. Layer on [SandboxConfig] for additional OS-level
/// hardening — see sandbox.dart.
///
/// Concurrency is capped at [ScoringConfig.workerCount]; additional jobs
/// wait in an in-memory queue until a slot frees up. Pending rows are
/// persisted in the DB so a server restart resumes cleanly.
class ScoringService {
  ScoringService({
    required MetadataStore store,
    required BlobStore blobStore,
    required Future<ScoringConfig> Function() configProvider,
    required String tempDir,
    required String Function() generateId,
    required ScoringLogger logger,
    this.dartdocOutputDir,
    this.dartdocBackend = DartdocBackend.filesystem,
  }) : _store = store,
       _blobStore = blobStore,
       _configProvider = configProvider,
       _tempDir = tempDir,
       _generateId = generateId,
       _logger = logger;

  final MetadataStore _store;
  final BlobStore _blobStore;
  final Future<ScoringConfig> Function() _configProvider;
  final String _tempDir;
  final String Function() _generateId;
  final ScoringLogger _logger;

  /// Root directory for persisting dartdoc HTML output.
  /// When set, docs are written to `<dartdocOutputDir>/<package>/latest/`
  /// in filesystem mode, or used as a scratch area in blob mode.
  final String? dartdocOutputDir;

  /// Where dartdoc HTML is persisted and served from. In filesystem mode,
  /// the worker's output directory IS the serve directory. In blob mode,
  /// we treat it as scratch — the service packs the tree into an indexed
  /// blob and uploads to `BlobStore` under `<pkg>/dartdoc/latest/`.
  final DartdocBackend dartdocBackend;

  final _queue = Queue<_QueuedJob>();
  final _inFlight = <_QueuedJob, Process>{};

  /// Future for each in-flight `_runJob` so cancellation paths can wait
  /// for full cleanup (drains, persist, `_inFlight`/`_activeKeys`
  /// removal) instead of just sending SIGKILL and returning. Without
  /// this, force-rescan would re-enqueue while the killed run's
  /// finally was still pending and the killed run's later
  /// `_activeKeys.remove` would clobber the freshly-enqueued key —
  /// opening a duplicate-processing window.
  final _runJobFutures = <_QueuedJob, Future<void>>{};

  /// Tracks in-flight or queued (package, version) pairs to prevent
  /// duplicate scoring jobs.
  final _activeKeys = <String>{};

  bool _stopped = false;

  /// Wall-clock cap around the whole subprocess invocation. Must be
  /// slightly longer than the pana internal timeout so the child has room
  /// to serialize its failure result before we kill it.
  static const _subprocessTimeout = Duration(minutes: 55);

  /// Read the last [count] lines from the scoring log file.
  Future<List<String>> readLogLines([int count = 300]) =>
      _logger.readLastLines(count);

  /// Clear the scoring log file.
  Future<void> clearLogs() => _logger.clear();

  /// Tools required by pana for full scoring (especially screenshot processing).
  static const requiredTools = [
    'webpinfo',
    'cwebp',
    'dwebp',
    'gif2webp',
    'webpmux',
  ];

  /// Start the scoring system: reset stale jobs and re-queue pending ones.
  Future<void> start() async {
    await _killOrphanSubprocesses();
    await _store.resetStaleRunningScores();
    if (dartdocOutputDir != null) {
      await _store.resetStaleRunningDartdocs();
    }

    final config = await _configProvider();
    if (!config.enabled) {
      _logger.log('Scoring disabled (no SDK configured).');
      return;
    }

    await _checkRequiredTools();

    _logger.log(
      'Scoring enabled: dart=${config.dartSdkPath}, '
      'flutter=${config.flutterSdkPath}, sandbox=${config.sandbox.describe()}',
    );
    if (config.subprocessBinary == null) {
      _logger.log(
        'Scoring will use `dart run club_server:scoring_subprocess` '
        '(development mode — set SCORING_SUBPROCESS_BINARY in prod).',
      );
    } else {
      _logger.log('Scoring subprocess binary: ${config.subprocessBinary}');
    }

    // Kick off permission fixup for every scoring-relevant directory
    // in the background. Spawns await this future before exec'ing
    // (see `_spawnAndWait`), so jobs queued at startup wait for prep
    // to finish — but the rest of bootstrap (HTTP listener, etc.) is
    // not blocked. On warm restart the SDK probe makes prep near-zero.
    final prepStart = DateTime.now();
    unawaited(
      _ensureSandboxReady(config)
          .then(
            (_) => _logger.log(
              'Sandbox prep ready '
              '(took ${DateTime.now().difference(prepStart).inMilliseconds}ms)',
            ),
          )
          .catchError(
            (Object e, StackTrace st) =>
                _logger.log('Sandbox prep failed: $e\n$st'),
          ),
    );

    // Re-queue any pending jobs from a previous run.
    final pending = await _store.listPendingScores();
    for (final score in pending) {
      _logger.log('Re-queuing ${score.packageName} ${score.version}');
      final key = '${score.packageName}@${score.version}';
      _activeKeys.add(key);
      _queue.add(
        _QueuedJob(packageName: score.packageName, version: score.version),
      );
    }
    _dispatch();
  }

  /// Kill any `scoring_subprocess` processes whose parent is init/launchd
  /// (PID 1) — orphans left behind by a previous server that died
  /// ungracefully. Without this, a freshly-spawned subprocess for the
  /// same package would race the orphan over the pub cache, temp dirs,
  /// and (on Linux) the rlimit slot.
  ///
  /// Linux first uses `/proc` (works in distroless containers without
  /// `ps`), with a `ps` fallback. macOS uses `ps`. Skipped on Windows.
  /// Best-effort throughout — startup never wedges over a failed sweep.
  Future<void> _killOrphanSubprocesses() async {
    if (Platform.isWindows) return;

    final List<({int pid, String command})> orphans;
    if (Directory('/proc').existsSync()) {
      orphans = _scanOrphansViaProc();
    } else {
      orphans = await _scanOrphansViaPs();
    }

    var killed = 0;
    for (final orphan in orphans) {
      // Match both dev (`dart run club_server:scoring_subprocess …`)
      // and prod (`/app/scoring_subprocess/bin/scoring_subprocess …`).
      if (!orphan.command.contains('scoring_subprocess')) continue;
      _logger.log(
        'Orphan sweep: killing pid=${orphan.pid} (cmd=${orphan.command})',
      );
      // Use the tree-kill so any grandchildren the orphan itself spawned
      // (pana → dart pub get, dartdoc, …) go down with it.
      await _killProcessTree(orphan.pid);
      killed++;
    }
    if (killed > 0) {
      _logger.log('Orphan sweep: killed $killed orphan subprocess(es)');
    }
  }

  /// Walk `/proc` to find PPID==1 processes with their full cmdline.
  /// Linux-only path; called when `/proc` is mounted.
  List<({int pid, String command})> _scanOrphansViaProc() {
    final out = <({int pid, String command})>[];
    final procDir = Directory('/proc');
    if (!procDir.existsSync()) return out;
    final List<FileSystemEntity> entries;
    try {
      entries = procDir.listSync(followLinks: false);
    } catch (e) {
      _logger.log('Orphan sweep: /proc listing failed: $e (skipping)');
      return out;
    }
    for (final entry in entries) {
      if (entry is! Directory) continue;
      final pidStr = entry.path.split('/').last;
      final pid = int.tryParse(pidStr);
      if (pid == null) continue;
      final ppid = _readProcPpid(pid);
      if (ppid != 1) continue;
      final cmd = _readProcCmdline(pid);
      if (cmd == null || cmd.isEmpty) continue;
      out.add((pid: pid, command: cmd));
    }
    return out;
  }

  int? _readProcPpid(int pid) {
    try {
      final content = File('/proc/$pid/status').readAsStringSync();
      for (final line in content.split('\n')) {
        if (line.startsWith('PPid:')) {
          return int.tryParse(line.substring(5).trim());
        }
      }
    } catch (_) {}
    return null;
  }

  String? _readProcCmdline(int pid) {
    try {
      // /proc/<pid>/cmdline is NUL-separated; convert to spaces.
      final raw = File('/proc/$pid/cmdline').readAsStringSync();
      return raw.replaceAll(' ', ' ').trim();
    } catch (_) {
      return null;
    }
  }

  Future<List<({int pid, String command})>> _scanOrphansViaPs() async {
    final out = <({int pid, String command})>[];
    ProcessResult result;
    try {
      result = await Process.run(
        'ps',
        const ['-A', '-o', 'pid,ppid,user,command'],
      );
    } catch (e) {
      _logger.log('Orphan sweep: ps invocation failed: $e (skipping)');
      return out;
    }
    if (result.exitCode != 0) {
      _logger.log(
        'Orphan sweep: ps exited ${result.exitCode} (skipping)',
      );
      return out;
    }
    final me =
        Platform.environment['USER'] ?? Platform.environment['LOGNAME'] ?? '';
    final lines = (result.stdout as String).split('\n');
    for (final line in lines.skip(1)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) continue;
      final pid = int.tryParse(parts[0]);
      final ppid = int.tryParse(parts[1]);
      final user = parts[2];
      if (pid == null || ppid == null) continue;
      if (ppid != 1) continue;
      // Only this user's processes on shared dev boxes.
      if (me.isNotEmpty && user != me) continue;
      final command = parts.sublist(3).join(' ');
      out.add((pid: pid, command: command));
    }
    return out;
  }

  /// SIGKILL [rootPid] and every descendant. Without this, killing only
  /// the wrapper PID leaves pana's grandchildren (`dart pub get`,
  /// `dartdoc`, etc.) alive — they were forked into the same stdio pipe
  /// they inherited, and *those open writers* are why the parent's
  /// `stderrDrain` and `stdoutDrain` futures never resolve. The result:
  /// `_runJob` blocks forever in `_spawnAndWait`, the `_inFlight`
  /// finally never fires, and the dispatcher sees a "ghost" busy worker.
  ///
  /// Strategy: enumerate descendants top-down (BFS), then SIGKILL them
  /// leaves-first so each parent dies after its children. The whole
  /// walk is best-effort — if descendant lookup fails we still SIGKILL
  /// the root, which at least frees the wrapper PID slot.
  ///
  /// Linux: `/proc/<pid>/status` for PPid lookup (no external binary).
  /// macOS: `ps -A -o pid,ppid`. Windows: just kill the root pid.
  Future<void> _killProcessTree(int rootPid) async {
    if (Platform.isWindows) {
      try {
        Process.killPid(rootPid, ProcessSignal.sigkill);
      } catch (_) {}
      return;
    }

    // Build pid → children map once, then walk it BFS from root.
    final childrenByParent = await _buildPpidIndex();
    final descendants = <int>[];
    final stack = [rootPid];
    final visited = <int>{rootPid};
    while (stack.isNotEmpty) {
      final pid = stack.removeLast();
      final kids = childrenByParent[pid] ?? const <int>[];
      for (final kid in kids) {
        if (visited.add(kid)) {
          descendants.add(kid);
          stack.add(kid);
        }
      }
    }

    // Leaves first.
    for (final pid in descendants.reversed) {
      try {
        Process.killPid(pid, ProcessSignal.sigkill);
      } catch (_) {}
    }
    try {
      Process.killPid(rootPid, ProcessSignal.sigkill);
    } catch (_) {}
  }

  /// Snapshot of every visible PID's parent. Used by [_killProcessTree]
  /// to enumerate descendants in one pass instead of one syscall per
  /// candidate parent.
  Future<Map<int, List<int>>> _buildPpidIndex() async {
    final index = <int, List<int>>{};
    if (Directory('/proc').existsSync()) {
      try {
        for (final entry in Directory(
          '/proc',
        ).listSync(followLinks: false)) {
          if (entry is! Directory) continue;
          final pid = int.tryParse(entry.path.split('/').last);
          if (pid == null) continue;
          final ppid = _readProcPpid(pid);
          if (ppid == null) continue;
          (index[ppid] ??= []).add(pid);
        }
        return index;
      } catch (_) {
        // Fall through to ps fallback.
      }
    }
    try {
      final result = await Process.run(
        'ps',
        const ['-A', '-o', 'pid,ppid'],
      );
      if (result.exitCode == 0) {
        final lines = (result.stdout as String).split('\n');
        for (final line in lines.skip(1)) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length < 2) continue;
          final pid = int.tryParse(parts[0]);
          final ppid = int.tryParse(parts[1]);
          if (pid == null || ppid == null) continue;
          (index[ppid] ??= []).add(pid);
        }
      }
    } catch (_) {}
    return index;
  }

  /// Future that completes with the scoring HOME path once
  /// [_prepareSandboxDirs] has run. Kicked off in [start] (or lazily
  /// from `_spawnAndWait` if scoring was disabled at boot), so the
  /// HTTP listener and rest of bootstrap can proceed while chown/chmod
  /// is still running. Spawns await this before exec'ing — first job
  /// pays the prep cost, restarts after that are instant.
  ///
  /// We don't need an isolate here because the prep work is entirely
  /// I/O (external `chown`/`chmod` processes); the dart event loop
  /// stays free during the awaits.
  Future<String>? _sandboxPrepFuture;

  /// Idempotent accessor: returns the in-flight or already-completed
  /// prep future, kicking it off lazily if needed. Both the eager
  /// call in [start] and the spawn-time wait in `_spawnAndWait` go
  /// through this — the `??=` ensures only one prep ever runs.
  ///
  /// On failure we clear the cache so the next caller retries instead
  /// of replaying the same error forever. Without this, a transient
  /// problem (chown briefly racing a volume mount, etc.) would
  /// silently kill scoring until the next server restart: every
  /// subsequent `_spawnAndWait` would await the poisoned future, get
  /// the original error, and `_runJob` would record the job as failed.
  Future<String> _ensureSandboxReady(ScoringConfig config) {
    if (_sandboxPrepFuture != null) return _sandboxPrepFuture!;
    Future<String> attempt() async {
      try {
        return await _prepareSandboxDirs(config);
      } catch (_) {
        // Reset before rethrowing so the *next* caller starts fresh.
        // Awaiters of THIS future still get the error — that's correct;
        // they should know prep failed and propagate as a job failure.
        _sandboxPrepFuture = null;
        rethrow;
      }
    }

    return _sandboxPrepFuture = attempt();
  }

  /// Ensure every scoring-relevant directory has permissions the
  /// (potentially dropped-UID) sandbox subprocess can actually use,
  /// and return the HOME path to pass via `Process.start(environment:)`.
  ///
  /// Why this matters: the parent server runs as root in the container,
  /// but pana's subprocess (and every `dart` it spawns) is dropped to
  /// `sandbox.dropToUid` via setpriv. Without per-dir permission fixup
  /// any of these failures can stall a job mid-run:
  ///   - `Exists failed, path = '/root/.dartServer/.instrumentation'`
  ///     → HOME inherited from the parent (root). Fix: writable HOME.
  ///   - `dart pub get` failing on PUB_CACHE writes → fix: writable
  ///     pub-cache.
  ///   - dartdoc copy failing on persist target → fix: writable dartdoc
  ///     output dir.
  ///   - `Permission denied` opening a tarball or job JSON in tempDir
  ///     → fix: writable tempDir.
  ///   - `dart` itself unable to load the SDK because the install path
  ///     was extracted root-only → fix: chmod a+rX on SDK trees.
  ///
  /// Two passes:
  ///   1. **Writable** — chown -R to the sandbox UID/GID so the dropped
  ///      child owns these. Falls back to `chmod -R 0777` if chown
  ///      fails (e.g. parent isn't root, as on macOS dev). Re-running
  ///      chown on already-correctly-owned files is cheap (kernel
  ///      updates inode metadata in-place); not worth caching.
  ///   2. **Readable** — chmod -R a+rX on SDK trees so the child can
  ///      traverse and read them regardless of how they were installed.
  ///      `a+rX` is the right mode here: read for all, execute-only on
  ///      directories and on files that are already executable. The
  ///      one *expensive* operation (200k inodes on a Flutter SDK) is
  ///      gated by [_sdkAlreadyReadable] — a single stat call probes
  ///      the dart binary's mode bits and bypasses the recursive chmod
  ///      when the tree is already permissioned correctly.
  Future<String> _prepareSandboxDirs(ScoringConfig config) async {
    final homePath = '$_tempDir/scoring-home';

    await Directory(homePath).create(recursive: true);
    if (config.pubCacheDir != null) {
      await Directory(config.pubCacheDir!).create(recursive: true);
    }
    if (dartdocOutputDir != null) {
      await Directory(dartdocOutputDir!).create(recursive: true);
    }

    final uid = config.sandbox.dropToUid;
    final gid = config.sandbox.dropToGid;
    final dropping = Platform.isLinux && (uid != null || gid != null);

    if (dropping) {
      final ownerArg = '${uid ?? ""}:${gid ?? ""}';

      // Writable: dirs the child needs to create/modify files in.
      // tempDir is included so the parent's tarball / job-file writes
      // (which we do as root) remain readable to the dropped child.
      final writable = <String>{
        homePath,
        _tempDir,
        ?config.pubCacheDir,
        ?dartdocOutputDir,
      };
      for (final path in writable) {
        await _chownTreeOrChmod777(path, ownerArg);
      }

      // Readable: SDK trees the child needs to traverse + read but
      // never write. Critical when SDKs were extracted root-only and
      // the dropped child hits "permission denied" on the dart binary
      // or its bundled assets.
      final readable = <String>{
        ?config.dartSdkPath,
        ?config.flutterSdkPath,
      };
      for (final path in readable) {
        await _chmodReadableTree(path);
      }

      _logger.log(
        'Sandbox prep done (uid=$ownerArg): '
        'writable=[${writable.join(", ")}], '
        'readable=[${readable.join(", ")}]',
      );
    } else {
      _logger.log(
        'Sandbox prep done: HOME=$homePath (no UID drop; '
        'permission fixup skipped)',
      );
    }

    return homePath;
  }

  Future<void> _chownTreeOrChmod777(String path, String ownerArg) async {
    try {
      final chown = await Process.run('chown', ['-R', ownerArg, path]);
      if (chown.exitCode == 0) return;
      _logger.log(
        'Sandbox prep: chown $ownerArg on $path failed '
        '(stderr=${(chown.stderr as String).trim()}); '
        'falling back to chmod 0777',
      );
    } catch (e) {
      _logger.log('Sandbox prep: chown failed on $path: $e; trying chmod');
    }
    try {
      await Process.run('chmod', ['-R', '0777', path]);
    } catch (e) {
      _logger.log(
        'Sandbox prep: chmod 0777 also failed on $path: $e — '
        'jobs writing here will likely fail with EACCES',
      );
    }
  }

  Future<void> _chmodReadableTree(String path) async {
    // Fast path: probe a known binary in the SDK. If it's already world
    // r+x the tree was almost certainly extracted with sensible perms
    // and a recursive chmod on a 1.5 GB Flutter SDK is wasted work
    // (10-30s of inode rewrites every container start).
    if (await _sdkAlreadyReadable(path)) {
      _logger.log(
        'Sandbox prep: $path already world-rx (probe hit); skipping chmod',
      );
      return;
    }
    try {
      final chmod = await Process.run('chmod', ['-R', 'a+rX', path]);
      if (chmod.exitCode != 0) {
        _logger.log(
          'Sandbox prep: chmod a+rX on $path failed '
          '(stderr=${(chmod.stderr as String).trim()})',
        );
      }
    } catch (e) {
      _logger.log('Sandbox prep: chmod a+rX failed on $path: $e');
    }
  }

  /// Heuristic readability check: the SDK is fine if a known binary
  /// inside it has world read+execute. Pure FileStat — no fork, no
  /// recursion, runs in microseconds. If no probe matches we return
  /// false and fall back to the recursive chmod.
  Future<bool> _sdkAlreadyReadable(String sdkPath) async {
    const probes = <String>[
      'bin/dart', // Dart SDK root
      'bin/flutter', // Flutter SDK root
      'bin/cache/dart-sdk/bin/dart', // dart-sdk inside Flutter
    ];
    for (final probe in probes) {
      final stat = await FileStat.stat('$sdkPath/$probe');
      if (stat.type == FileSystemEntityType.notFound) continue;
      // Mask to the bottom 9 mode bits; check world-read (0o4) +
      // world-exec (0o1) — a+rx for "other".
      final worldRX = (stat.mode & 0x005) == 0x005;
      return worldRX;
    }
    return false;
  }

  /// Stop the service and kill any in-flight subprocesses (and their
  /// grandchildren) so a server shutdown doesn't leak orphan processes
  /// to init/launchd.
  Future<void> stop() async {
    _stopped = true;
    for (final process in _inFlight.values) {
      try {
        await _killProcessTree(process.pid);
      } catch (_) {}
    }
    _inFlight.clear();
  }

  /// True when a (package, version) is already represented somewhere
  /// in our state — queued, in-flight, or sitting in `_activeKeys`
  /// during the brief window between dispatch and `_runJob` actually
  /// starting. Used by [enqueue] for dedup.
  ///
  /// `_activeKeys` is the fast O(1) check, but it's not sufficient by
  /// itself: a finishing `_runJob` removes the key from `_activeKeys`
  /// in its persist path *before* the next `_dispatch` actually picks
  /// up the queued successor. Scanning `_queue` and `_inFlight` covers
  /// that race so a concurrent enqueue during a force-rescan can't
  /// kick off a duplicate scoring run for the same version.
  bool _isActiveOrQueued(String packageName, String version) {
    final key = '$packageName@$version';
    if (_activeKeys.contains(key)) return true;
    for (final q in _queue) {
      if (q.packageName == packageName && q.version == version) return true;
    }
    for (final q in _inFlight.keys) {
      if (q.packageName == packageName && q.version == version) return true;
    }
    return false;
  }

  /// Enqueue a scoring job for a package version.
  Future<void> enqueue(String packageName, String version) async {
    final config = await _configProvider();
    if (!config.enabled) return;

    final key = '$packageName@$version';
    if (_isActiveOrQueued(packageName, version)) {
      _logger.log('Skipping duplicate enqueue for $key');
      return;
    }

    _logger.log('Enqueuing $packageName $version');

    await _store.saveScore(
      PackageScoreCompanion(
        packageName: packageName,
        version: version,
        status: ScoreStatus.pending,
      ),
    );

    _activeKeys.add(key);
    _queue.add(_QueuedJob(packageName: packageName, version: version));
    _dispatch();
  }

  /// Enqueue all unscored package versions.
  /// Returns the number of packages enqueued.
  Future<int> enqueueUnscored() async {
    final config = await _configProvider();
    if (!config.enabled) return 0;

    final unscored = await _store.listUnscoredVersions();
    var count = 0;
    for (final entry in unscored) {
      final key = '${entry.packageName}@${entry.version}';
      if (_activeKeys.contains(key)) continue;
      await enqueue(entry.packageName, entry.version);
      count++;
    }
    _logger.log('Enqueued $count unscored package(s)');
    return count;
  }

  /// Enqueue every package version for a full rescan, replacing existing
  /// scores. When [latestOnly] is true, only the latest version per package
  /// is enqueued.
  ///
  /// Force semantics: rescan is the operator's "I want this re-processed
  /// now" lever, so any in-flight subprocess for a matching entry is
  /// SIGKILL'd, the queue + `_activeKeys` are cleared for matching
  /// entries, and every entry is re-enqueued from scratch. Without this,
  /// an entry already in the queue (e.g., re-queued at startup after the
  /// previous server crashed mid-job) would be silently deduped out and
  /// rescan would report 0 — leaving the operator with no way to break a
  /// stuck job loose besides the explicit Kill button.
  ///
  /// Race note: SIGKILL'ing a child causes its `_spawnAndWait` to resolve
  /// with a non-zero exit, which then runs `_persistFailure` (saves
  /// status=failed). Our re-enqueue below saves status=pending, and a
  /// later `_runJob` saves status=running. Final-write-wins, and `_runJob`
  /// is the last writer, so the DB converges to a consistent state. A
  /// brief, cosmetic `failed` audit-log entry may appear from the killed
  /// run — that's the paper trail of the cancellation, not a bug.
  Future<int> enqueueAll({required bool latestOnly}) async {
    final config = await _configProvider();
    if (!config.enabled) return 0;

    final entries = await _store.listVersionsForRescan(latestOnly: latestOnly);
    if (entries.isEmpty) {
      _logger.log('Rescan: no versions to enqueue (latestOnly=$latestOnly)');
      return 0;
    }

    final entryKeys = <String>{
      for (final e in entries) '${e.packageName}@${e.version}',
    };

    var killed = 0;
    final pendingCleanup = <Future<void>>[];
    for (final entry in _inFlight.entries.toList()) {
      final job = entry.key;
      final key = '${job.packageName}@${job.version}';
      if (!entryKeys.contains(key)) continue;
      _logger.log(
        'Rescan: killing in-flight ${job.packageName} ${job.version} '
        '(pid=${entry.value.pid})',
      );
      try {
        await _killProcessTree(entry.value.pid);
        killed++;
        final fut = _runJobFutures[job];
        if (fut != null) pendingCleanup.add(fut);
      } catch (e) {
        _logger.log(
          'Rescan: failed to kill ${job.packageName} ${job.version}: $e',
        );
      }
    }

    // Wait for the killed runs to fully unwind before mutating queue
    // state and re-enqueueing. Without this, the killed run's eventual
    // `_inFlight.remove` + `_activeKeys.remove` (in its post-spawn
    // persist path) would clobber the keys we set below — opening a
    // race where a concurrent enqueue during cleanup creates a
    // duplicate scoring run for the same version. 30s is generous
    // headroom over `_spawnAndWait`'s 5s drain timeout + persist.
    if (pendingCleanup.isNotEmpty) {
      try {
        await Future.wait(pendingCleanup).timeout(
          const Duration(seconds: 30),
        );
      } catch (e) {
        _logger.log(
          'Rescan: cleanup wait did not complete in time: $e '
          '(continuing — duplicate-run risk is bounded by the dedup '
          'check in `enqueue`)',
        );
      }
    }

    final droppedFromQueue = _queue.length;
    _queue.removeWhere(
      (q) => entryKeys.contains('${q.packageName}@${q.version}'),
    );
    final queueDelta = droppedFromQueue - _queue.length;
    for (final key in entryKeys) {
      _activeKeys.remove(key);
    }

    var count = 0;
    for (final entry in entries) {
      await enqueue(entry.packageName, entry.version);
      count++;
    }
    _logger.log(
      'Rescan enqueued $count version(s) (latestOnly=$latestOnly, '
      'killed=$killed in-flight, dropped=$queueDelta from queue)',
    );
    return count;
  }

  /// Current system status for the admin API.
  ScoringSystemStatus get systemStatus => ScoringSystemStatus(
    enabled: _lastConfig?.enabled ?? false,
    dartSdkPath: _lastConfig?.dartSdkPath,
    flutterSdkPath: _lastConfig?.flutterSdkPath,
    workerCount: _lastConfig?.workerCount ?? 1,
    queueDepth: _queue.length,
    activeJobs: _inFlight.length,
    inFlightJobs: [
      for (final entry in _inFlight.entries)
        ScoringInFlightJob(
          packageName: entry.key.packageName,
          version: entry.key.version,
          pid: entry.value.pid,
        ),
    ],
  );

  /// Operator-triggered cancellation. SIGKILLs the in-flight subprocess(es)
  /// matching the filter; the existing wait-and-persist flow records the
  /// kill as a failure (`Subprocess exited with code -9 …`) and the
  /// dispatcher picks up the next queued job. Returns the number of
  /// processes signalled.
  ///
  /// Why SIGKILL and not SIGTERM: the typical caller is hitting this
  /// because a job is stuck — pana, dart pub get, or dartdoc are not
  /// signal-aware enough for SIGTERM to do anything useful, and the
  /// failure path doesn't need a graceful flush from the child (the
  /// parent records the cancellation log line itself).
  ///
  /// Pass [packageName]/[version] to target one job; both null cancels
  /// every in-flight job. Pass [packageName] alone to cancel all
  /// versions of a package (only one usually runs, but be explicit).
  Future<int> cancelInFlight({String? packageName, String? version}) async {
    var cancelled = 0;
    // Snapshot first so concurrent _inFlight mutations from finishing
    // jobs don't ConcurrentModification us.
    final targets = _inFlight.entries.where((e) {
      if (packageName != null && e.key.packageName != packageName) return false;
      if (version != null && e.key.version != version) return false;
      return true;
    }).toList();

    final pendingCleanup = <Future<void>>[];
    for (final entry in targets) {
      final job = entry.key;
      final process = entry.value;
      _logger.log(
        'Operator cancellation: killing tree rooted at '
        '${job.packageName} ${job.version} (pid=${process.pid})',
      );
      try {
        await _killProcessTree(process.pid);
        cancelled++;
        final fut = _runJobFutures[job];
        if (fut != null) pendingCleanup.add(fut);
      } catch (e) {
        _logger.log(
          'Failed to kill ${job.packageName} ${job.version} '
          '(pid=${process.pid}): $e',
        );
      }
    }

    // Wait for the killed runs' `_runJob` chains to fully unwind
    // (drains, persist, _inFlight + _activeKeys cleanup) before
    // returning. Without this the API responds to the operator while
    // state is mid-cleanup, and the immediate UI refresh sees a
    // ghost active count. Bound the wait so a missed grandchild
    // (drain timeout fires anyway at 5s + persist) can't pin the
    // request handler — 30s is comfortable headroom over the drain.
    if (pendingCleanup.isNotEmpty) {
      try {
        await Future.wait(pendingCleanup).timeout(
          const Duration(seconds: 30),
        );
      } catch (e) {
        _logger.log(
          'Cancellation cleanup wait did not complete in time: $e '
          '(state will catch up via the next dispatch)',
        );
      }
    }
    return cancelled;
  }

  /// Cache of the last resolved config for synchronous access.
  ScoringConfig? _lastConfig;

  /// Verify that external tools required by pana are on PATH.
  /// Logs warnings for each missing tool and exits the process if any are
  /// absent — scoring would produce incorrect results without them.
  Future<void> _checkRequiredTools() async {
    final missing = <String>[];
    for (final tool in requiredTools) {
      try {
        final result = await Process.run('which', [tool]);
        if (result.exitCode != 0) missing.add(tool);
      } catch (_) {
        missing.add(tool);
      }
    }
    if (missing.isNotEmpty) {
      _logger.log(
        'ERROR: Missing tools required by pana: ${missing.join(', ')}',
      );
      stderr.writeln('');
      stderr.writeln(
        '  Scoring cannot start: the following tools required by pana are missing:',
      );
      for (final tool in missing) {
        stderr.writeln('    - $tool');
      }
      stderr.writeln('');
      stderr.writeln(
        '  Install them (e.g. apt-get install webp) or disable scoring.',
      );
      stderr.writeln('');
      exit(1);
    }
  }

  // ── Internal ──────────────────────────────────────────────

  /// Fire off as many queued jobs as the concurrency cap allows.
  void _dispatch() {
    if (_stopped) return;
    while (_queue.isNotEmpty &&
        _inFlight.length < (_lastConfig?.workerCount ?? 1)) {
      final job = _queue.removeFirst();
      final future = _runJob(job);
      _runJobFutures[job] = future;
      // whenComplete drops our entry whether the job succeeded or not.
      future.whenComplete(() => _runJobFutures.remove(job));
      unawaited(future);
    }
  }

  Future<void> _runJob(_QueuedJob queued) async {
    // Resolve current config for SDK paths + sandbox settings.
    final config = await _configProvider();
    _lastConfig = config;

    if (!config.enabled || config.dartSdkPath == null) {
      _logger.log(
        'Scoring disabled mid-flight, failing job '
        '${queued.packageName} ${queued.version}',
      );
      try {
        await _persistFailure(
          queued.packageName,
          queued.version,
          'Scoring was disabled.',
        );
      } catch (e, st) {
        _logger.log(
          'Persist failure (mid-flight disable) for '
          '${queued.packageName} ${queued.version}: $e\n$st',
        );
      } finally {
        _activeKeys.remove('${queued.packageName}@${queued.version}');
        _dispatch();
      }
      return;
    }

    _logger.log('Starting analysis: ${queued.packageName} ${queued.version}');

    await _store.saveScore(
      PackageScoreCompanion(
        packageName: queued.packageName,
        version: queued.version,
        status: ScoreStatus.running,
      ),
    );

    String? tarballPath;
    try {
      tarballPath = await _prepareTarball(queued.packageName, queued.version);
    } catch (e) {
      _logger.log(
        'Failed to prepare tarball for '
        '${queued.packageName} ${queued.version}: $e',
      );
      try {
        await _persistFailure(
          queued.packageName,
          queued.version,
          'Failed to prepare tarball: $e',
        );
      } catch (persistErr, st) {
        _logger.log(
          'Persist failure (tarball prep) for '
          '${queued.packageName} ${queued.version}: $persistErr\n$st',
        );
      } finally {
        _activeKeys.remove('${queued.packageName}@${queued.version}');
        _dispatch();
      }
      return;
    }

    // ── Dartdoc gate: latest version only ─────────────────────────
    // We only persist dartdoc for whatever version is the current
    // latest at scoring-start time. Older re-scores skip dartdoc
    // entirely to avoid overwriting newer docs with older content.
    // A second check at write time guards the race where latest
    // flips between start and finish.
    final latestVersion = (await _store.lookupPackage(
      queued.packageName,
    ))?.latestVersion;
    final isLatestAtStart =
        latestVersion != null && latestVersion == queued.version;

    // Path we pass to the worker subprocess as its `dartdocOutputDir`.
    // Filesystem mode: persist location, served directly by shelf_static.
    // Blob mode: scratch dir under `_tempDir`; the service bundles into
    //            an indexed blob and uploads post-subprocess.
    String? dartdocPersistDir;
    final uploadDartdocToBlob =
        dartdocOutputDir != null &&
        isLatestAtStart &&
        dartdocBackend == DartdocBackend.blob;
    if (dartdocOutputDir != null && isLatestAtStart) {
      dartdocPersistDir = dartdocBackend == DartdocBackend.blob
          ? p.join(_tempDir, 'dartdoc-staging-${_generateId()}')
          : '$dartdocOutputDir/${queued.packageName}/latest';
    }

    if (dartdocPersistDir != null) {
      await _store.saveDartdoc(
        DartdocRecordCompanion(
          packageName: queued.packageName,
          version: queued.version,
          status: DartdocStatus.running,
        ),
      );
    }

    final job = ScoringJob(
      packageName: queued.packageName,
      version: queued.version,
      tarballPath: tarballPath,
      dartSdkPath: config.dartSdkPath!,
      flutterSdkPath: config.flutterSdkPath,
      pubCacheDir: config.pubCacheDir,
      tempBaseDir: _tempDir,
      licenseDataDir: config.licenseDataDir,
      dartdocOutputDir: dartdocPersistDir,
    );

    ScoringResult result;
    try {
      result = await _spawnAndWait(job, config, queued);
    } catch (e, st) {
      _logger.log(
        'Subprocess spawn failed for ${queued.packageName} '
        '${queued.version}: $e\n$st',
      );
      result = ScoringResult(
        packageName: queued.packageName,
        version: queued.version,
        success: false,
        errorMessage: 'Subprocess spawn failed: $e',
      );
    } finally {
      _inFlight.remove(queued);
      // Always clean up the parent's tarball copy — the child reads it by
      // path but doesn't own it.
      try {
        await File(tarballPath).delete();
      } catch (_) {}
    }

    // ── Blob-mode dartdoc upload ──────────────────────────────────
    // In blob mode, the subprocess has written the dartdoc tree to a
    // scratch directory. Pack it into an indexed blob and push to the
    // BlobStore under `<pkg>/dartdoc/latest/{index.json, blob}`. If
    // anything here fails, flip `dartdocSuccess` to false so the rest
    // of the persist logic records a failure rather than claiming
    // success with no durable output.
    if (uploadDartdocToBlob &&
        result.dartdocSuccess &&
        dartdocPersistDir != null) {
      // Race guard: if a newer version landed while we were scoring,
      // the docs we just generated are for the previous latest. Skip
      // the upload so that version's docs don't overwrite the ones
      // the newer scoring run will eventually produce.
      final currentLatest = (await _store.lookupPackage(
        queued.packageName,
      ))?.latestVersion;
      if (currentLatest != queued.version) {
        _logger.log(
          'Abandoning dartdoc upload for ${queued.packageName} '
          '${queued.version}: latest changed to '
          '${currentLatest ?? "<none>"} mid-run.',
        );
        result = _withDartdocSuccess(result, false);
      } else {
        try {
          await _uploadDartdocToBlob(
            queued.packageName,
            dartdocPersistDir,
          );
        } catch (e, st) {
          _logger.log(
            'Dartdoc blob upload failed for ${queued.packageName} '
            '${queued.version}: $e\n$st',
          );
          result = _withDartdocSuccess(result, false);
        }
      }
    }
    // Always clean up the scratch dir used for blob-mode staging.
    // Filesystem-mode paths live under `<dartdocOutputDir>/…` and
    // are not under `_tempDir`, so this doesn't touch them.
    if (uploadDartdocToBlob && dartdocPersistDir != null) {
      try {
        final scratch = Directory(dartdocPersistDir);
        if (await scratch.exists()) {
          await scratch.delete(recursive: true);
        }
      } catch (_) {}
    }

    // finally guarantees _activeKeys + dispatch fire even if the DB
    // write throws — without it, a transient DB error would leak the
    // key, and every future enqueue for this version would dedup-fail
    // and silently skip until server restart.
    try {
      await _persistResult(result);
    } catch (e, st) {
      _logger.log(
        'Persist result failed for '
        '${result.packageName} ${result.version}: $e\n$st',
      );
    } finally {
      _activeKeys.remove('${result.packageName}@${result.version}');
      _dispatch();
    }
  }

  /// Package the dartdoc HTML tree at [scratchDir] into an indexed blob
  /// and upload both pieces (`index.json` + `blob`) to the BlobStore
  /// under `<pkg>/dartdoc/latest/`. Each file is gzip-encoded inside the
  /// blob so range reads can be served with `Content-Encoding: gzip`
  /// directly to clients that accept it.
  Future<void> _uploadDartdocToBlob(
    String packageName,
    String scratchDir,
  ) async {
    // blobId doubles as a cache-busting identifier: when the docs are
    // regenerated the new index has a new blobId, so per-range cache
    // entries keyed on `dartdoc:range:<blobId>:<path>` don't collide
    // with stale bytes from the previous generation.
    final blobId = '$packageName:latest:'
        '${DateTime.now().toUtc().millisecondsSinceEpoch}';
    final pair = await BlobIndexPair.folderToIndexedBlob(
      blobId,
      scratchDir,
    );

    await _blobStore.putAsset(
      packageName,
      'dartdoc/latest/blob',
      Stream.value(pair.blob),
    );
    await _blobStore.putAsset(
      packageName,
      'dartdoc/latest/index.json',
      Stream.value(pair.index.asBytes()),
    );
    _logger.log(
      'Dartdoc blob uploaded for $packageName (blobId=$blobId, '
      '${pair.blob.length} bytes, ${pair.index.asBytes().length} B index).',
    );
  }

  /// Returns a copy of [result] with `dartdocSuccess` flipped to
  /// [newValue]. `ScoringResult` isn't mutable; reconstructing is the
  /// cheapest way to override the one field without adding a setter.
  static ScoringResult _withDartdocSuccess(
    ScoringResult result,
    bool newValue,
  ) {
    return ScoringResult(
      packageName: result.packageName,
      version: result.version,
      success: result.success,
      grantedPoints: result.grantedPoints,
      maxPoints: result.maxPoints,
      reportJson: result.reportJson,
      panaTags: result.panaTags,
      panaVersion: result.panaVersion,
      dartVersion: result.dartVersion,
      flutterVersion: result.flutterVersion,
      dartdocSuccess: newValue,
      errorMessage: result.errorMessage,
    );
  }

  /// Spawn the scoring subprocess and wait for it to write a
  /// [ScoringResult] JSON to the result path. The child reads the job
  /// from [jobFile] and writes to [resultFile] — we don't use stdin/stdout
  /// because pana's transitive `dart pub get` invocation prints build-hook
  /// status to stdout. Stderr streams to the scoring log. Kills the
  /// process on [_subprocessTimeout].
  Future<ScoringResult> _spawnAndWait(
    ScoringJob job,
    ScoringConfig config,
    _QueuedJob tracker,
  ) async {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final jobFile = File(
      '$_tempDir/scoring-${job.packageName}-${job.version}-$ts.job.json',
    );
    final resultFile = File(
      '$_tempDir/scoring-${job.packageName}-${job.version}-$ts.result.json',
    );
    await jobFile.writeAsString(jsonEncode(job.toJson()));

    // Wait for sandbox prep to finish before exec'ing. Started in
    // `start()` as a background future; near-instant on warm restart.
    // First call after a runtime enable kicks it off lazily.
    final scoringHome = await _ensureSandboxReady(config);

    final innerCmd = [
      ..._resolveCommand(config),
      jobFile.path,
      resultFile.path,
    ];
    _logger.log(
      'Spawning: ${innerCmd.join(" ")} '
      '(for ${job.packageName} ${job.version})',
    );

    final process = await Process.start(
      innerCmd.first,
      innerCmd.sublist(1),
      mode: ProcessStartMode.normal,
      // Override HOME so dart subprocesses (analyzer server, pub) write
      // their `.dartServer/` and `.pub-cache/credentials.json` to a
      // dir the dropped-UID child can actually write to. Without this,
      // pana's static-analysis and platform-support checks score 0/N
      // with `Exists failed, path = '/root/.dartServer/...'` errors.
      // The parent's env is merged in by default, so PATH and friends
      // still flow through.
      environment: {'HOME': scoringHome},
    );
    _inFlight[tracker] = process;
    _logger.log(
      'Subprocess started (pid=${process.pid}) for '
      '${job.packageName} ${job.version}',
    );

    var timedOut = false;
    var processExited = false;
    try {
      // Stream stderr into the main scoring log, line by line.
      final stderrDrain = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_logger.log);

      // Drain stdout into /dev/null — pana prints build-hook chatter here
      // that we don't want in the scoring log. All structured output comes
      // via the result file.
      final stdoutDrain = process.stdout.drain<void>();

      final killTimer = Timer(_subprocessTimeout, () {
        timedOut = true;
        _logger.log(
          'Subprocess timed out after ${_subprocessTimeout.inMinutes}m '
          'for ${job.packageName} ${job.version} (pid=${process.pid}); '
          'killing process tree',
        );
        // Async kill — Timer callback can't be Future<void>, so dispatch
        // and forget. The next `await` cycle picks up the process exit.
        unawaited(_killProcessTree(process.pid));
      });

      final exitCode = await process.exitCode;
      processExited = true;
      killTimer.cancel();
      // Drains can hang if the kill didn't take down a grandchild that
      // inherited our stdio pipe (e.g. dart pub get spawned by pana).
      // The tree-kill above and at the cancellation sites should catch
      // those, but treat the drain as best-effort with a short ceiling
      // so a single missed grandchild can't pin _runJob — and therefore
      // the dispatcher's worker slot — forever.
      await stderrDrain.asFuture<void>().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _logger.log(
            'Subprocess stderr drain timed out for ${job.packageName} '
            '${job.version} (pid=${process.pid}); a grandchild may still '
            'hold the pipe. Continuing.',
          );
          unawaited(stderrDrain.cancel());
        },
      );
      await stdoutDrain.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _logger.log(
            'Subprocess stdout drain timed out for ${job.packageName} '
            '${job.version} (pid=${process.pid}); continuing.',
          );
        },
      );

      if (exitCode != 0) {
        final reason = timedOut
            ? 'killed after ${_subprocessTimeout.inMinutes}m timeout'
            : 'exited with code $exitCode';
        _logger.log(
          'Subprocess $reason for ${job.packageName} ${job.version}',
        );
        return ScoringResult(
          packageName: job.packageName,
          version: job.version,
          success: false,
          errorMessage: 'Subprocess $reason',
        );
      }

      if (!await resultFile.exists()) {
        _logger.log(
          'Subprocess exited 0 but did not write result file for '
          '${job.packageName} ${job.version} at ${resultFile.path}',
        );
        return ScoringResult(
          packageName: job.packageName,
          version: job.version,
          success: false,
          errorMessage:
              'Subprocess exited 0 but did not write result file at '
              '${resultFile.path}',
        );
      }

      try {
        final map =
            jsonDecode(await resultFile.readAsString()) as Map<String, dynamic>;
        return ScoringResult.fromJson(map);
      } catch (e) {
        _logger.log(
          'Result file for ${job.packageName} ${job.version} is not '
          'valid ScoringResult JSON: $e',
        );
        return ScoringResult(
          packageName: job.packageName,
          version: job.version,
          success: false,
          errorMessage: 'Result file not valid ScoringResult JSON: $e',
        );
      }
    } finally {
      // Only tree-kill if the wait block is unwinding *before* we saw
      // a clean exit (e.g. an uncaught exception aborted the wait).
      // Once `process.exitCode` has resolved the OS may recycle the
      // pid, so an unconditional `kill(pid)` here can SIGKILL an
      // unrelated process on a busy host. The drain timeouts above
      // ensure we always reach the post-exit code paths if the child
      // has exited, so this guard is safe.
      if (!processExited) {
        try {
          await _killProcessTree(process.pid);
        } catch (_) {}
      }
      // Best-effort cleanup; we don't want stale job/result files
      // accumulating in tempdir over time.
      for (final f in [jobFile, resultFile]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  /// Resolve the argv for spawning the scoring subprocess, including any
  /// active sandbox layers.
  List<String> _resolveCommand(ScoringConfig config) {
    final inner = config.subprocessBinary != null
        ? <String>[config.subprocessBinary!]
        : <String>[
            Platform.resolvedExecutable, // `dart` in JIT, server bin in AOT
            'run',
            'club_server:scoring_subprocess',
          ];
    return config.sandbox.wrap(inner);
  }

  /// Copy the tarball to a temp file so the worker has its own copy.
  Future<String> _prepareTarball(String packageName, String version) async {
    final stream = await _blobStore.get(packageName, version);
    final tempPath =
        '$_tempDir/scoring-$packageName-$version-${DateTime.now().microsecondsSinceEpoch}.tar.gz';
    final tempFile = File(tempPath);
    final sink = tempFile.openWrite();
    await stream.pipe(sink);
    return tempPath;
  }

  Future<void> _persistResult(ScoringResult result) async {
    if (result.success) {
      _logger.log(
        'Scored ${result.packageName} ${result.version}: '
        '${result.grantedPoints}/${result.maxPoints}',
      );
      await _store.saveScore(
        PackageScoreCompanion(
          packageName: result.packageName,
          version: result.version,
          status: ScoreStatus.completed,
          grantedPoints: result.grantedPoints,
          maxPoints: result.maxPoints,
          reportJson: result.reportJson,
          panaTags: result.panaTags,
          panaVersion: result.panaVersion,
          dartVersion: result.dartVersion,
          flutterVersion: result.flutterVersion,
          scoredAt: DateTime.now().toUtc(),
        ),
      );

      await _store.appendAuditLog(
        AuditLogCompanion(
          id: _generateId(),
          kind: AuditKind.versionScored,
          packageName: result.packageName,
          version: result.version,
          summary:
              'Scored ${result.packageName} ${result.version}: '
              '${result.grantedPoints}/${result.maxPoints} points.',
          dataJson: jsonEncode({
            'grantedPoints': result.grantedPoints,
            'maxPoints': result.maxPoints,
            'panaVersion': result.panaVersion,
          }),
        ),
      );

      if (dartdocOutputDir != null) {
        if (result.dartdocSuccess) {
          _logger.log(
            'Dartdoc generated for ${result.packageName} ${result.version}',
          );
          await _store.saveDartdoc(
            DartdocRecordCompanion(
              packageName: result.packageName,
              version: result.version,
              status: DartdocStatus.completed,
              generatedAt: DateTime.now().toUtc(),
            ),
          );
          await _store.appendAuditLog(
            AuditLogCompanion(
              id: _generateId(),
              kind: AuditKind.dartdocGenerated,
              packageName: result.packageName,
              version: result.version,
              summary:
                  'API docs generated for ${result.packageName} '
                  '${result.version}.',
            ),
          );
        } else {
          _logger.log(
            'Dartdoc generation failed for ${result.packageName} '
            '${result.version}',
          );
          await _store.saveDartdoc(
            DartdocRecordCompanion(
              packageName: result.packageName,
              version: result.version,
              status: DartdocStatus.failed,
              errorMessage: 'Dartdoc generation did not produce output.',
            ),
          );
          await _store.appendAuditLog(
            AuditLogCompanion(
              id: _generateId(),
              kind: AuditKind.dartdocFailed,
              packageName: result.packageName,
              version: result.version,
              summary:
                  'API docs generation failed for ${result.packageName} '
                  '${result.version}.',
            ),
          );
        }
      }
    } else {
      await _persistFailure(
        result.packageName,
        result.version,
        result.errorMessage ?? 'Unknown error',
      );
    }
  }

  Future<void> _persistFailure(
    String packageName,
    String version,
    String error,
  ) async {
    _logger.log('Scoring failed for $packageName $version: $error');
    await _store.saveScore(
      PackageScoreCompanion(
        packageName: packageName,
        version: version,
        status: ScoreStatus.failed,
        errorMessage: error,
      ),
    );

    await _store.appendAuditLog(
      AuditLogCompanion(
        id: _generateId(),
        kind: AuditKind.versionScoreFailed,
        packageName: packageName,
        version: version,
        summary: 'Scoring failed for $packageName $version.',
        dataJson: jsonEncode({'error': error}),
      ),
    );

    if (dartdocOutputDir != null) {
      await _store.saveDartdoc(
        DartdocRecordCompanion(
          packageName: packageName,
          version: version,
          status: DartdocStatus.failed,
          errorMessage: 'Scoring failed: $error',
        ),
      );
      await _store.appendAuditLog(
        AuditLogCompanion(
          id: _generateId(),
          kind: AuditKind.dartdocFailed,
          packageName: packageName,
          version: version,
          summary: 'API docs generation failed for $packageName $version.',
          dataJson: jsonEncode({'error': error}),
        ),
      );
    }
  }
}

class _QueuedJob {
  const _QueuedJob({required this.packageName, required this.version});
  final String packageName;
  final String version;
}
