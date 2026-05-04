import 'dart:io';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_static/shelf_static.dart';

import 'api/account_api.dart';
import 'api/admin_api.dart';
import 'config/app_config.dart';
import 'api/auth_api.dart';
import 'api/dartdoc_api.dart';
import 'dartdoc/blob_handler.dart';
import 'dartdoc/cache.dart';
import 'api/downloads_api.dart';
import 'api/health_api.dart';
import 'api/legal_api.dart';
import 'api/oauth_api.dart';
import 'api/likes_api.dart';
import 'api/package_admin_api.dart';
import 'api/pub_api.dart';
import 'api/publisher_api.dart';
import 'api/scoring_api.dart';
import 'api/sdk_api.dart';
import 'api/search_api.dart';
import 'api/setup_api.dart';
import 'api/version_api.dart';
import 'update/update_checker.dart';
import 'auth/geo_locator.dart';
import 'scoring/internal_scoring_token.dart';
import 'scoring/scoring_service.dart';
import 'sdk/sdk_manager.dart';
import 'middleware/auth_middleware.dart';
import 'middleware/error_middleware.dart';
import 'middleware/logging_middleware.dart';
import 'middleware/origin_guard.dart';
import 'middleware/public_routes.dart';
import 'middleware/rate_limit.dart';
import 'middleware/security_headers.dart';
import 'middleware/setup_guard.dart';

/// Build the full shelf handler with all routes and middleware.
Handler buildHandler({
  required AuthService authService,
  required PackageService packageService,
  required PublishService publishService,
  required PublisherService publisherService,
  required LikesService likesService,
  required DownloadService downloadService,
  required MetadataStore metadataStore,
  required BlobStore blobStore,
  required SearchIndex searchIndex,
  required SetupApi setupApi,
  String? staticFilesPath,
  required String dartdocPath,
  Uri? serverUrlOverride,
  bool signupEnabled = false,
  bool trustProxy = false,
  List<String> allowedOrigins = const [],
  required ScoringService scoringService,
  required SdkManager sdkManager,
  required SettingsStore settingsStore,
  required AppConfig config,
  required DateTime startedAt,
  required RateLimiters rateLimiters,
  required UpdateChecker updateChecker,
  InternalScoringToken? internalScoringToken,
}) {
  // Rate limiters are constructed in bootstrap and passed in here so
  // the same instances can be registered with the Scheduler for
  // periodic bucket sweeps. Keeps the router focused on HTTP routing.
  final loginLimiter = rateLimiters.login;
  final signupLimiter = rateLimiters.signup;
  final setupLimiter = rateLimiters.setup;
  final inviteLimiter = rateLimiters.invite;
  // Create API handlers
  final pubApi = PubApi(
    packageService: packageService,
    publishService: publishService,
    blobStore: blobStore,
    metadataStore: metadataStore,
    downloadService: downloadService,
    serverUrlOverride: serverUrlOverride,
  );
  final downloadsApi = DownloadsApi(
    downloadService: downloadService,
    metadataStore: metadataStore,
  );
  final authApi = AuthApi(
    authService: authService,
    metadataStore: metadataStore,
    geoLocator: IpwhoisGeoLocator(),
    signupEnabled: signupEnabled,
    trustProxy: trustProxy,
  );
  final oauthApi = OAuthApi(
    authService: authService,
    metadataStore: metadataStore,
  );
  final packageAdminApi = PackageAdminApi(
    packageService: packageService,
    metadataStore: metadataStore,
    blobStore: blobStore,
  );
  final searchApi = SearchApi(
    searchIndex: searchIndex,
    metadataStore: metadataStore,
  );
  final likesApi = LikesApi(likesService: likesService);
  final accountApi = AccountApi(metadataStore: metadataStore);
  final publisherApi = PublisherApi(
    publisherService: publisherService,
    metadataStore: metadataStore,
  );
  final adminApi = AdminApi(
    authService: authService,
    metadataStore: metadataStore,
    blobStore: blobStore,
    searchIndex: searchIndex,
    serverUrl: serverUrlOverride ?? Uri.parse('http://localhost:8080'),
    config: config,
    startedAt: startedAt,
    updateChecker: updateChecker,
  );
  final healthApi = HealthApi(
    metadataStore: metadataStore,
    blobStore: blobStore,
    searchIndex: searchIndex,
  );
  final versionApi = VersionApi();
  final legalApi = LegalApi(settingsStore: settingsStore);
  final scoringApi = ScoringApi(
    scoringService: scoringService,
    metadataStore: metadataStore,
    settingsStore: settingsStore,
  );
  final sdkApi = SdkApi(
    sdkManager: sdkManager,
    settingsStore: settingsStore,
    scoringService: scoringService,
    metadataStore: metadataStore,
  );
  final dartdocApi = DartdocApi(
    scoringService: scoringService,
    metadataStore: metadataStore,
    settingsStore: settingsStore,
  );
  // Combine all routers
  final cascade = Cascade()
      .add(healthApi.router.call)
      .add(versionApi.router.call)
      .add(legalApi.router.call)
      .add(setupApi.router.call)
      .add(pubApi.router.call)
      .add(authApi.router.call)
      .add(oauthApi.router.call)
      .add(packageAdminApi.router.call)
      .add(searchApi.router.call)
      .add(likesApi.router.call)
      .add(accountApi.router.call)
      .add(publisherApi.router.call)
      .add(adminApi.router.call)
      .add(scoringApi.router.call)
      .add(sdkApi.router.call)
      .add(dartdocApi.router.call)
      .add(downloadsApi.router.call);

  // Serve dartdoc HTML under /documentation/<package>/latest/. Two
  // serve paths depending on `DARTDOC_BACKEND`:
  //   - filesystem: local tree at `<dartdocPath>/<pkg>/latest/…`,
  //     served by shelf_static. Requires a persistent DARTDOC_PATH
  //     volume; doesn't cooperate with S3/GCS blob backends.
  //   - blob: read from BlobStore as an indexed blob + LRU cache.
  //     See docs/PLAN_DARTDOC_BLOB_STORAGE.md for the full rationale.
  Handler apiHandler = cascade.handler;
  final matchDartdoc = RegExp(r'^documentation/([^/]+)/([^/]+)(/.*)?$');

  if (config.dartdocBackend == DartdocBackend.blob) {
    final cache = InMemoryDartdocCache(
      maxMemoryBytes: config.dartdocCacheMaxMemoryMb * 1024 * 1024,
    );
    final blobHandler = makeBlobDartdocHandler(
      blobStore: blobStore,
      cache: cache,
    );
    final prevHandler = apiHandler;
    apiHandler = (Request request) async {
      final match = matchDartdoc.firstMatch(request.url.path);
      if (match != null) {
        return blobHandler(
          request,
          match.group(1)!,
          match.group(2)!,
          match.group(3) ?? '/',
        );
      }
      return prevHandler(request);
    };
  } else {
    final dartdocDir = Directory(dartdocPath);
    if (dartdocDir.existsSync()) {
      final docsStaticHandler = createStaticHandler(
        dartdocPath,
        defaultDocument: 'index.html',
      );
      final prevHandler = apiHandler;
      apiHandler = (Request request) async {
        final match = matchDartdoc.firstMatch(request.url.path);
        if (match != null) {
          final pkg = match.group(1)!;
          final version = match.group(2)!;
          final rest = match.group(3) ?? '/';
          if (version != 'latest') {
            return Response.found('/documentation/$pkg/latest$rest');
          }
          // On-disk layout: `<dartdocPath>/<pkg>/latest/...`.
          // shelf_static resolves url.path relative to its root, so
          // we construct `<pkg>/latest/<rest>` and let it resolve.
          final docRequest = Request(
            'GET',
            Uri.parse('http://localhost/$pkg/latest$rest'),
            headers: request.headers,
          );
          return docsStaticHandler(docRequest);
        }
        return prevHandler(request);
      };
    }
  }

  // Add static file serving for SvelteKit build output
  if (staticFilesPath != null && Directory(staticFilesPath).existsSync()) {
    final staticHandler = createStaticHandler(
      staticFilesPath,
      defaultDocument: 'index.html',
    );

    // SPA fallback: serve index.html for any non-API route that doesn't
    // match a static file. Required for SvelteKit client-side routing.
    final indexFile = File('$staticFilesPath/index.html');
    final indexBytes = indexFile.existsSync()
        ? indexFile.readAsBytesSync()
        : null;

    final combinedHandler = Cascade()
        .add(apiHandler)
        .add(staticHandler)
        .handler;

    // Try API+docs+static first, then SPA fallback for non-API/docs 404s
    apiHandler = (Request request) async {
      final response = await combinedHandler(request);
      if (response.statusCode == 404 &&
          !request.url.path.startsWith('api/') &&
          !request.url.path.startsWith('documentation/') &&
          indexBytes != null) {
        return Response.ok(
          indexBytes,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }
      return response;
    };
  }

  // Build middleware pipeline. Order matters:
  //   1. security headers last so they're attached to every response,
  //      including errors raised by earlier stages
  //   2. logging at the edge so we see all traffic
  //   3. rate limits + origin guard *before* auth so a flood of bad
  //      requests doesn't hit the DB
  //   4. auth + CSRF
  //   5. setup guard
  final pipeline = Pipeline()
      .addMiddleware(securityHeadersMiddleware())
      .addMiddleware(loggingMiddleware())
      .addMiddleware(errorMiddleware())
      .addMiddleware(
        originGuardMiddleware(
          serverUrl: serverUrlOverride,
          allowedOrigins: allowedOrigins,
          trustProxy: trustProxy,
        ),
      )
      .addMiddleware(
        rateLimitMiddleware(
          limiter: loginLimiter,
          paths: const {'/api/auth/login'},
        ),
      )
      .addMiddleware(
        rateLimitMiddleware(
          limiter: signupLimiter,
          paths: const {'/api/auth/signup'},
        ),
      )
      .addMiddleware(
        rateLimitMiddleware(
          limiter: setupLimiter,
          paths: const {'/api/setup/verify', '/api/setup/complete'},
        ),
      )
      .addMiddleware(
        rateLimitMiddleware(
          limiter: inviteLimiter,
          // Prefix match because the invite token is in the path:
          //   POST /api/invites/<token>/accept
          prefixPaths: const {'/api/invites/'},
        ),
      )
      .addMiddleware(setupGuardMiddleware(metadataStore))
      .addMiddleware(
        authMiddleware(
          authService,
          // The public surface is defined in `public_routes.dart` so
          // the auth middleware, the router, and the regression test
          // share a single source of truth. Default policy is
          // auth-required.
          publicExactPaths: publicExactPaths,
          publicPathPrefixes: publicPathPrefixes,
          internalScoringToken: internalScoringToken,
        ),
      )
      .addHandler(apiHandler);

  return pipeline;
}
