/// All environment variable names used by club.
///
/// Plain, unprefixed names. Set them directly in docker-compose,
/// systemd units, or `export KEY=value` in the shell.
abstract final class EnvKeys {
  // Server
  static const host = 'HOST';

  /// Internal listen port. Intentionally NOT "PORT" to avoid conflict with
  /// docker-compose's PORT variable which controls the host-side mapping.
  static const port = 'LISTEN_PORT';
  static const serverUrl = 'SERVER_URL';
  static const logLevel = 'LOG_LEVEL';

  // Database
  static const dbBackend = 'DB_BACKEND';
  static const sqlitePath = 'SQLITE_PATH';
  static const postgresUrl = 'POSTGRES_URL';

  // Blob storage
  static const blobBackend = 'BLOB_BACKEND';
  static const blobPath = 'BLOB_PATH';
  static const s3Endpoint = 'S3_ENDPOINT';
  static const s3Bucket = 'S3_BUCKET';
  static const s3Region = 'S3_REGION';
  static const s3AccessKey = 'S3_ACCESS_KEY';
  static const s3SecretKey = 'S3_SECRET_KEY';
  static const gcsBucket = 'GCS_BUCKET';
  static const gcsCredentialsFile = 'GCS_CREDENTIALS_FILE';
  static const gcsCredentialsJson = 'GCS_CREDENTIALS_JSON';

  // Search
  static const searchBackend = 'SEARCH_BACKEND';
  static const meilisearchUrl = 'MEILISEARCH_URL';
  static const meilisearchKey = 'MEILISEARCH_KEY';

  // Auth
  static const jwtSecret = 'JWT_SECRET';
  static const sessionTtlHours = 'SESSION_TTL_HOURS';
  static const tokenExpiryDays = 'TOKEN_EXPIRY_DAYS';
  static const bcryptCost = 'BCRYPT_COST';

  /// When true, exposes the `/signup` page and `POST /api/auth/signup`
  /// endpoint so anyone can self-register. New signups are created with
  /// the `member` role. Default: false (closed / private registry mode).
  static const signupEnabled = 'SIGNUP_ENABLED';

  /// When true, the server trusts `X-Forwarded-Proto` and `X-Forwarded-For`
  /// headers for scheme detection (cookie `Secure` flag) and client-IP
  /// audit logging. Only set when the server runs behind a reverse proxy
  /// that guarantees those headers. Default: false, so direct exposure
  /// to the internet doesn't allow clients to spoof them.
  static const trustProxy = 'TRUST_PROXY';

  /// Comma-separated list of additional origins that `/api/auth/login`,
  /// `/api/auth/signup`, `/api/setup/complete` etc. should accept Origin
  /// headers from. The configured [serverUrl] is always trusted. Leave
  /// empty unless you front the server from multiple domains.
  static const allowedOrigins = 'ALLOWED_ORIGINS';

  /// When true (default), package version retraction and restoration are
  /// restricted to the 7-day windows defined in the Dart pub spec: a
  /// version can only be retracted within 7 days of its publish date, and
  /// a retracted version can only be restored within 7 days of when it
  /// was retracted. Set to `false` on a private self-hosted registry
  /// where admins need to retract older versions (e.g. known-bad
  /// releases predating the window).
  static const enforceRetractionWindow = 'ENFORCE_RETRACTION_WINDOW';

  // Publishers
  /// Maximum number of *verified* publishers a single user can own. Only
  /// counts publishers where the user is a member; internal publishers
  /// created by admins don't count against any user. Default: 10.
  static const maxPublishersPerUser = 'MAX_PUBLISHERS_PER_USER';

  /// How long a pending DNS verification token is valid, in hours.
  /// Must be long enough to survive real-world DNS propagation delays.
  /// Default: 24.
  static const verificationTokenTtlHours = 'VERIFICATION_TOKEN_TTL_HOURS';

  // Upload
  static const tempDir = 'TEMP_DIR';
  static const maxUploadBytes = 'MAX_UPLOAD_BYTES';

  // Static files
  static const staticFilesPath = 'STATIC_FILES_PATH';

  // Dartdoc output
  static const dartdocPath = 'DARTDOC_PATH';

  /// Where rendered dartdoc HTML lives.
  /// - `filesystem` (default): local `DARTDOC_PATH`, served by
  ///    `shelf_static`. Single-container, persistent-volume friendly.
  /// - `blob`: persisted into `BlobStore` as an indexed blob per
  ///    package, served via byte-range reads with an in-memory LRU.
  ///    Works with S3/GCS blob backends and multi-replica setups.
  static const dartdocBackend = 'DARTDOC_BACKEND';

  /// Max RAM (in MiB) the in-process dartdoc LRU may consume when
  /// `DARTDOC_BACKEND=blob`. Unused in filesystem mode. Default: 64.
  static const dartdocCacheMaxMemoryMb = 'DARTDOC_CACHE_MAX_MEMORY_MB';

  // Config file
  static const configFile = 'CONFIG';
}
