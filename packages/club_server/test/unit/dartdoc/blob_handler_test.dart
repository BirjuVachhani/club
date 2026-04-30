import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:club_core/club_core.dart';
import 'package:club_indexed_blob/club_indexed_blob.dart';
import 'package:club_server/src/dartdoc/blob_handler.dart';
import 'package:club_server/src/dartdoc/cache.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

void main() {
  group('makeBlobDartdocHandler', () {
    late _FakeBlobStore blobStore;
    late InMemoryDartdocCache cache;
    late BlobDartdocHandler handler;

    setUp(() async {
      blobStore = _FakeBlobStore();
      cache = InMemoryDartdocCache(maxMemoryBytes: 1024 * 1024);
      handler = makeBlobDartdocHandler(blobStore: blobStore, cache: cache);
    });

    /// Uploads a minimal indexed blob for [pkg] with the given files.
    Future<void> seedDartdoc(
      String pkg,
      Map<String, String> files,
    ) async {
      final pair = await BlobIndexPair.build('$pkg-blob', (addFile) async {
        for (final entry in files.entries) {
          await addFile(
            entry.key,
            Stream.value(gzip.encode(utf8.encode(entry.value))),
          );
        }
      });
      blobStore.assets['$pkg/dartdoc/latest/blob'] = pair.blob;
      blobStore.assets['$pkg/dartdoc/latest/index.json'] = pair.index.asBytes();
    }

    shelf.Request req(String url, {Map<String, String>? headers}) =>
        shelf.Request('GET', Uri.parse('http://test/$url'), headers: headers);

    test('serves index.html on empty path', () async {
      await seedDartdoc('foo', {'index.html': '<h1>hi</h1>'});
      final resp = await handler(req('documentation/foo/latest/'), 'foo',
          'latest', '/');
      expect(resp.statusCode, 200);
      expect(resp.headers['content-type'], contains('text/html'));
      expect(
        utf8.decode(await _collect(resp.read())),
        '<h1>hi</h1>',
      );
    });

    test('serves a nested file', () async {
      await seedDartdoc('foo', {
        'index.html': 'root',
        'api/Thing-class.html': '<h1>Thing</h1>',
      });
      final resp = await handler(
        req('documentation/foo/latest/api/Thing-class.html'),
        'foo',
        'latest',
        '/api/Thing-class.html',
      );
      expect(resp.statusCode, 200);
      expect(
        utf8.decode(await _collect(resp.read())),
        '<h1>Thing</h1>',
      );
    });

    test('404s when index.json is missing', () async {
      final resp = await handler(
        req('documentation/missing/latest/'),
        'missing',
        'latest',
        '/',
      );
      expect(resp.statusCode, 404);
      expect(
        utf8.decode(await _collect(resp.read())),
        contains('not available'),
      );
    });

    test('404s with __404error.html body when the path is unknown', () async {
      await seedDartdoc('foo', {
        'index.html': 'root',
        '__404error.html': '<h1>not here</h1>',
      });
      final resp = await handler(
        req('documentation/foo/latest/bogus.html'),
        'foo',
        'latest',
        '/bogus.html',
      );
      expect(resp.statusCode, 404);
      expect(
        utf8.decode(await _collect(resp.read())),
        contains('not here'),
      );
    });

    test('redirects non-latest version segments to latest', () async {
      final resp = await handler(
        req('documentation/foo/1.2.3/readme.html'),
        'foo',
        '1.2.3',
        '/readme.html',
      );
      expect(resp.statusCode, 302);
      expect(resp.headers['location'], '/documentation/foo/latest/readme.html');
    });

    test('serves gzip when client accepts it', () async {
      await seedDartdoc('foo', {'index.html': 'gzip-me'});
      final resp = await handler(
        req(
          'documentation/foo/latest/',
          headers: {'accept-encoding': 'gzip, deflate'},
        ),
        'foo',
        'latest',
        '/',
      );
      expect(resp.statusCode, 200);
      expect(resp.headers['content-encoding'], 'gzip');
      final bytes = await _collect(resp.read());
      expect(utf8.decode(gzip.decode(bytes)), 'gzip-me');
    });

    test('returns plain bytes when client does not accept gzip', () async {
      await seedDartdoc('foo', {'index.html': 'plain-me'});
      final resp = await handler(
        req('documentation/foo/latest/'),
        'foo',
        'latest',
        '/',
      );
      expect(resp.statusCode, 200);
      expect(resp.headers['content-encoding'], isNull);
      expect(
        utf8.decode(await _collect(resp.read())),
        'plain-me',
      );
    });

    test('caches index bytes across requests', () async {
      await seedDartdoc('foo', {'index.html': 'a'});
      await handler(
        req('documentation/foo/latest/'),
        'foo',
        'latest',
        '/',
      );
      final indexGets = blobStore.getCountFor('foo/dartdoc/latest/index.json');

      // Second request: should be served from the cached index.
      await handler(
        req('documentation/foo/latest/'),
        'foo',
        'latest',
        '/',
      );
      expect(
        blobStore.getCountFor('foo/dartdoc/latest/index.json'),
        indexGets,
        reason: 'index.json should be fetched at most once',
      );
    });

    test('rejects unknown file extensions', () async {
      await seedDartdoc('foo', {
        'index.html': 'root',
        'sus.bin': 'binary junk',
      });
      final resp = await handler(
        req('documentation/foo/latest/sus.bin'),
        'foo',
        'latest',
        '/sus.bin',
      );
      expect(resp.statusCode, 404);
    });
  });
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final buf = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    buf.add(chunk);
  }
  return buf.toBytes();
}

/// Minimal in-memory BlobStore for tests. Only implements the asset
/// methods we actually need for the dartdoc handler; other methods
/// throw UnimplementedError so any accidental reliance fails loud.
final class _FakeBlobStore implements BlobStore {
  final Map<String, List<int>> assets = {};
  final Map<String, int> _getCounts = {};

  int getCountFor(String key) => _getCounts[key] ?? 0;

  @override
  Future<Stream<List<int>>> getAsset(String package, String assetKey) async {
    final k = '$package/$assetKey';
    _getCounts[k] = (_getCounts[k] ?? 0) + 1;
    final bytes = assets[k];
    if (bytes == null) {
      throw NotFoundException('Asset $assetKey for $package not found.');
    }
    return Stream.value(bytes);
  }

  @override
  Future<Stream<List<int>>> getAssetRange(
    String package,
    String assetKey,
    int offset,
    int length,
  ) async {
    final bytes = assets['$package/$assetKey'];
    if (bytes == null) {
      throw NotFoundException('Asset $assetKey for $package not found.');
    }
    final end = (offset + length).clamp(0, bytes.length);
    return Stream.value(bytes.sublist(offset, end));
  }

  @override
  Future<BlobInfo> put(
    String package,
    String version,
    Stream<List<int>> bytes, {
    bool overwrite = false,
  }) => throw UnimplementedError();

  @override
  Future<Stream<List<int>>> get(String package, String version) =>
      throw UnimplementedError();

  @override
  Future<BlobInfo?> info(String package, String version) =>
      throw UnimplementedError();

  @override
  Future<bool> exists(String package, String version) =>
      throw UnimplementedError();

  @override
  Future<void> delete(String package, String version) =>
      throw UnimplementedError();

  @override
  Future<List<String>> listVersions(String package) =>
      throw UnimplementedError();

  @override
  Future<List<String>> listPackages() => throw UnimplementedError();

  @override
  Future<Uri?> signedDownloadUrl(
    String package,
    String version, {
    Duration expiry = const Duration(hours: 1),
  }) => throw UnimplementedError();

  @override
  Future<BlobInfo> putAsset(
    String package,
    String assetKey,
    Stream<List<int>> bytes,
  ) => throw UnimplementedError();

  @override
  Future<BlobInfo?> assetInfo(String package, String assetKey) =>
      throw UnimplementedError();

  @override
  Future<void> deleteAssetsUnder(String package, String prefix) =>
      throw UnimplementedError();

  @override
  Future<void> deleteAsset(String package, String assetKey) =>
      throw UnimplementedError();

  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}
}
