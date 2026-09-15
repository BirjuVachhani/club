import 'dart:convert';
import 'dart:io';

import 'package:club_core/club_core.dart';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';

import '../config/app_config.dart';
import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';

/// Archives are authenticated by the normal API middleware, including 304s.
class SiteApi {
  SiteApi(this.config, this.store, this.settingsStore);
  final AppConfig config;
  final MetadataStore store;
  final SettingsStore settingsStore;

  Future<bool> get disableSites async =>
      await settingsStore.getSetting('disable_sites') == 'true';

  DecodedRouter get router => DecodedRouter()
    ..get('/api/admin/sites/settings', _getSettings)
    ..put('/api/admin/sites/settings', _setSettings)
    ..get('/api/packages/<package>/sites', list)
    ..get('/api/packages/<package>/sites/<site>/archive', archive);

  Future<Response> _getSettings(Request request) async {
    requireRole(request, UserRole.admin);
    return Response.ok(
      jsonEncode({'disableSites': await disableSites}),
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );
  }

  Future<Response> _setSettings(Request request) async {
    requireRole(request, UserRole.admin);
    final body = jsonDecode(await request.readAsString());
    if (body is! Map || body['disableSites'] is! bool) {
      throw const InvalidInputException('disableSites must be a boolean.');
    }
    await settingsStore.setSetting(
      'disable_sites',
      body['disableSites'].toString(),
    );
    return _getSettings(request);
  }

  Future<Response?> _disabledResponse() async => await disableSites
      ? Response(
          403,
          body: jsonEncode({
            'error': {
              'code': 'sites_disabled',
              'message': 'Sites are disabled on this server.',
            },
          }),
          headers: {
            'content-type': 'application/json',
            'cache-control': 'no-store',
          },
        )
      : null;

  Future<Response> list(Request request, String package) async {
    final disabled = await _disabledResponse();
    if (disabled != null) return disabled;
    if (PackageNameValidator.validate(package) != null ||
        await store.lookupPackage(package) == null) {
      return Response.notFound('Not found');
    }
    final root = Directory('${config.sitesPath}/$package');
    final names = <String>[];
    final urls = <String, String>{};
    final labels = <String, String>{};
    if (await root.exists()) {
      await for (final entry in root.list(followLinks: false)) {
        if (entry is! Directory) continue;
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final metadata = File('${entry.path}/metadata.json');
        if (SiteUpload.validName(name) && await metadata.exists()) {
          final data = jsonDecode(await metadata.readAsString());
          if (data is Map && data['label'] is String) {
            labels[name] = data['label'] as String;
          }
        }
        final redirect = File('${entry.path}/redirect.json');
        if (SiteUpload.validName(name) && await redirect.exists()) {
          final data = jsonDecode(await redirect.readAsString());
          final url = data is Map ? data['url'] : null;
          if (url is String && SiteUpload.validUrl(url)) {
            names.add(name);
            urls[name] = url;
          }
          continue;
        }
        if (SiteUpload.validName(name) &&
            await File('${entry.path}/site.tar.gz').exists()) {
          names.add(name);
        }
      }
    }
    names.sort();
    return Response.ok(
      jsonEncode({
        'sites': names,
        'urls': urls,
        'labels': labels,
        'runnerUrl': config.siteRunnerUrl,
        'limits': config.siteLimits.toJson(),
      }),
      headers: {
        'content-type': 'application/json',
        'cache-control': 'private, no-store',
      },
    );
  }

  Future<Response> archive(Request request, String package, String site) async {
    // Check before reading bytes or honoring conditional requests.
    final disabled = await _disabledResponse();
    if (disabled != null) return disabled;
    if (PackageNameValidator.validate(package) != null ||
        !SiteUpload.validName(site) ||
        await store.lookupPackage(package) == null) {
      return Response.notFound('Not found');
    }
    final file = File('${config.sitesPath}/$package/$site/site.tar.gz');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return Response.notFound('Not found');
    }
    // Open once so an atomic site replacement cannot mismatch the ETag/body.
    final handle = await file.open();
    try {
      final length = await handle.length();
      if (length > config.siteLimits.archiveBytes) {
        await handle.close();
        return Response(413);
      }
      Stream<List<int>> chunks() async* {
        while (true) {
          final bytes = await handle.read(64 * 1024);
          if (bytes.isEmpty) break;
          yield bytes;
        }
      }

      final hash = (await sha256.bind(chunks()).first).toString();
      final etag = '"$hash"';
      final headers = {
        'etag': etag,
        'cache-control': 'private, no-cache',
        'content-type': 'application/gzip',
        'x-content-type-options': 'nosniff',
      };
      final matches = request.headers['if-none-match']
          ?.split(',')
          .map((v) => v.trim().replaceFirst(RegExp(r'^W/'), ''));
      if (matches != null &&
          (matches.contains(etag) || matches.contains('*'))) {
        await handle.close();
        return Response.notModified(headers: headers);
      }
      await handle.setPosition(0);
      // The stream owns its descriptor after returning the response.
      final body = chunks();
      return Response.ok(
        _closeAfter(body, handle),
        headers: {...headers, 'content-length': '$length'},
      );
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }
}

Stream<List<int>> _closeAfter(
  Stream<List<int>> stream,
  RandomAccessFile file,
) async* {
  try {
    yield* stream;
  } finally {
    await file.close();
  }
}
