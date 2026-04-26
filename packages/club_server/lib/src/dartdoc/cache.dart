/// In-process cache layer for the dartdoc blob serve path.
///
/// Three things get cached today, all with the same `key → bytes` shape:
///
///   - `dartdoc:index:<pkg>` — the `index.json` bytes for a package's
///      indexed blob. Fetched once per package (until the next scoring
///      run invalidates it), parsed into a `BlobIndex` by the caller.
///      Typical size 10–500 KB.
///   - `dartdoc:range:<blobId>:<path>` — a specific file's byte range
///      within the blob. Only cached when the range is ≤ 1 MiB; larger
///      payloads stream straight through without caching to avoid
///      blowing the budget on a single asset.
///   - `dartdoc:html:<pkg>:<path>` — reserved for future use; unused
///      today because club skips the pub.dev JSON → HTML re-render and
///      serves HTML bytes as-is from the range cache.
///
/// The [InMemoryDartdocCache] is per-replica and volatile — it starts
/// cold on every server boot. That's fine for single-container
/// deployments; multi-replica / ephemeral-container setups should swap
/// in a shared-cache backend later (see docs/FUTURE_REDIS_CACHE.md).
library;

import 'dart:collection';
import 'dart:typed_data';

/// Byte-payload cache with a hard memory cap and LRU eviction.
///
/// Keys are strings; values are opaque byte lists. The cache enforces
/// its budget on [setBytes] by evicting least-recently-used entries
/// until the new payload fits. Very large payloads that exceed the
/// budget on their own are rejected (not cached) rather than
/// triggering a runaway eviction loop.
abstract interface class DartdocCache {
  /// Returns the cached bytes for [key], or null if absent.
  ///
  /// On a hit, the entry is promoted to most-recently-used.
  Future<Uint8List?> getBytes(String key);

  /// Store [value] under [key]. A prior entry is replaced and the
  /// budget is rebalanced. Over-budget values are silently dropped
  /// (they'd always evict everything else on insertion, so the cache
  /// refuses to churn for them).
  Future<void> setBytes(String key, List<int> value);

  /// Remove the entry under [key]. No-op if absent.
  Future<void> invalidate(String key);

  /// Remove every entry whose key begins with [prefix]. Intended for
  /// invalidating a package's whole footprint on re-score
  /// (`dartdoc:index:<pkg>` + any cached range entries keyed on the
  /// package's old blobId).
  Future<void> invalidatePrefix(String prefix);

  /// Current total of cached payload bytes. Reported for diagnostics.
  int get sizeBytes;

  /// Number of entries currently held.
  int get entryCount;
}

/// In-process LRU implementation. Thread-safety is trivial in a single-
/// isolate Dart server; all mutations run on the event loop.
final class InMemoryDartdocCache implements DartdocCache {
  InMemoryDartdocCache({required int maxMemoryBytes})
    : assert(maxMemoryBytes > 0),
      _maxMemoryBytes = maxMemoryBytes;

  final int _maxMemoryBytes;
  final LinkedHashMap<String, Uint8List> _entries =
      LinkedHashMap<String, Uint8List>();
  int _sizeBytes = 0;

  @override
  int get sizeBytes => _sizeBytes;

  @override
  int get entryCount => _entries.length;

  @override
  Future<Uint8List?> getBytes(String key) async {
    final value = _entries.remove(key);
    if (value == null) return null;
    // Re-insert moves the key to the end of the iteration order, which
    // this class uses as MRU. `remove` + put is the documented idiom
    // for LinkedHashMap-based LRU.
    _entries[key] = value;
    return value;
  }

  @override
  Future<void> setBytes(String key, List<int> value) async {
    final bytes = value is Uint8List ? value : Uint8List.fromList(value);
    if (bytes.length > _maxMemoryBytes) {
      // A single entry bigger than the whole budget would force us to
      // evict every other entry and still not fit. Refuse gracefully;
      // the caller will just miss on this key every time, which is
      // strictly better than churning the rest of the cache.
      return;
    }
    final prior = _entries.remove(key);
    if (prior != null) _sizeBytes -= prior.length;
    while (_sizeBytes + bytes.length > _maxMemoryBytes && _entries.isNotEmpty) {
      final evictedKey = _entries.keys.first;
      final evicted = _entries.remove(evictedKey)!;
      _sizeBytes -= evicted.length;
    }
    _entries[key] = bytes;
    _sizeBytes += bytes.length;
  }

  @override
  Future<void> invalidate(String key) async {
    final prior = _entries.remove(key);
    if (prior != null) _sizeBytes -= prior.length;
  }

  @override
  Future<void> invalidatePrefix(String prefix) async {
    final victims = _entries.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in victims) {
      await invalidate(k);
    }
  }
}

/// Key builders. Centralised so the Redis swap-in (see
/// `docs/FUTURE_REDIS_CACHE.md`) can reuse the exact same strings
/// pub.dev does, making cache-invalidation logic portable.
abstract final class DartdocCacheKeys {
  /// Cache key for a package's `index.json` bytes.
  static String index(String package) => 'dartdoc:index:$package';

  /// Cache key for a specific file's raw bytes within an indexed blob.
  /// Keyed on [blobId] (not package) so a re-scored package's new
  /// blob doesn't collide with stale range entries — the old blobId
  /// simply falls out under LRU pressure.
  static String range(String blobId, String path) =>
      'dartdoc:range:$blobId:$path';

  /// Per-package prefix used by [DartdocCache.invalidatePrefix] to
  /// evict a package's index (range entries age out on their own).
  static String packagePrefix(String package) => 'dartdoc:index:$package';
}
