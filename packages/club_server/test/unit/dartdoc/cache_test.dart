import 'dart:typed_data';

import 'package:club_server/src/dartdoc/cache.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryDartdocCache', () {
    test('stores and retrieves bytes', () async {
      final cache = InMemoryDartdocCache(maxMemoryBytes: 1024);
      await cache.setBytes('k1', [1, 2, 3]);
      final got = await cache.getBytes('k1');
      expect(got, isNotNull);
      expect(got, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('returns null for missing keys', () async {
      final cache = InMemoryDartdocCache(maxMemoryBytes: 1024);
      expect(await cache.getBytes('missing'), isNull);
    });

    test('enforces memory cap via LRU eviction', () async {
      // Budget big enough for two 100-byte entries; the third forces
      // one of the first two out.
      final cache = InMemoryDartdocCache(maxMemoryBytes: 250);
      await cache.setBytes('a', List.filled(100, 0xaa));
      await cache.setBytes('b', List.filled(100, 0xbb));
      expect(cache.entryCount, 2);

      // Touch 'a' so 'b' becomes LRU.
      await cache.getBytes('a');
      await cache.setBytes('c', List.filled(100, 0xcc));

      expect(await cache.getBytes('b'), isNull, reason: 'b should be evicted');
      expect(await cache.getBytes('a'), isNotNull);
      expect(await cache.getBytes('c'), isNotNull);
    });

    test('replacing an entry rebalances the budget', () async {
      final cache = InMemoryDartdocCache(maxMemoryBytes: 250);
      await cache.setBytes('a', List.filled(100, 0xaa));
      await cache.setBytes('a', List.filled(200, 0xbb));
      expect(cache.sizeBytes, 200);
      expect(cache.entryCount, 1);
    });

    test('refuses entries larger than the whole budget', () async {
      // Avoids a runaway eviction loop for a single oversized entry.
      final cache = InMemoryDartdocCache(maxMemoryBytes: 100);
      await cache.setBytes('a', List.filled(50, 0xaa));
      await cache.setBytes('too-big', List.filled(500, 0xbb));

      expect(await cache.getBytes('too-big'), isNull);
      expect(
        await cache.getBytes('a'),
        isNotNull,
        reason: 'existing entry must not be evicted by the refused insert',
      );
    });

    test('invalidate removes the entry and releases budget', () async {
      final cache = InMemoryDartdocCache(maxMemoryBytes: 1024);
      await cache.setBytes('a', List.filled(100, 0));
      await cache.invalidate('a');
      expect(await cache.getBytes('a'), isNull);
      expect(cache.sizeBytes, 0);
    });

    test('invalidatePrefix removes every matching entry', () async {
      final cache = InMemoryDartdocCache(maxMemoryBytes: 1024);
      await cache.setBytes('dartdoc:index:foo', [1]);
      await cache.setBytes('dartdoc:index:bar', [2]);
      await cache.setBytes('dartdoc:range:xyz:readme.html', [3]);

      await cache.invalidatePrefix('dartdoc:index:');

      expect(await cache.getBytes('dartdoc:index:foo'), isNull);
      expect(await cache.getBytes('dartdoc:index:bar'), isNull);
      expect(await cache.getBytes('dartdoc:range:xyz:readme.html'), isNotNull);
    });

    test(
      'get on a present key promotes it (so it survives eviction pressure)',
      () async {
        final cache = InMemoryDartdocCache(maxMemoryBytes: 250);
        await cache.setBytes('a', List.filled(100, 0));
        await cache.setBytes('b', List.filled(100, 0));
        // Access 'a' — promotes to MRU. 'b' is now LRU.
        await cache.getBytes('a');
        await cache.setBytes('c', List.filled(100, 0));

        expect(await cache.getBytes('b'), isNull);
        expect(await cache.getBytes('a'), isNotNull);
      },
    );
  });

  group('DartdocCacheKeys', () {
    test('index key shape', () {
      expect(DartdocCacheKeys.index('foo'), 'dartdoc:index:foo');
    });

    test('range key shape', () {
      expect(
        DartdocCacheKeys.range('blob-abc', 'api/Thing-class.html'),
        'dartdoc:range:blob-abc:api/Thing-class.html',
      );
    });

    test('packagePrefix matches the index key shape', () {
      // Ensures invalidatePrefix(packagePrefix(pkg)) wipes the index.
      final pkg = 'some_pkg';
      final indexKey = DartdocCacheKeys.index(pkg);
      final prefix = DartdocCacheKeys.packagePrefix(pkg);
      expect(indexKey.startsWith(prefix), isTrue);
    });
  });
}
