import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pana/pana.dart';

import '../dartdoc/sanitizer.dart';
import '../dartdoc/themer.dart';

// Trust model note: pana executes uploader code (build scripts, analyzer
// plugins, `dart pub get` hooks). We execute pana in a **separate OS
// subprocess**, not a Dart isolate, so an RCE inside pana can't reach the
// server's DB, blob store, secrets, or the API socket. Parent talks to the
// child over stdin/stdout only (job JSON in, result JSON out, logs on
// stderr).
//
// Subprocess isolation gives us fresh Dart VM state per job but still
// trusts the host OS — the child runs as the same UNIX user as the parent
// unless [SandboxConfig] drops UID or wraps with a kernel sandbox. For a
// typical private registry (trusted uploaders) that's enough. For open
// signup / multi-tenant, configure [SandboxConfig.commandPrefix] to layer
// bwrap / firejail / gVisor on top — see sandbox.dart.

/// Overall time budget for one pana analysis (unpack + pub resolve + lints +
/// dartdoc). Mirrors pub.dev's pub_worker budget of 50 minutes. Without this
/// cap a pathological package can hold a worker slot indefinitely.
const _panaTimeout = Duration(minutes: 50);

/// Upper bound on the size of the pana report JSON we'll persist. Anything
/// larger is replaced with a placeholder so a single bloated report can't
/// balloon the scores table. pub.dev caps the *compressed* report at 32 KB;
/// this is the uncompressed equivalent at a ~6× ratio with headroom.
const _maxReportBytes = 256 * 1024;

/// How often the worker logs a "still working" heartbeat. Without it a
/// stuck job and a slow-but-healthy one look identical until the 50-minute
/// pana timeout fires. 2 min is rare enough not to spam fast runs (most
/// finish in <90s) and quick enough to localize a stall to its phase.
const _heartbeatInterval = Duration(minutes: 2);

String _formatElapsed(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '${m}m${s}s';
}

/// Thrown by [_BoundedByteSink] to abort [JsonUtf8Encoder] mid-walk when
/// the encoded output would exceed the size limit. The sink throws (rather
/// than silently dropping) so the encoder stops traversing the object tree
/// — the whole point is to avoid the runaway-encode hang.
class _ReportTooLarge implements Exception {}

/// Buffers UTF-8 chunks from [JsonUtf8Encoder.startChunkedConversion] and
/// throws [_ReportTooLarge] once the running total would exceed [_max].
/// We size-check *before* appending so the buffered bytes never exceed
/// the limit.
class _BoundedByteSink extends ByteConversionSink {
  _BoundedByteSink(this._max, this._builder);
  final int _max;
  final BytesBuilder _builder;
  int _count = 0;

  @override
  void add(List<int> chunk) {
    if (_count + chunk.length > _max) throw _ReportTooLarge();
    _count += chunk.length;
    _builder.add(chunk);
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    final len = end - start;
    if (_count + len > _max) throw _ReportTooLarge();
    _count += len;
    if (start == 0 && end == chunk.length) {
      _builder.add(chunk);
    } else {
      _builder.add(chunk.sublist(start, end));
    }
  }

  @override
  void close() {
    // No-op: caller pulls bytes from the BytesBuilder directly. Throws
    // from `add`/`addSlice` propagate out of
    // `JsonUtf8Encoder.startChunkedConversion(sink).add(obj)` because
    // the encoder doesn't catch sink-side exceptions — verified against
    // dart:convert's `_JsonUtf8StringifierSink` which simply rethrows.
    // If a future SDK update wraps that path in a try/catch, we'd
    // silently fall back to the post-hoc length check below; not
    // catastrophic, just the original behavior we set out to fix.
  }
}

/// Encode [obj] as a JSON string, returning `null` if the encoded output
/// would exceed [maxBytes]. Uses the chunked encoder so we abort while the
/// encoder is still walking the object tree, instead of materializing the
/// whole string first and *then* checking length — the latter is exactly
/// what hangs on a pathological pana report.
String? _boundedJsonEncode(Object? obj, int maxBytes) {
  final builder = BytesBuilder(copy: false);
  final sink = _BoundedByteSink(maxBytes, builder);
  try {
    JsonUtf8Encoder().startChunkedConversion(sink).add(obj);
    return utf8.decode(builder.takeBytes());
  } on _ReportTooLarge {
    return null;
  }
}

/// Parent → child job description.
///
/// JSON-serializable: travels on the subprocess stdin stream, not through a
/// Dart port, so every field must round-trip via [jsonEncode]/[jsonDecode].
class ScoringJob {
  const ScoringJob({
    required this.packageName,
    required this.version,
    required this.tarballPath,
    required this.dartSdkPath,
    this.flutterSdkPath,
    this.pubCacheDir,
    required this.tempBaseDir,
    this.licenseDataDir,
    this.dartdocOutputDir,
  });

  final String packageName;
  final String version;
  final String tarballPath;
  final String dartSdkPath;
  final String? flutterSdkPath;
  final String? pubCacheDir;
  final String tempBaseDir;
  final String? licenseDataDir;

  /// When set, the worker copies the generated dartdoc HTML to this
  /// persistent directory after pana completes successfully.
  final String? dartdocOutputDir;

  Map<String, dynamic> toJson() => {
    'packageName': packageName,
    'version': version,
    'tarballPath': tarballPath,
    'dartSdkPath': dartSdkPath,
    'flutterSdkPath': flutterSdkPath,
    'pubCacheDir': pubCacheDir,
    'tempBaseDir': tempBaseDir,
    'licenseDataDir': licenseDataDir,
    'dartdocOutputDir': dartdocOutputDir,
  };

  factory ScoringJob.fromJson(Map<String, dynamic> json) => ScoringJob(
    packageName: json['packageName'] as String,
    version: json['version'] as String,
    tarballPath: json['tarballPath'] as String,
    dartSdkPath: json['dartSdkPath'] as String,
    flutterSdkPath: json['flutterSdkPath'] as String?,
    pubCacheDir: json['pubCacheDir'] as String?,
    tempBaseDir: json['tempBaseDir'] as String,
    licenseDataDir: json['licenseDataDir'] as String?,
    dartdocOutputDir: json['dartdocOutputDir'] as String?,
  );
}

/// Child → parent result.
///
/// JSON-serializable (see [ScoringJob]).
class ScoringResult {
  const ScoringResult({
    required this.packageName,
    required this.version,
    required this.success,
    this.grantedPoints,
    this.maxPoints,
    this.reportJson,
    this.panaVersion,
    this.dartVersion,
    this.flutterVersion,
    this.errorMessage,
    this.dartdocSuccess = false,
  });

  final String packageName;
  final String version;
  final bool success;
  final int? grantedPoints;
  final int? maxPoints;
  final String? reportJson;
  final String? panaVersion;
  final String? dartVersion;
  final String? flutterVersion;
  final String? errorMessage;

  /// Whether dartdoc HTML was successfully persisted to the output directory.
  final bool dartdocSuccess;

  Map<String, dynamic> toJson() => {
    'packageName': packageName,
    'version': version,
    'success': success,
    'grantedPoints': grantedPoints,
    'maxPoints': maxPoints,
    'reportJson': reportJson,
    'panaVersion': panaVersion,
    'dartVersion': dartVersion,
    'flutterVersion': flutterVersion,
    'errorMessage': errorMessage,
    'dartdocSuccess': dartdocSuccess,
  };

  factory ScoringResult.fromJson(Map<String, dynamic> json) => ScoringResult(
    packageName: json['packageName'] as String,
    version: json['version'] as String,
    success: json['success'] as bool,
    grantedPoints: json['grantedPoints'] as int?,
    maxPoints: json['maxPoints'] as int?,
    reportJson: json['reportJson'] as String?,
    panaVersion: json['panaVersion'] as String?,
    dartVersion: json['dartVersion'] as String?,
    flutterVersion: json['flutterVersion'] as String?,
    errorMessage: json['errorMessage'] as String?,
    dartdocSuccess: (json['dartdocSuccess'] as bool?) ?? false,
  );
}

/// Run a single pana analysis. Pure: no Dart ports, no globals — takes a
/// [log] callback so the caller decides where log lines go (stderr in the
/// subprocess entry, the ScoringLogger from unit tests).
///
/// Returns a [ScoringResult] describing success or failure; uncaught errors
/// are trapped and surfaced in [ScoringResult.errorMessage] rather than
/// thrown, so the caller never has to wrap this in try/catch.
Future<ScoringResult> runAnalysis(
  ScoringJob job, {
  required void Function(String) log,
}) async {
  final ts = DateTime.now().microsecondsSinceEpoch;
  final extractDir = Directory(
    '${job.tempBaseDir}/scoring-${job.packageName}-${job.version}-$ts',
  );
  final dartdocDir = Directory(
    '${job.tempBaseDir}/dartdoc-${job.packageName}-${job.version}-$ts',
  );

  // Phase tracking + heartbeat. The closure captures `phase` by reference
  // so each tick logs whatever stage we're in *right now*. Cancel it in
  // the finally so a thrown exception or early return can't leak a timer.
  var phase = 'starting';
  final stopwatch = Stopwatch()..start();
  final heartbeat = Timer.periodic(_heartbeatInterval, (_) {
    log(
      'Heartbeat for ${job.packageName} ${job.version}: '
      'phase=$phase, elapsed=${_formatElapsed(stopwatch.elapsed)}',
    );
  });

  try {
    phase = 'extract';
    log('Extracting tarball for ${job.packageName} ${job.version}');
    await extractDir.create(recursive: true);
    final tarballBytes = await File(job.tarballPath).readAsBytes();
    final archive = GZipDecoder().decodeBytes(tarballBytes);
    final tarArchive = TarDecoder().decodeBytes(archive);

    for (final file in tarArchive) {
      if (!file.isFile) continue;
      final filePath = file.name;
      if (filePath.isEmpty) continue;

      final outFile = File('${extractDir.path}/$filePath');
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(file.content as List<int>);
    }

    if (job.pubCacheDir != null) {
      await Directory(job.pubCacheDir!).create(recursive: true);
    }

    phase = 'tool-env';
    log(
      'Creating tool environment (dart=${job.dartSdkPath}, '
      'flutter=${job.flutterSdkPath ?? "none"})',
    );
    final toolEnv = await ToolEnvironment.create(
      dartSdkConfig: SdkConfig(rootPath: job.dartSdkPath),
      flutterSdkConfig: job.flutterSdkPath != null
          ? SdkConfig(rootPath: job.flutterSdkPath!)
          : null,
      pubCacheDir: job.pubCacheDir,
    );

    await dartdocDir.create(recursive: true);

    phase = 'pana';
    log('Running pana analysis for ${job.packageName} ${job.version}...');
    final analyzer = PackageAnalyzer(toolEnv);
    final options = InspectOptions(
      licenseDataDir: job.licenseDataDir,
      dartdocOutputDir: dartdocDir.path,
      dartdocTimeout: const Duration(minutes: 10),
    );
    // Outer budget across pana's full pipeline. The dartdocTimeout above
    // only bounds the documentation phase; this bounds the whole run so a
    // hung pub-get or lint pass can't pin a worker slot forever.
    final summary = await analyzer
        .inspectDir(extractDir.path, options: options)
        .timeout(_panaTimeout);

    final report = summary.report;
    final granted = report?.grantedPoints ?? 0;
    final max = report?.maxPoints ?? 0;
    final runtimeInfo = summary.runtimeInfo;

    log(
      'Analysis complete: ${job.packageName} ${job.version} — '
      '$granted/$max points',
    );

    var dartdocSuccess = false;
    if (job.dartdocOutputDir != null &&
        await File('${dartdocDir.path}/index.html').exists()) {
      try {
        // Strip inline `<script>` bodies, `on*` handlers, and javascript:
        // URLs from every HTML/SVG file before persisting. Sanitizing the
        // scratch tree (rather than the persisted copy) means both
        // filesystem and blob modes benefit from the same pass — the
        // later copy-or-indexed-blob-pack step just moves already-clean
        // bytes. See dartdoc/sanitizer.dart for the threat model.
        phase = 'sanitize-dartdoc';
        final sanitizeStats = await sanitizeDartdocTree(
          dartdocDir,
          log: log,
        );
        log(
          'Sanitized dartdoc tree for ${job.packageName} ${job.version}: '
          '$sanitizeStats',
        );

        // Apply club's visual theme on top of the sanitized output. We
        // run this *after* sanitize so the sanitizer's HTML round-trip
        // doesn't re-touch our injected nodes; everything we add is
        // already safe under the dartdoc CSP (external src=, no inline
        // JS, no on* handlers). See dartdoc/themer.dart for details.
        phase = 'theme-dartdoc';
        final themeStats = await applyClubTheme(dartdocDir, log: log);
        log(
          'Themed dartdoc tree for ${job.packageName} ${job.version}: '
          '$themeStats',
        );

        phase = 'persist-dartdoc';
        log('Persisting dartdoc output for ${job.packageName} ${job.version}');
        final persistDir = Directory(job.dartdocOutputDir!);
        final ts = DateTime.now().microsecondsSinceEpoch;
        final tempPersist = Directory('${job.dartdocOutputDir!}.tmp-$ts');
        await _copyDirectory(dartdocDir, tempPersist);
        if (await persistDir.exists()) {
          await persistDir.delete(recursive: true);
        }
        await tempPersist.rename(persistDir.path);
        dartdocSuccess = true;
        log('Dartdoc output persisted to ${job.dartdocOutputDir}');
      } catch (e) {
        log('Failed to persist dartdoc output: $e');
      }
    }

    // Bounded encoder: aborts mid-walk if the report would exceed the
    // size cap. The previous post-hoc length check ran *after* the full
    // encode and was the most likely culprit for silent stalls — a
    // pathological pana report could sit in jsonEncode for the entire
    // 50-min timeout window.
    phase = 'encode-result';
    String reportJson;
    final encoded = _boundedJsonEncode(summary.toJson(), _maxReportBytes);
    if (encoded != null) {
      reportJson = encoded;
    } else {
      log(
        'Report for ${job.packageName} ${job.version} exceeded '
        '$_maxReportBytes bytes; replacing with placeholder. '
        'Points/runtime info preserved.',
      );
      reportJson = jsonEncode({
        'dropped': true,
        'reason': 'report_too_large',
        'maxBytes': _maxReportBytes,
        'grantedPoints': granted,
        'maxPoints': max,
      });
    }

    return ScoringResult(
      packageName: job.packageName,
      version: job.version,
      success: true,
      grantedPoints: granted,
      maxPoints: max,
      reportJson: reportJson,
      panaVersion: runtimeInfo.panaVersion,
      dartVersion: runtimeInfo.sdkVersion,
      flutterVersion: runtimeInfo.flutterVersion,
      dartdocSuccess: dartdocSuccess,
    );
  } catch (e, st) {
    log(
      'Analysis failed for ${job.packageName} ${job.version} '
      '(phase=$phase, elapsed=${_formatElapsed(stopwatch.elapsed)}): $e\n$st',
    );
    return ScoringResult(
      packageName: job.packageName,
      version: job.version,
      success: false,
      errorMessage: '$e',
    );
  } finally {
    heartbeat.cancel();
    stopwatch.stop();
    for (final dir in [extractDir, dartdocDir]) {
      try {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }
}

Future<void> _copyDirectory(Directory src, Directory dst) async {
  await dst.create(recursive: true);
  await for (final entity in src.list(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(src.path.length);
    if (entity is File) {
      final target = File('${dst.path}$relative');
      await target.parent.create(recursive: true);
      await entity.copy(target.path);
    } else if (entity is Directory) {
      await Directory('${dst.path}$relative').create(recursive: true);
    }
  }
}
