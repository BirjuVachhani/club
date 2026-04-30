import 'dart:io';

import 'package:yaml/yaml.dart';

import 'env_keys.dart';

enum DbBackend { sqlite, postgres }

enum BlobBackend { filesystem, s3, gcs }

enum SearchBackend { sqlite, meilisearch }

/// Where rendered dartdoc HTML trees are stored and served from.
enum DartdocBackend {
  /// Write to `dartdocPath` on the local filesystem, serve via
  /// `shelf_static`. Default; ideal for single-container self-hosted
  /// deployments on a persistent `/data` volume.
  filesystem,

  /// Pack each package's dartdoc tree into a single indexed blob
  /// (`<pkg>/dartdoc/latest/{index.json, blob}`) in the [BlobStore],
  /// serve via byte-range reads with an in-process LRU in front.
  /// Required for S3/GCS blob backends and multi-replica deployments.
  blob,
}

class S3Config {
  const S3Config({
    this.endpoint,
    required this.bucket,
    required this.region,
    required this.accessKey,
    required this.secretKey,
  });

  final String? endpoint;
  final String bucket;
  final String region;
  final String accessKey;
  final String secretKey;
}

/// Firebase Storage / Google Cloud Storage configuration.
///
/// Auth priority: [credentialsFile] > [credentialsJson] > Application
/// Default Credentials (when both are null/empty).
///
/// [credentialsJson] holds a raw service-account PEM for the process
/// lifetime. Prefer [credentialsFile] when possible so the key isn't
/// resident in the config object. Never log or serialize this struct.
class GcsConfig {
  const GcsConfig({
    required this.bucket,
    this.credentialsFile,
    this.credentialsJson,
  });

  final String bucket;
  final String? credentialsFile;
  final String? credentialsJson;

  /// Redacted toString so accidental logging of [AppConfig] doesn't leak the
  /// private key.
  @override
  String toString() =>
      'GcsConfig(bucket: $bucket, credentialsFile: ${credentialsFile != null ? "<set>" : "<unset>"}, credentialsJson: ${credentialsJson != null ? "<redacted>" : "<unset>"})';
}

/// Application configuration loaded from env vars + optional YAML file.
class AppConfig {
  AppConfig({
    this.host = '0.0.0.0',
    this.port = 8080,
    this.serverUrl,
    this.logLevel = 'info',
    required this.jwtSecret,
    this.sessionTtlHours = 1,
    this.tokenExpiryDays = 365,
    this.bcryptCost = 12,
    this.dbBackend = DbBackend.sqlite,
    this.sqlitePath = '/data/db/club.db',
    this.postgresUrl,
    this.blobBackend = BlobBackend.filesystem,
    this.blobPath = '/data/blobs',
    this.s3,
    this.gcs,
    this.searchBackend = SearchBackend.sqlite,
    this.meilisearchUrl,
    this.meilisearchKey,
    this.tempDir = '/data/tmp/uploads',
    this.maxUploadBytes = 100 * 1024 * 1024,
    this.staticFilesPath,
    this.dartdocPath = '/data/cache/dartdoc',
    this.dartdocBackend = DartdocBackend.filesystem,
    this.dartdocCacheMaxMemoryMb = 64,
    this.signupEnabled = false,
    this.trustProxy = false,
    this.allowedOrigins = const [],
    this.enforceRetractionWindow = true,
    this.maxPublishersPerUser = 10,
    this.verificationTokenTtlHours = 24,
  });

  // Server
  final String host;
  final int port;
  final Uri? serverUrl;
  final String logLevel;

  // Auth
  final String jwtSecret;
  final int sessionTtlHours;
  final int tokenExpiryDays;
  final int bcryptCost;

  // Database
  final DbBackend dbBackend;
  final String sqlitePath;
  final String? postgresUrl;

  // Blob storage
  final BlobBackend blobBackend;
  final String blobPath;
  final S3Config? s3;
  final GcsConfig? gcs;

  // Search
  final SearchBackend searchBackend;
  final String? meilisearchUrl;
  final String? meilisearchKey;

  // Upload
  final String tempDir;
  final int maxUploadBytes;

  // Static files (SvelteKit build output)
  final String? staticFilesPath;

  // Dartdoc output directory. In `filesystem` mode the server writes
  // dartdoc trees here and serves them via shelf_static. In `blob`
  // mode this directory is unused; everything lives in the BlobStore.
  final String dartdocPath;

  /// Where dartdoc HTML is persisted + served from. See [DartdocBackend].
  final DartdocBackend dartdocBackend;

  /// Cap on in-process dartdoc LRU size (blob mode only). Bytes are
  /// counted against cached payloads, not entry count. Tune up if your
  /// hot-set exceeds the default 64 MiB.
  final int dartdocCacheMaxMemoryMb;

  /// Enable the `/signup` page and endpoint. Off by default (closed
  /// registry). Controlled by `SIGNUP_ENABLED=true`.
  final bool signupEnabled;

  /// Trust `X-Forwarded-Proto` / `X-Forwarded-For` from the request.
  /// See [EnvKeys.trustProxy] for the reasoning — only enable when the
  /// server is behind a reverse proxy that strips client-supplied copies.
  final bool trustProxy;

  /// Extra origins allowed on public state-changing endpoints (login,
  /// signup, setup). [serverUrl] is always included implicitly.
  final List<String> allowedOrigins;

  /// Enforce the pub spec's 7-day retraction/restoration windows. When
  /// `true` (the default), a version can only be retracted within 7 days
  /// of publishing and only restored within 7 days of retraction — the
  /// behaviour documented at https://dart.dev/tools/pub/publishing#retract.
  /// Set to `false` on a private registry where admins need to retract
  /// older versions (e.g. pulling a release with a known security issue
  /// that's outside the window). Controlled by
  /// `ENFORCE_RETRACTION_WINDOW=true|false`.
  final bool enforceRetractionWindow;

  /// Maximum verified publishers a single user may own. Membership in an
  /// admin-created internal publisher doesn't count — only DNS-verified
  /// publishers are quota-bearing. Controlled by
  /// `MAX_PUBLISHERS_PER_USER` (default 10).
  final int maxPublishersPerUser;

  /// How long a pending DNS verification token stays valid. Real-world
  /// DNS propagation can be slow (corporate resolvers, long TTLs, etc.),
  /// so this defaults to 24 hours. Controlled by
  /// `VERIFICATION_TOKEN_TTL_HOURS`.
  final int verificationTokenTtlHours;

  /// Load config from environment variables, with optional YAML file as base.
  factory AppConfig.fromEnvironment() {
    final env = Platform.environment;
    Map<String, dynamic> yaml = {};

    // Load YAML config if specified
    final configPath = env[EnvKeys.configFile] ?? '/etc/club/config.yaml';
    final configFile = File(configPath);
    if (configFile.existsSync()) {
      final content = configFile.readAsStringSync();
      final parsed = loadYaml(content);
      if (parsed is YamlMap) {
        yaml = _flattenYaml(parsed);
      }
    }

    // Env vars are read by their bare names (no CLUB_ prefix). Operators
    // using docker-compose / shell scripts set e.g. `HOST`, `JWT_SECRET`
    // directly — the container namespace already scopes them.
    String? readEnv(String key) => env[key];

    String str(String envKey, [String? yamlKey, String? defaultVal]) {
      return readEnv(envKey) ??
          yaml[yamlKey ?? envKey]?.toString() ??
          defaultVal ??
          '';
    }

    int integer(String envKey, [String? yamlKey, int defaultVal = 0]) {
      final raw = readEnv(envKey) ?? yaml[yamlKey ?? envKey]?.toString();
      return raw != null ? (int.tryParse(raw) ?? defaultVal) : defaultVal;
    }

    /// Parse a boolean env var. Accepts the usual truthy forms
    /// ("true", "1", "yes", "on") case-insensitively; anything else is false.
    bool boolean(String envKey, [String? yamlKey, bool defaultVal = false]) {
      final raw = readEnv(envKey) ?? yaml[yamlKey ?? envKey]?.toString();
      if (raw == null) return defaultVal;
      final v = raw.trim().toLowerCase();
      return v == 'true' || v == '1' || v == 'yes' || v == 'on';
    }

    final serverUrlStr = str(EnvKeys.serverUrl, 'server_url');

    return AppConfig(
      host: str(EnvKeys.host, 'host', '0.0.0.0'),
      port: integer(EnvKeys.port, 'port', 8080),
      serverUrl: serverUrlStr.isNotEmpty ? Uri.parse(serverUrlStr) : null,
      logLevel: str(EnvKeys.logLevel, 'log_level', 'info'),
      jwtSecret: str(EnvKeys.jwtSecret, 'jwt_secret'),
      sessionTtlHours: integer(EnvKeys.sessionTtlHours, 'session_ttl_hours', 1),
      tokenExpiryDays: integer(
        EnvKeys.tokenExpiryDays,
        'token_expiry_days',
        365,
      ),
      bcryptCost: integer(EnvKeys.bcryptCost, 'bcrypt_cost', 12),
      dbBackend: str(EnvKeys.dbBackend, 'db_backend', 'sqlite') == 'postgres'
          ? DbBackend.postgres
          : DbBackend.sqlite,
      sqlitePath: str(EnvKeys.sqlitePath, 'sqlite_path', '/data/db/club.db'),
      postgresUrl: env[EnvKeys.postgresUrl] ?? yaml['postgres_url']?.toString(),
      blobBackend: _parseBlobBackend(
        str(EnvKeys.blobBackend, 'blob_backend', 'filesystem'),
      ),
      blobPath: str(EnvKeys.blobPath, 'blob_path', '/data/blobs'),
      s3: _parseS3(env, yaml),
      gcs: _parseGcs(env, yaml),
      searchBackend:
          str(EnvKeys.searchBackend, 'search_backend', 'sqlite') ==
              'meilisearch'
          ? SearchBackend.meilisearch
          : SearchBackend.sqlite,
      meilisearchUrl:
          env[EnvKeys.meilisearchUrl] ?? yaml['meilisearch_url']?.toString(),
      meilisearchKey:
          env[EnvKeys.meilisearchKey] ?? yaml['meilisearch_key']?.toString(),
      tempDir: str(EnvKeys.tempDir, 'temp_dir', '/data/tmp/uploads'),
      maxUploadBytes: integer(
        EnvKeys.maxUploadBytes,
        'max_upload_bytes',
        100 * 1024 * 1024,
      ),
      staticFilesPath: _resolveStaticFilesPath(readEnv, yaml),
      dartdocPath: str(
        EnvKeys.dartdocPath,
        'dartdoc_path',
        '/data/cache/dartdoc',
      ),
      dartdocBackend: _parseDartdocBackend(
        str(EnvKeys.dartdocBackend, 'dartdoc_backend', 'filesystem'),
      ),
      dartdocCacheMaxMemoryMb: integer(
        EnvKeys.dartdocCacheMaxMemoryMb,
        'dartdoc_cache_max_memory_mb',
        64,
      ),
      signupEnabled: boolean(EnvKeys.signupEnabled, 'signup_enabled', false),
      trustProxy: boolean(EnvKeys.trustProxy, 'trust_proxy', false),
      allowedOrigins: () {
        final raw = str(EnvKeys.allowedOrigins, 'allowed_origins', '');
        if (raw.isEmpty) return const <String>[];
        return raw
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
      }(),
      enforceRetractionWindow: boolean(
        EnvKeys.enforceRetractionWindow,
        'enforce_retraction_window',
        true,
      ),
      maxPublishersPerUser: integer(
        EnvKeys.maxPublishersPerUser,
        'max_publishers_per_user',
        10,
      ),
      verificationTokenTtlHours: integer(
        EnvKeys.verificationTokenTtlHours,
        'verification_token_ttl_hours',
        24,
      ),
    );
  }

  /// Resolve the static files path. Checks env, yaml, then common defaults.
  static String? _resolveStaticFilesPath(
    String? Function(String) readEnv,
    Map<String, dynamic> yaml,
  ) {
    final explicit =
        readEnv(EnvKeys.staticFilesPath) ??
        yaml['static_files_path']?.toString();
    if (explicit != null && explicit.isNotEmpty) return explicit;

    // Auto-detect: check common locations
    const candidates = [
      '/app/static/web', // Docker default
      'packages/club_web/build', // Local dev (from repo root)
    ];
    for (final path in candidates) {
      if (Directory(path).existsSync()) return path;
    }
    return null;
  }

  /// Load from a map (for testing).
  factory AppConfig.fromMap(Map<String, dynamic> map) {
    final db = map['db'] as Map<String, dynamic>? ?? {};
    final blob = map['blob'] as Map<String, dynamic>? ?? {};

    return AppConfig(
      host: map['host'] as String? ?? '0.0.0.0',
      port: map['port'] as int? ?? 8080,
      serverUrl: map['server_url'] != null
          ? Uri.parse(map['server_url'] as String)
          : null,
      logLevel: map['log_level'] as String? ?? 'info',
      jwtSecret: map['jwt_secret'] as String? ?? '',
      sessionTtlHours: map['session_ttl_hours'] as int? ?? 1,
      tokenExpiryDays: map['token_expiry_days'] as int? ?? 365,
      dbBackend: db['backend'] == 'postgres'
          ? DbBackend.postgres
          : DbBackend.sqlite,
      sqlitePath: db['sqlite_path'] as String? ?? '/tmp/club-test.db',
      postgresUrl: db['postgres_url'] as String?,
      blobBackend: _parseBlobBackend(blob['backend'] as String?),
      blobPath: blob['path'] as String? ?? '/tmp/club-test-packages',
      tempDir: map['temp_dir'] as String? ?? '/tmp/club-test-uploads',
      maxUploadBytes: map['max_upload_bytes'] as int? ?? 100 * 1024 * 1024,
      staticFilesPath: map['static_files_path'] as String?,
      dartdocPath: map['dartdoc_path'] as String? ?? '/data/cache/dartdoc',
      dartdocBackend: _parseDartdocBackend(
        map['dartdoc_backend'] as String?,
      ),
      dartdocCacheMaxMemoryMb:
          map['dartdoc_cache_max_memory_mb'] as int? ?? 64,
    );
  }

  /// Validate required fields. Throws [StateError] if misconfigured.
  void validate() {
    if (jwtSecret.isEmpty) {
      throw StateError('JWT_SECRET is required.');
    }
    if (jwtSecret.length < 32) {
      throw StateError('JWT_SECRET must be at least 32 characters.');
    }
    if (dbBackend == DbBackend.postgres &&
        (postgresUrl == null || postgresUrl!.isEmpty)) {
      throw StateError('POSTGRES_URL must be set when DB_BACKEND=postgres.');
    }
    if (blobBackend == BlobBackend.s3) {
      if (s3 == null) {
        throw StateError('S3 configuration required when BLOB_BACKEND=s3.');
      }
      if (s3!.accessKey.isEmpty || s3!.secretKey.isEmpty) {
        throw StateError(
          'S3_ACCESS_KEY and S3_SECRET_KEY are required when BLOB_BACKEND=s3.',
        );
      }
    }
    if (blobBackend == BlobBackend.gcs) {
      if (gcs == null || gcs!.bucket.isEmpty) {
        throw StateError('GCS_BUCKET is required when BLOB_BACKEND=gcs.');
      }
      // credentialsFile/credentialsJson are both optional — fall back to
      // Application Default Credentials when neither is set. That's valid on
      // GCE/GKE/Cloud Run but won't work on a laptop, so no hard failure here.
    }
    if (searchBackend == SearchBackend.meilisearch &&
        (meilisearchUrl == null || meilisearchUrl!.isEmpty)) {
      throw StateError(
        'MEILISEARCH_URL must be set when SEARCH_BACKEND=meilisearch.',
      );
    }
  }

  static BlobBackend _parseBlobBackend(String? raw) {
    switch (raw) {
      case 's3':
        return BlobBackend.s3;
      case 'gcs':
      case 'firebase':
        return BlobBackend.gcs;
      default:
        return BlobBackend.filesystem;
    }
  }

  /// Parse `DARTDOC_BACKEND=filesystem|blob`. Unknown / missing values
  /// default to `filesystem` — the safe choice that requires no extra
  /// storage-layer capability.
  static DartdocBackend _parseDartdocBackend(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'blob':
        return DartdocBackend.blob;
      case 'filesystem':
      case '':
      case null:
        return DartdocBackend.filesystem;
      default:
        return DartdocBackend.filesystem;
    }
  }

  static GcsConfig? _parseGcs(
    Map<String, String> env,
    Map<String, dynamic> yaml,
  ) {
    String? e(String key) => env[key];
    final bucket = e(EnvKeys.gcsBucket) ?? yaml['gcs_bucket']?.toString();
    if (bucket == null || bucket.isEmpty) return null;

    return GcsConfig(
      bucket: bucket,
      credentialsFile:
          e(EnvKeys.gcsCredentialsFile) ??
          yaml['gcs_credentials_file']?.toString(),
      credentialsJson:
          e(EnvKeys.gcsCredentialsJson) ??
          yaml['gcs_credentials_json']?.toString(),
    );
  }

  static S3Config? _parseS3(
    Map<String, String> env,
    Map<String, dynamic> yaml,
  ) {
    String? e(String key) => env[key];
    final bucket = e(EnvKeys.s3Bucket) ?? yaml['s3_bucket']?.toString();
    if (bucket == null || bucket.isEmpty) return null;

    return S3Config(
      endpoint: e(EnvKeys.s3Endpoint) ?? yaml['s3_endpoint']?.toString(),
      bucket: bucket,
      region:
          e(EnvKeys.s3Region) ?? yaml['s3_region']?.toString() ?? 'us-east-1',
      accessKey:
          e(EnvKeys.s3AccessKey) ?? yaml['s3_access_key']?.toString() ?? '',
      secretKey:
          e(EnvKeys.s3SecretKey) ?? yaml['s3_secret_key']?.toString() ?? '',
    );
  }

  static Map<String, dynamic> _flattenYaml(YamlMap yaml) {
    final result = <String, dynamic>{};
    for (final entry in yaml.entries) {
      final key = entry.key.toString();
      if (entry.value is YamlMap) {
        final nested = _flattenYaml(entry.value as YamlMap);
        for (final nEntry in nested.entries) {
          result['${key}_${nEntry.key}'] = nEntry.value;
        }
        result[key] = _yamlMapToMap(entry.value as YamlMap);
      } else {
        result[key] = entry.value;
      }
    }
    return result;
  }

  static Map<String, dynamic> _yamlMapToMap(YamlMap yaml) {
    final result = <String, dynamic>{};
    for (final entry in yaml.entries) {
      result[entry.key.toString()] = entry.value is YamlMap
          ? _yamlMapToMap(entry.value as YamlMap)
          : entry.value;
    }
    return result;
  }
}
