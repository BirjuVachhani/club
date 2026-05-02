import 'dart:convert';
import 'dart:io';

import 'auth/dns_resolver.dart';

import 'package:archive/archive.dart';
import 'package:barbecue/barbecue.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:club_core/club_core.dart';
import 'package:club_db/club_db.dart';
import 'package:club_package_reader/club_package_reader.dart' as pkg_reader;
import 'package:club_storage/club_storage.dart';
import 'package:club_storage_firebase/club_storage_firebase.dart';
import 'package:club_storage_s3/club_storage_s3.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import 'api/setup_api.dart';
import 'config/app_config.dart';
import 'middleware/rate_limit.dart';
import 'router.dart';
import 'scheduler/scheduler.dart';
import 'scoring/sandbox.dart';
import 'scoring/scoring_logger.dart';
import 'scoring/scoring_service.dart';
import 'sdk/sdk_manager.dart';

final _bootstrapLogger = Logger('Bootstrap');

/// Result of bootstrapping the server.
class BootstrapResult {
  const BootstrapResult({
    required this.handler,
    required this.metadataStore,
    required this.blobStore,
    required this.searchIndex,
    required this.startedAt,
    required this.scheduler,
  });

  final Handler handler;
  final MetadataStore metadataStore;
  final BlobStore blobStore;
  final SearchIndex searchIndex;
  final DateTime startedAt;

  /// In-process cron scheduler. Caller is responsible for closing it on
  /// shutdown alongside the HTTP server.
  final Scheduler scheduler;
}

const _uuid = Uuid();

/// Bootstrap the server: create stores, services, and the HTTP handler.
Future<BootstrapResult> bootstrap(
  AppConfig config, {
  bool startServer = true,
  DateTime? startedAt,
}) async {
  // ── Resolve storage implementations ────────────────────────

  // Metadata store
  final MetadataStore metadataStore;
  late final ClubDatabase clubDb;
  switch (config.dbBackend) {
    case DbBackend.sqlite:
      clubDb = await ClubDatabase.open(path: config.sqlitePath);
      final sqliteStore = SqliteMetadataStore(clubDb);
      await sqliteStore.runMigrations();
      metadataStore = sqliteStore;
    case DbBackend.postgres:
      throw UnimplementedError('PostgreSQL backend not yet implemented.');
  }

  // Blob store
  final BlobStore blobStore;
  switch (config.blobBackend) {
    case BlobBackend.filesystem:
      blobStore = FilesystemBlobStore(rootPath: config.blobPath);
      await blobStore.open();
    case BlobBackend.s3:
      final s3 = config.s3;
      if (s3 == null) {
        throw StateError('S3 configuration required when BLOB_BACKEND=s3.');
      }
      blobStore = S3BlobStore(
        S3BlobStoreConfig(
          bucket: s3.bucket,
          region: s3.region,
          accessKey: s3.accessKey,
          secretKey: s3.secretKey,
          endpoint: s3.endpoint,
        ),
      );
      await blobStore.open();
    case BlobBackend.gcs:
      final gcs = config.gcs;
      if (gcs == null) {
        throw StateError('GCS configuration required when BLOB_BACKEND=gcs.');
      }
      blobStore = GcsBlobStore(
        GcsBlobStoreConfig(
          bucket: gcs.bucket,
          credentialsFile: gcs.credentialsFile,
          credentialsJson: gcs.credentialsJson,
        ),
      );
      await blobStore.open();
  }

  // Search index
  final SearchIndex searchIndex;
  switch (config.searchBackend) {
    case SearchBackend.sqlite:
      searchIndex = SqliteSearchIndex(clubDb);
      await searchIndex.open();
    case SearchBackend.meilisearch:
      throw UnimplementedError('Meilisearch backend not yet implemented.');
  }

  // ── Create temp directory ──────────────────────────────────
  await Directory(config.tempDir).create(recursive: true);

  // ── Create services ────────────────────────────────────────

  final authService = AuthService(
    store: metadataStore,
    hashPassword: (plain) async => BCrypt.hashpw(plain, BCrypt.gensalt()),
    verifyPassword: (plain, hash) async => BCrypt.checkpw(plain, hash),
    generateId: () => _uuid.v4(),
    // Raw hex only — AuthService prepends the kind prefix (e.g. club_sess_
    // for sessions, club_pat_ for PATs) so the server can tell credentials
    // apart at a glance without looking them up.
    generateTokenSecret: () => _generateHex(32),
  );

  // ── Settings store + SDK manager ───────────────────────────
  final settingsStore = SqliteSettingsStore(clubDb);

  final sdkManager = SdkManager(
    settingsStore: settingsStore,
    sdkBaseDir:
        Platform.environment['SDK_BASE_DIR'] ?? '/data/cache/sdks',
    generateId: () => _uuid.v4(),
  );
  await sdkManager.initialize();

  // ── Scoring service (pana analysis) ────────────────────────
  // Config is resolved dynamically — the admin can enable/disable scoring
  // and switch SDK versions at runtime without restarting the server.

  // In AOT mode (Docker), SPDX license data is copied next to the binary.
  // In JIT mode (dev), pana resolves it automatically via package URIs.
  final spdxDir = Directory(
    '${Platform.resolvedExecutable.contains('/bin/') ? File(Platform.resolvedExecutable).parent.parent.path : '.'}/spdx-licenses',
  );
  final licenseDataDir = spdxDir.existsSync() ? spdxDir.path : null;

  // Sandbox + subprocess-binary settings are resolved from env at boot —
  // they never change at runtime. Settings-store-backed knobs (enabled,
  // SDK paths) remain dynamic below.
  final sandbox = SandboxConfig.fromEnv(Platform.environment);
  final subprocessBinary = Platform.environment['SCORING_SUBPROCESS_BINARY']
      ?.trim();
  final scoringSubprocessBinary =
      subprocessBinary == null || subprocessBinary.isEmpty
      ? null
      : subprocessBinary;

  Future<ScoringConfig> configProvider() async {
    final enabled = await settingsStore.getScoringEnabled();
    if (!enabled) return const ScoringConfig.disabled();

    final dartPath = await sdkManager.getDefaultDartSdkPath();
    final flutterPath = await sdkManager.getDefaultFlutterSdkPath();
    if (dartPath == null) return const ScoringConfig.disabled();

    return ScoringConfig(
      enabled: true,
      dartSdkPath: dartPath,
      flutterSdkPath: flutterPath,
      pubCacheDir: '/data/cache/pub-cache',
      licenseDataDir: licenseDataDir,
      sandbox: sandbox,
      subprocessBinary: scoringSubprocessBinary,
    );
  }

  // Logs live at `<DATA_DIR>/logs/scoring.log`. The data-dir anchor is
  // inferred by walking up from the sqlite path — `sqlite_path` defaults
  // to `<DATA_DIR>/db/club.db`, so its grandparent is the data root. Any
  // operator who overrides SQLITE_PATH to a non-`db/` layout should also
  // set LOGS_DIR explicitly; we honour that here.
  final logsDir =
      Platform.environment['LOGS_DIR'] ??
      p.join(File(config.sqlitePath).parent.parent.path, 'logs');
  await Directory(logsDir).create(recursive: true);
  final scoringLogger = ScoringLogger(
    logFilePath: p.join(logsDir, 'scoring.log'),
  );
  await scoringLogger.open();

  // Ensure dartdoc output directory exists. In filesystem mode this
  // is where rendered HTML trees live; in blob mode the server never
  // writes here (scratch dirs live under `_tempDir` instead), but the
  // env-var default still points at a plausible spot so operators who
  // flip modes don't see surprising errors.
  await Directory(config.dartdocPath).create(recursive: true);

  final scoringService = ScoringService(
    store: metadataStore,
    blobStore: blobStore,
    configProvider: configProvider,
    tempDir: config.tempDir,
    generateId: () => _uuid.v4(),
    logger: scoringLogger,
    dartdocOutputDir: config.dartdocPath,
    dartdocBackend: config.dartdocBackend,
  );
  await scoringService.start();

  // Hosted-dep allowlist for the publish validator. Starts from the relaxed
  // club policy (which already includes pub.dev + pub.dartlang.org), then
  // adds this server's own public URL so packages on this club instance
  // can depend on each other via `hosted: url: <SERVER_URL>`. Without the
  // self-URL entry, any inter-club dependency would be rejected at publish
  // time as "not in the allowed-hosts list".
  final readerPolicy = pkg_reader.ReaderPolicy.club.copyWith(
    allowedHostedUrls: [
      ...pkg_reader.ReaderPolicy.club.allowedHostedUrls,
      if (config.serverUrl != null) config.serverUrl!.toString(),
    ],
  );

  final publishService = PublishService(
    store: metadataStore,
    blobStore: blobStore,
    searchIndex: searchIndex,
    generateId: () => _uuid.v4(),
    tempDir: config.tempDir,
    maxUploadBytes: config.maxUploadBytes,
    extractArchive: (file) => _extractArchive(file, policy: readerPolicy),
    onVersionPublished: (pkg, version) => scoringService.enqueue(pkg, version),
  );

  final downloadService = DownloadService(store: metadataStore);

  final packageService = PackageService(
    store: metadataStore,
    downloadService: downloadService,
    generateId: () => _uuid.v4(),
    enforceRetractionWindow: config.enforceRetractionWindow,
  );

  final publisherService = PublisherService(
    store: metadataStore,
    generateId: () => _uuid.v4(),
    // Real DNS resolver — tests inject their own. Dual-provider strict
    // mode is the default; if operators are behind a network that can't
    // reach both Google and Cloudflare we'd need to relax via config.
    dnsResolver: DualDohResolver(),
    verificationTtl: Duration(hours: config.verificationTokenTtlHours),
    maxVerifiedPublishersPerUser: config.maxPublishersPerUser,
  );

  final likesService = LikesService(store: metadataStore);

  // ── Check setup status ──────────────────────────────────────

  // ── Setup API (onboarding) ──────────────────────────────────

  final setupApi = SetupApi(
    authService: authService,
    metadataStore: metadataStore,
    signupEnabled: config.signupEnabled,
    trustProxy: config.trustProxy,
  );

  final users = await metadataStore.listUsers(limit: 1);
  if (users.items.isEmpty) {
    _printSetupBanner(config.serverUrl, setupApi.setupCode);
  }

  // ── Build HTTP handler ─────────────────────────────────────

  final effectiveStartedAt = startedAt ?? DateTime.now().toUtc();

  // Rate limiters are constructed here rather than inside the router
  // so the Scheduler can register each one's `sweep()` on a cron.
  // Services that own background state live at the bootstrap layer;
  // scheduling is a separate concern handled by Scheduler.
  final rateLimiters = RateLimiters.defaults(trustProxy: config.trustProxy);

  final handler = buildHandler(
    authService: authService,
    packageService: packageService,
    publishService: publishService,
    publisherService: publisherService,
    likesService: likesService,
    downloadService: downloadService,
    metadataStore: metadataStore,
    blobStore: blobStore,
    searchIndex: searchIndex,
    setupApi: setupApi,
    staticFilesPath: config.staticFilesPath,
    dartdocPath: config.dartdocPath,
    signupEnabled: config.signupEnabled,
    serverUrlOverride: config.serverUrl,
    trustProxy: config.trustProxy,
    allowedOrigins: config.allowedOrigins,
    scoringService: scoringService,
    sdkManager: sdkManager,
    settingsStore: settingsStore,
    config: config,
    startedAt: effectiveStartedAt,
    rateLimiters: rateLimiters,
  );

  // ── Scheduler ──────────────────────────────────────────────
  //
  // Cross-cutting scheduled work that doesn't belong to any one
  // component — DB housekeeping, retention sweeps, and the like.
  // Components that maintain their own state (e.g. RateLimiter's
  // in-memory buckets) own their own timers; only work that spans
  // components or the database lives here.
  final scheduler = Scheduler([
    ScheduledTask(
      name: 'publisher-verifications:sweep',
      // Hourly at :00. Expired rows are inert (upsert-on-start replaces
      // them anyway), so this is pure table hygiene.
      schedule: '0 * * * *',
      run: () async {
        final n = await metadataStore.deleteExpiredVerifications();
        if (n > 0) {
          _bootstrapLogger.fine('Pruned $n expired publisher verifications.');
        }
      },
    ),
  ]);
  scheduler.start();

  return BootstrapResult(
    handler: handler,
    metadataStore: metadataStore,
    blobStore: blobStore,
    searchIndex: searchIndex,
    startedAt: effectiveStartedAt,
    scheduler: scheduler,
  );
}

void _printSetupBanner(Uri? serverUrl, String setupCode) {
  final urlLine = serverUrl != null
      ? '${serverUrl.resolve('/setup')}'
      : '/setup';
  final table = Table(
    tableStyle: const TableStyle(border: true),
    body: TableSection(
      rows: [
        Row(
          cells: [
            Cell(
              'club — Initial Setup Required\n'
              '\n'
              'No admin account found.\n'
              'Open the setup wizard to create your admin account:\n'
              '\n'
              '  $urlLine\n'
              '\n'
              'Setup code:  $setupCode\n'
              '\n'
              'Enter this code in the wizard to verify\n'
              'you have access to these logs.',
              style: const CellStyle(
                paddingLeft: 2,
                paddingRight: 2,
                paddingTop: 1,
                paddingBottom: 1,
              ),
            ),
          ],
        ),
      ],
    ),
  );
  // ignore: avoid_print
  print('');
  // ignore: avoid_print
  print(table.render());
}

String _generateHex(int length) {
  final random = List.generate(length, (_) => _uuid.v4().hashCode % 16);
  return random.map((b) => b.toRadixString(16)).join();
}

/// Extract and validate a tarball archive.
///
/// Validation + string extraction (pubspec, readme, changelog, example,
/// license, libraries) is delegated to the vendored `club_package_reader`,
/// which implements the pub.dev validation rules. See
/// [packages/club_package_reader/README.md] for policy tuning.
///
/// A secondary tar pass (via `package:archive`) handles the club-specific
/// extras that the vendored reader doesn't surface: bin executable names,
/// `dart:*` imports for platform-tag derivation, and screenshot bytes.
Future<ArchiveContent> _extractArchive(
  File file, {
  required pkg_reader.ReaderPolicy policy,
}) async {
  final pkg_reader.PackageSummary summary;
  try {
    summary = await pkg_reader.summarizePackageArchive(
      file.path,
      policy: policy,
    );
  } catch (e) {
    // Covers decoder crashes that slip past scanArchiveSurface (rare — the
    // reader wraps most tar/gzip failures internally and returns them as
    // issues). Surface as a PackageRejected so the CLI gets a 400, not 500.
    throw PackageRejectedException.invalidArchive('Failed to read archive: $e');
  }

  if (summary.hasIssues) {
    final msg = summary.issues.map((i) => i.message).join('\n');
    throw PackageRejectedException.invalidArchive(msg);
  }

  // summary.pubspecContent is non-null once issues are empty (pubspec parse
  // success is a precondition inside summarizePackageArchive).
  final pubspecContent = summary.pubspecContent!;
  final Map<String, dynamic> pubspecMap;
  try {
    pubspecMap = _parseSimpleYaml(pubspecContent);
  } catch (e) {
    throw PackageRejectedException.invalidArchive('Invalid pubspec.yaml: $e');
  }

  // Second pass: extract the pieces of data the vendored reader doesn't
  // emit (bin executables, `dart:*` imports, and the bytes for any file
  // that may end up referenced as a screenshot or README asset). The
  // file is already on disk and capped at 100 MB, so decoding twice is
  // cheap and keeps the integration shallow.
  final bytes = await file.readAsBytes();
  final tarArchive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));

  final binExecutables = <String>[];
  final dartImports = <String>{};
  final imageBytesByPath = <String, List<int>>{};
  final readmeAssetBytesByPath = <String, List<int>>{};
  var hasBuildHooks = false;

  for (final entry in tarArchive) {
    if (!entry.isFile || entry.size == 0) continue;

    var name = entry.name;
    if (name.startsWith('./')) name = name.substring(2);
    if (name.isEmpty) continue;

    // Dart Build hooks: any direct-child `hook/*.dart` (e.g.
    // `hook/build.dart`, `hook/link.dart`). Nested paths like
    // `hook/src/helper.dart` are not hook entry points per the
    // Dart spec — match the upstream `checkHooks` allowlist shape
    // so a relaxed policy elsewhere can't produce a false positive.
    final slashCount = '/'.allMatches(name).length;
    if (slashCount == 1 && name.startsWith('hook/') && name.endsWith('.dart')) {
      hasBuildHooks = true;
    }

    final ext = screenshotExtOf(name);

    final isScreenshotEligible =
        _screenshotExts.contains(ext) && entry.size <= _maxScreenshotBytes;
    final readmeAssetCap = readmeAssetCapFor(ext);
    final isReadmeAssetEligible =
        readmeAssetCap != null && entry.size <= readmeAssetCap;

    if (isScreenshotEligible || isReadmeAssetEligible) {
      // Decode once and share between maps when both apply (e.g. a
      // 2 MiB png is eligible for both screenshot resolution and as a
      // README asset).
      final entryBytes = List<int>.from(entry.content as List<int>);
      if (isScreenshotEligible) imageBytesByPath[name] = entryBytes;
      if (isReadmeAssetEligible) readmeAssetBytesByPath[name] = entryBytes;
      continue;
    }

    final nameParts = name.split('/');
    if (name.startsWith('lib/') && name.endsWith('.dart')) {
      final source = utf8.decode(
        entry.content as List<int>,
        allowMalformed: true,
      );
      _scanDartImports(source, dartImports);
    } else if (nameParts.length == 2 &&
        nameParts.first == 'bin' &&
        name.endsWith('.dart')) {
      binExecutables.add(
        nameParts.last.substring(0, nameParts.last.length - 5),
      );
    }
  }

  final screenshots = _resolveScreenshots(pubspecMap, imageBytesByPath);

  // Rewrite README references to point at the screenshot endpoint (for
  // pubspec-declared screenshots) or the readme-asset endpoint (for
  // anything else in the supported extension set). Skipped when there
  // is no README — nothing to rewrite, no assets to extract.
  final pubspecName = pubspecMap['name'] as String? ?? '';
  final pubspecVersion = pubspecMap['version'] as String? ?? '';
  String? rewrittenReadme = summary.readmeContent;
  List<ExtractedReadmeAsset> readmeAssets = const [];
  if (rewrittenReadme != null &&
      pubspecName.isNotEmpty &&
      pubspecVersion.isNotEmpty) {
    final rewrite = rewriteReadmeAssets(
      readme: rewrittenReadme,
      archiveBytesByPath: readmeAssetBytesByPath,
      screenshotPaths: [for (final s in screenshots) s.path],
      packageName: pubspecName,
      version: pubspecVersion,
    );
    rewrittenReadme = rewrite.readme;
    readmeAssets = rewrite.assets;
  }

  return ArchiveContent(
    pubspecYaml: pubspecContent,
    pubspecMap: pubspecMap,
    readme: rewrittenReadme,
    changelog: summary.changelogContent,
    example: summary.exampleContent,
    examplePath: summary.examplePath,
    license: summary.licenseContent,
    licensePath: summary.licensePath,
    // summary.libraries paths are already lib/-stripped and lib/src-filtered.
    libraries: summary.libraries ?? const [],
    binExecutables: binExecutables,
    dartImports: dartImports,
    screenshots: screenshots,
    readmeAssets: readmeAssets,
    hasBuildHooks: hasBuildHooks,
  );
}

// Supported screenshot extensions. Mirrors pub.dev's accepted set so the
// UX of publishing a screenshot on this registry matches publishing to
// pub.dev without having to re-encode assets.
const _screenshotExts = <String>{'png', 'jpg', 'jpeg', 'gif', 'webp'};

// Per-image size cap — 4 MiB, matching pub.dev. Files larger than this
// are silently skipped during extraction so one oversized asset can't
// block an otherwise valid publish.
const _maxScreenshotBytes = 4 * 1024 * 1024;

// Maximum screenshots surfaced per version. Anything beyond this is
// ignored — keeps the sidebar, DB row, and API response bounded.
const _maxScreenshots = 10;

/// Resolve pubspec `screenshots:` entries against the bytes collected
/// during tarball iteration. Entries missing from the archive or using
/// unsupported extensions are dropped silently — publish continues so an
/// author with a stale path gets their version in rather than a hard fail.
List<ExtractedScreenshot> _resolveScreenshots(
  Map<String, dynamic> pubspec,
  Map<String, List<int>> imageBytesByPath,
) {
  final raw = pubspec['screenshots'];
  if (raw is! List) return const [];

  final out = <ExtractedScreenshot>[];
  for (final entry in raw) {
    if (out.length >= _maxScreenshots) break;
    if (entry is! Map) continue;
    final path = entry['path'];
    if (path is! String || path.isEmpty) continue;

    // Normalise the declared path the same way we normalised archive entry
    // names (strip leading `./`) so the lookup matches irrespective of
    // whether the author wrote `./screenshots/a.png` or `screenshots/a.png`.
    var normalised = path;
    if (normalised.startsWith('./')) normalised = normalised.substring(2);

    final bytes = imageBytesByPath[normalised];
    if (bytes == null) continue;

    final ext = screenshotExtOf(normalised);
    if (!_screenshotExts.contains(ext)) continue;

    out.add(
      ExtractedScreenshot(
        path: path,
        description: entry['description'] is String
            ? entry['description'] as String
            : null,
        bytes: bytes,
        mimeType:
            readmeAssetMimeFor(ext) ?? 'application/octet-stream',
      ),
    );
  }
  return out;
}

/// Scan Dart source for `import 'dart:xxx'` directives and collect the
/// library names (e.g. `io`, `html`, `ffi`) into [result].
void _scanDartImports(String source, Set<String> result) {
  // Match: import 'dart:io'; or import "dart:html";
  // Also handles: import 'dart:io' show File;
  final pattern = RegExp(r'''import\s+['"]dart:(\w+)['"]''');
  for (final match in pattern.allMatches(source)) {
    result.add(match.group(1)!);
  }
}

/// Parse pubspec YAML into a plain Dart map.
///
/// Uses the official `yaml` package so block scalars (`|`, `>`, `|-`, `>-`),
/// flow style, quoted strings, and nested structures are all handled
/// correctly. Returns `{}` for empty or null documents so callers can treat
/// the result as a map unconditionally.
Map<String, dynamic> _parseSimpleYaml(String source) {
  final node = loadYaml(source);
  if (node == null) return <String, dynamic>{};
  if (node is! YamlMap) {
    throw const FormatException('pubspec.yaml root must be a map');
  }
  return _yamlToDart(node) as Map<String, dynamic>;
}

Object? _yamlToDart(Object? node) {
  if (node is YamlMap) {
    return <String, dynamic>{
      for (final entry in node.entries)
        entry.key.toString(): _yamlToDart(entry.value),
    };
  }
  if (node is YamlList) {
    return [for (final item in node) _yamlToDart(item)];
  }
  return node;
}
