/// Metadata about a stored blob.
class BlobInfo {
  const BlobInfo({
    required this.package,
    required this.version,
    required this.sizeBytes,
    required this.sha256Hex,
    required this.createdAt,
  });

  final String package;
  final String version;
  final int sizeBytes;
  final String sha256Hex;
  final DateTime createdAt;
}

/// Abstract interface for tarball binary storage.
///
/// Implementations: FilesystemBlobStore, S3BlobStore.
abstract interface class BlobStore {
  Future<void> open();
  Future<void> close();

  /// Store a tarball. Returns info about the stored blob.
  Future<BlobInfo> put(
    String package,
    String version,
    Stream<List<int>> bytes, {
    bool overwrite = false,
  });

  /// Stream the tarball bytes. Throws if absent.
  Future<Stream<List<int>>> get(String package, String version);

  /// Returns null if the blob does not exist.
  Future<BlobInfo?> info(String package, String version);

  /// Returns true if the blob exists.
  Future<bool> exists(String package, String version);

  /// Permanently delete a tarball.
  Future<void> delete(String package, String version);

  /// List all stored versions for a package.
  Future<List<String>> listVersions(String package);

  /// List all packages that have at least one stored blob.
  Future<List<String>> listPackages();

  /// Generate a pre-signed or direct download URL.
  /// Returns null if the backend does not support direct URLs
  /// (e.g., filesystem — must proxy through the server).
  Future<Uri?> signedDownloadUrl(
    String package,
    String version, {
    Duration expiry = const Duration(hours: 1),
  });

  // ── Per-package assets (screenshots, logos, etc.) ─────────────
  //
  // Generic key-value surface scoped under a package, separate from the
  // versioned tarball API above. [assetKey] is a relative POSIX path
  // (e.g. `screenshots/1.2.3/0.png`) — implementations MUST reject keys
  // containing `..` segments, leading `/`, or empty components.

  /// Store an asset. Overwrites any existing asset at the same key.
  Future<BlobInfo> putAsset(
    String package,
    String assetKey,
    Stream<List<int>> bytes,
  );

  /// Stream asset bytes. Throws [NotFoundException] if absent.
  Future<Stream<List<int>>> getAsset(String package, String assetKey);

  /// Stream a contiguous byte range of an asset. [offset] is inclusive,
  /// [length] is the number of bytes to read. Implementations clip to
  /// the actual object size when [offset] + [length] extends past EOF
  /// (they do not throw for over-reads; the returned stream simply
  /// emits fewer bytes).
  ///
  /// Intended for the indexed-blob dartdoc serving path: the worker
  /// uploads one `blob` object per package, the reader looks up file
  /// ranges via a sidecar index and fetches them one at a time.
  ///
  /// Backends:
  ///   - Filesystem: `RandomAccessFile.setPosition(offset) + read(length)`.
  ///   - S3: `GET` with `Range: bytes=offset-(offset+length-1)`.
  ///   - GCS: same, via the `Range:` header.
  ///
  /// Throws [NotFoundException] if the asset doesn't exist.
  /// Throws [ArgumentError] if [offset] or [length] is negative.
  Future<Stream<List<int>>> getAssetRange(
    String package,
    String assetKey,
    int offset,
    int length,
  );

  /// Returns null if the asset does not exist.
  Future<BlobInfo?> assetInfo(String package, String assetKey);

  /// Delete every asset whose key begins with [prefix]. No-op if the
  /// prefix matches nothing.
  Future<void> deleteAssetsUnder(String package, String prefix);

  /// Delete a single asset. No-op if the key does not resolve to a file.
  /// Used to evict tail entries on re-publish without nuking the whole
  /// prefix — safer against partial-write windows.
  Future<void> deleteAsset(String package, String assetKey);
}
