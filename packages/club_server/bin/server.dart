import 'dart:async';
import 'dart:io';

import 'package:club_server/src/bootstrap.dart';
import 'package:club_server/src/config/app_config.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> args) async {
  // Anything that escapes a Future/Stream without a handler lands here.
  // Without this guard, isolated async failures (e.g. a missed await in a
  // background task) would be eaten by the Dart runtime and only surface
  // as mystery hangs. Print and keep running — the server itself is fine.
  runZonedGuarded(() => _run(args), (error, stack) {
    stderr.writeln('Uncaught async error: $error\n$stack');
  });
}

Future<void> _run(List<String> args) async {
  final startedAt = DateTime.now().toUtc();

  // Load configuration
  final config = AppConfig.fromEnvironment();

  try {
    config.validate();
  } on StateError catch (e) {
    stderr.writeln('Configuration error: ${e.message}');
    exit(1);
  }

  // Bootstrap: create stores, services, handler
  final result = await bootstrap(config, startedAt: startedAt);

  // Start HTTP server
  final server = await shelf_io.serve(
    result.handler,
    config.host,
    config.port,
  );

  _printStartupInfo(config, server);

  // Graceful shutdown
  ProcessSignal.sigterm.watch().listen((_) async {
    // ignore: avoid_print
    print('Shutting down...');
    await server.close();
    // Stop scheduled work before closing stores, so a sweep can't fire
    // mid-shutdown against a half-closed DB.
    await result.scheduler.close();
    await result.searchIndex.close();
    await result.blobStore.close();
    await result.metadataStore.close();
    exit(0);
  });

  ProcessSignal.sigint.watch().listen((_) async {
    // ignore: avoid_print
    print('Shutting down...');
    await server.close();
    // Stop scheduled work before closing stores, so a sweep can't fire
    // mid-shutdown against a half-closed DB.
    await result.scheduler.close();
    await result.searchIndex.close();
    await result.blobStore.close();
    await result.metadataStore.close();
    exit(0);
  });
}

// ignore: avoid_print
void _p(String s) => print(s);

void _printStartupInfo(AppConfig config, HttpServer server) {
  _p('');
  _p('  ┌─────────────────────────────────────────────────┐');
  _p('  │  club server started                            │');
  _p('  └─────────────────────────────────────────────────┘');
  _p('');

  // ── Server ──────────────────────────────────────────────
  _p('  Server');
  _p('  ├─ Listening     http://${server.address.host}:${server.port}');
  if (config.serverUrl != null) {
    _p('  ├─ Public URL    ${config.serverUrl}');
  }
  _p('  ├─ Log level     ${config.logLevel}');
  _p('  ├─ Trust proxy   ${config.trustProxy}');
  _p('  └─ Signup        ${config.signupEnabled ? 'enabled' : 'disabled'}');
  _p('');

  // ── Database ────────────────────────────────────────────
  _p('  Database');
  switch (config.dbBackend) {
    case DbBackend.sqlite:
      _p('  └─ SQLite        ${config.sqlitePath}');
    case DbBackend.postgres:
      _p('  └─ PostgreSQL    ${_redactUrl(config.postgresUrl)}');
  }
  _p('');

  // ── Storage ─────────────────────────────────────────────
  _p('  Storage');
  switch (config.blobBackend) {
    case BlobBackend.filesystem:
      _p('  └─ Filesystem    ${config.blobPath}');
    case BlobBackend.s3:
      _p('  ├─ S3 bucket     ${config.s3?.bucket ?? '(not set)'}');
      _p('  ├─ S3 region     ${config.s3?.region ?? '(not set)'}');
      if (config.s3?.endpoint != null) {
        _p('  └─ S3 endpoint   ${config.s3!.endpoint}');
      } else {
        _p('  └─ S3 endpoint   AWS default');
      }
    case BlobBackend.gcs:
      _p('  └─ GCS bucket    ${config.gcs?.bucket ?? '(not set)'}');
  }
  _p('');

  // ── Search ──────────────────────────────────────────────
  _p('  Search');
  switch (config.searchBackend) {
    case SearchBackend.sqlite:
      _p('  └─ SQLite FTS5');
    case SearchBackend.meilisearch:
      _p('  └─ Meilisearch   ${config.meilisearchUrl}');
  }
  _p('');

  // ── Scoring ─────────────────────────────────────────────
  _p('  Scoring');
  _p('  └─ Managed via Admin > Settings > Scoring');
  _p('');
}

/// Redact password from a database URL for safe logging.
String _redactUrl(String? url) {
  if (url == null) return '(not set)';
  try {
    final uri = Uri.parse(url);
    if (uri.userInfo.contains(':')) {
      final user = uri.userInfo.split(':').first;
      return url.replaceFirst(uri.userInfo, '$user:****');
    }
    return url;
  } catch (_) {
    return '(invalid URL)';
  }
}
