# Plan: dartdoc serving via blob storage (opt-in)

**Status**: Planned. Implementation deferred.

**Companion doc**: [FUTURE_REDIS_CACHE.md](FUTURE_REDIS_CACHE.md) — the Redis tier sits on top of this work once we need cross-replica caching.

## Goal

Support two dartdoc storage modes behind a single config switch:

- **`filesystem`** (default): today's behaviour. dartdoc HTML tree lives at `<DARTDOC_PATH>/<pkg>/latest/`, served directly by `shelf_static`. Zero blob-store involvement. Best for single-container / self-hosted deployments on persistent `/data` volumes.
- **`blob`** (opt-in): dartdoc is packed into an indexed blob in the BlobStore under `<pkg>/dartdoc/latest/...`. Server reads byte ranges per request with an in-memory LRU in front. Works with any blob backend (filesystem, S3, GCS) and survives ephemeral containers and multi-replica deployments.

The default must do nothing new — existing deployments on `DARTDOC_BACKEND=filesystem` keep working unchanged.

## Non-goals

- **No per-version dartdoc.** We only ever store and serve docs for the current latest version. Older versions have no dartdoc. When a new version becomes latest, its dartdoc overwrites `<pkg>/dartdoc/latest/` in place.
- **No JSON → HTML re-render.** Worker output is served as-is. club is a private/trusted-input registry; we run `dart doc` ourselves on code we chose to ingest. XSS hardening via template re-render (pub.dev's approach) is unnecessary complexity for this threat model.
- **No Redis in this phase.** In-process LRU per replica. See the companion doc for when to add Redis.
- **No CDN in this phase.** Possible follow-up.

## Config surface

One new env var:

| Var | Values | Default | Purpose |
|---|---|---|---|
| `DARTDOC_BACKEND` | `filesystem` \| `blob` | `filesystem` | Where dartdoc output lives + how it's served. |

Matches the existing `*_BACKEND` pattern (`DB_BACKEND`, `BLOB_BACKEND`, `SEARCH_BACKEND`). No behaviour change unless the operator explicitly flips it to `blob`.

Existing `DARTDOC_PATH` stays meaningful in `filesystem` mode (default `/data/cache/dartdoc`). In `blob` mode it's ignored.

In-memory cache knobs — see `FUTURE_REDIS_CACHE.md` for full detail; for this phase we need just one:

| Var | Default | Purpose |
|---|---|---|
| `DARTDOC_CACHE_MAX_MEMORY_MB` | `64` | Cap on the in-memory LRU. Bytes stored are post-decompression HTML / JSON / image data. |

## Storage layout

### `DARTDOC_BACKEND=filesystem` (unchanged)

```
/data/cache/dartdoc/<pkg>/latest/        ← full dartdoc HTML tree
  index.html
  __404error.html
  <pkg>/…
  static-assets/…
```

Scoring worker writes the tree with `dart doc`; router's `shelf_static` serves it. No indexed blob, no LRU (the OS page cache handles it).

### `DARTDOC_BACKEND=blob`

```
<BlobStore>/<pkg>/dartdoc/latest/
  blob           ← concatenated, each file gzipped individually
  index.json     ← { <path>: { start, end, blobId: "blob" } }
```

- **`index.json`** is a flat map of dartdoc file paths to byte ranges within `blob`. Small (typically 10–500 KB for a package).
- **`blob`** is a single opaque concatenation. Each file gzipped before concatenation, so byte-range responses can be served with `Content-Encoding: gzip` if the client accepts it, or decompressed server-side otherwise.

Same format pub.dev uses (`pkg/indexed_blob` in the research tree). We vendor that library verbatim.

Writer uploads both via `blobStore.putAsset(pkg, 'dartdoc/latest/index.json', ...)` and `putAsset(pkg, 'dartdoc/latest/blob', ...)`. Reader uses a new byte-range method on BlobStore (below).

## BlobStore interface change: byte-range reads

New method on `BlobStore`:

```dart
/// Stream a byte range of an asset. [length] may extend past EOF;
/// implementations clip to the actual size.
Future<Stream<List<int>>> getAssetRange(
  String package,
  String assetKey,
  int offset,
  int length,
);
```

Implementations:

- **FilesystemBlobStore** — `RandomAccessFile.read()` after seeking. Trivial.
- **S3BlobStore** — `getObject` with `Range: bytes=offset-(offset+length-1)` header. Minio client supports this via the `offset` / `length` parameters.
- **GcsBlobStore** — same, via `Range` header on the Objects.get call (the `downloadOptions` partial-content mode accepts a byte range).

Existing `getAsset` stays for whole-object reads (screenshots and anything that doesn't need slicing).

## Worker changes

Two switches in `ScoringService` / `ScoringWorker`:

1. **Latest-only gate.** Before enqueueing dartdoc generation: skip if the version being scored is not the package's latest. Existing scoring (pana report) still runs for all versions — we want scores for old releases. Only dartdoc is gated.

```dart
final latestVersion = await _packageService.latestStable(queued.packageName);
final shouldGenerateDartdoc = dartdocEnabled
  && queued.version == latestVersion;
final jobDartdocOutputDir = shouldGenerateDartdoc
  ? '<scratch>/<pkg>/latest'
  : null;
```

2. **Persist path depends on `DARTDOC_BACKEND`.**

```
case filesystem:
  rsync <scratch>/<pkg>/latest/ → <DARTDOC_PATH>/<pkg>/latest/
  (same as today)

case blob:
  indexedBlob = IndexedBlobBuilder(...)
  for file in <scratch>/<pkg>/latest/:
    indexedBlob.add(file.relativePath, file.bytes)
  index = indexedBlob.buildIndex('dartdoc/latest/blob')
  blobStore.putAsset(pkg, 'dartdoc/latest/index.json', index.toJson)
  blobStore.putAsset(pkg, 'dartdoc/latest/blob', <scratch blob>)
```

### Race: new version published while scoring an older one

Two versions published in quick succession (v1.0 then v1.1):

- v1.0 scoring starts → checks latest → sees v1.0 is latest → will generate dartdoc
- v1.1 gets published while v1.0 scoring is still in-flight → latest flips to v1.1
- v1.0 scoring finishes → its output overwrites `<pkg>/dartdoc/latest/` on disk or in blob
- v1.1 scoring eventually finishes → overwrites again with v1.1 docs

Result: a short window where `<pkg>/dartdoc/latest` shows v1.0 docs even though latest is v1.1. Self-corrects on v1.1 scoring.

Mitigation (worth doing): at write time, re-check the current latest version. If this job's version is no longer latest, abandon the write. One more DB read, cheap, prevents the stale-latest-docs window entirely.

## Router changes

```
// Pseudocode
if (DARTDOC_BACKEND == filesystem) {
  // Existing path — createStaticHandler(dartdocPath), prefix-rewrite.
  useShelfStatic();
} else {
  useBlobDartdocHandler(blobStore, cache);
}
```

`blobDartdocHandler(pkg, path)`:

1. `resolvedVersion` = `latest` (hardcoded — we only store docs for latest).
2. `index` = `cache.getOrFetch('dartdoc:index:$pkg', () async { bytes = blobStore.getAsset(pkg, 'dartdoc/latest/index.json'); return BlobIndex.fromBytes(bytes); })`.
3. `range` = `index.lookup(path)`. If null → 404.
4. `bytes` = `cache.getOrFetch('dartdoc:range:${index.blobId}:$path', () async { return blobStore.getAssetRange(pkg, 'dartdoc/latest/blob', range.start, range.length); })`.
   - Only cache when `length <= 1 MB`; for bigger assets stream directly without caching.
5. Return `shelf.Response.ok(bytes, headers: { ... })`.
   - `Content-Type` from extension lookup (safelist: html, css, js, svg, png, jpg, gif, webp, json, ico).
   - `Content-Encoding: gzip` when the body is gzip-encoded *and* the client accepts it (check `Accept-Encoding`). Otherwise server-side `gzip.decode`.
   - `Vary: Accept-Encoding`.
   - `Cache-Control: public, max-age=300` — short TTL, re-publish cycle is fast.
6. On any cache miss or exception, bypass the cache and go direct. Cache is strictly performance.

Return 404 with a friendly body when `index.json` is absent ("dartdoc not yet generated, scoring is running"), matching the existing UX.

## In-memory LRU

One shared instance per server process. Bounded by `DARTDOC_CACHE_MAX_MEMORY_MB` (default 64 MB) via payload-size accounting, not entry count. Keys follow pub.dev's naming so they port straight to Redis later:

- `dartdoc:resolve:<pkg>` → not needed here (latest-only; `resolvedVersion` is literal `latest`).
- `dartdoc:index:<pkg>` — parsed BlobIndex.
- `dartdoc:range:<blobId>:<path>` — raw byte-range bytes (≤ 1 MB).

No status/page bytes tier (those are pub.dev JSON-render artefacts; we skipped re-render).

Use a simple `LinkedHashMap`-based LRU with `moveToEnd` on access + byte-size accounting on write. Dart has `dart_collection` and `basics` packages; we can also roll our own in ~80 lines.

## Invalidation

When a new scoring job completes and writes a new dartdoc blob for `<pkg>`:

```
cache.invalidate('dartdoc:index:<pkg>');
// No need to purge dartdoc:range:* — those are keyed by blobId which is
// stable within a blob, and the new blob has a new implicit identity
// (next fetch reparses the new index.json, which points at the new blob).
```

Even simpler than pub.dev's version-keyed invalidation because we only ever have one dartdoc per package.

## Security notes

- **XSS**: we serve raw HTML from the worker. The worker runs inside the scoring sandbox (`SandboxConfig.fromEnv`), not arbitrary user code on the server. club's threat model treats dartdoc output as trusted-ish (it's generated by `dart doc` on packages the operator chose to ingest). Re-render-from-JSON is pub.dev's hardening against public-registry hostile input; it's overkill here.
- **Asset MIME safelist**: still apply the safelist from pub.dev's `_safeMimeTypes`. Unknown extensions → 404. Prevents the handler from being abused to serve arbitrary file types if a package ever injected e.g. `.bin` files into its doc tree.
- **Byte-range bounds**: all ranges are looked up through the BlobIndex, which is itself verified (`blobId` must match the expected pattern and start with the prefix for this package). Rules out cross-package or cross-tenant reads.

## Migration for existing deployments

- Operators on `filesystem` (the default): no action. Their current setup keeps working. dartdoc keeps being generated into `/data/cache/dartdoc/`, served by `shelf_static`.
- Operators who flip to `blob`: on the next scoring completion, dartdoc starts going to the blob store. The local `/data/cache/dartdoc/` tree becomes stale but harmless — the router stops reading it. Operators can `rm -rf /data/cache/dartdoc/` after confirming.
- Operators on multi-replica S3 today (broken state): flipping to `blob` fixes it.

No schema migration. No data migration. Just config + new code paths.

## Implementation order

Each step is independently mergeable and leaves the tree shippable.

1. **Vendor `pkg/indexed_blob`** from the research tree into `packages/club_indexed_blob/` (new workspace package). Keep its public API, add tests as-is.
2. **Add `BlobStore.getAssetRange`** to the interface + all three implementations (filesystem, S3, GCS). Unit tests for each: read-range, end-of-file clipping, invalid offset.
3. **Add `DartdocBackend` enum to `AppConfig`** + `DARTDOC_BACKEND` env-var parsing. Default `filesystem`. Test parsing.
4. **Worker: latest-only gate.** Skip dartdoc step when version != latest. Unit test via fake `PackageService`.
5. **Worker: blob-mode writer.** When `DARTDOC_BACKEND=blob`, build indexed blob + upload. Integration test using an in-memory BlobStore.
6. **Server: `DartdocCache` interface + `InMemoryDartdocCache` impl.** ~150 lines. Unit tests for LRU eviction, byte-size accounting, invalidation.
7. **Server: new `blobDartdocHandler`.** Wire into router behind the `DARTDOC_BACKEND` switch. Integration test: put indexed blob into filesystem BlobStore, request various paths, verify bytes + headers.
8. **`docker/.env.example` + `docs/CONFIGURATION.md` + `docs/SELF_HOSTING.md`** — document the new env var and mode trade-offs.

Estimated effort: **2–3 days** for steps 1–7 plus tests. Step 8 an hour.

## What this unblocks / doesn't

**Unblocks:**
- S3/GCS blob backend for dartdoc (currently incompatible with remote storage).
- Ephemeral containers (Cloud Run etc.) where `/data/cache/dartdoc/` doesn't survive.
- Multi-replica deployments — any replica can serve any package.
- Future CDN fronting — the byte-range paths are cache-friendly HTTP GETs that can live behind CloudFront / Cloudflare.

**Doesn't unblock / doesn't change:**
- Single-replica persistent-volume deployments — no behavioural change, no perf change.
- The Redis requirement if you ever go to many replicas with cold starts — see the companion doc.
- Older-version dartdoc — explicitly out of scope; latest is the only version with docs.

## Decision record

- **Filesystem default, blob opt-in**: keeps simple deployments simple, makes S3/GCS viable without forcing the rewrite on everyone.
- **Latest-only**: halves the storage footprint (no `1.0/`, `1.1/`, `1.2/` trees) and simplifies the cache key space. Older-version docs were never a promised feature; clarifying that.
- **No JSON re-render**: private-registry threat model. Keep the codebase small.
- **In-memory LRU first, Redis later**: matches current deployment scale. Clean upgrade path documented.
