# Future plan: Redis-backed dartdoc cache

**Status**: Deferred. In-memory LRU is sufficient for current scale.

**When to revisit**: When one of the following becomes true:
- Deploy cold-start load on the blob store exceeds a threshold (noticeable elevated egress / GET costs after every deploy).
- Server needs to scale horizontally (multiple replicas behind a load balancer or container orchestrator) and per-replica cache warming becomes a real cost.
- Container runtime is ephemeral (Cloud Run, scale-to-zero) and replicas churn frequently.

## Why Redis, specifically

The dartdoc serving stack (indexed blob + byte-range reads, adapted from pub.dev) needs a fast key-value cache for five distinct read paths:

1. **`resolvedDocUrlVersion(pkg, ver)`** — `latest` → actual completed version. Small (~50 bytes). Short TTL.
2. **`taskResultIndex(pkg, ver)`** — parsed `BlobIndex` (path → byte range map). ~10–500 KB. Medium TTL.
3. **`dartdocPageStatus(pkg, ver, path)`** — redirect / missing / ok verdict for a single page. ~100 bytes.
4. **`dartdocHtmlBytes(pkg, ver, path)`** — rendered HTML bytes after `DartDocPage.render()`. ~10–200 KB.
5. **`gzippedTaskResult(blobId, path)`** — raw byte-range response bytes when ≤ 1 MB. ~1 KB–1 MB.

pub.dev uses Redis for all five. club's in-memory LRU does the same job per-replica; Redis promotes it to cross-replica and cross-restart.

## What Redis buys over in-memory LRU

| | In-memory LRU | Sidecar Redis |
|---|---|---|
| Single-replica hot-path latency | ~100 ns | ~0.3 ms over loopback |
| Survives server restart / redeploy | ❌ | ✅ |
| Shared across replicas | ❌ | ✅ |
| Thundering-herd suppression (atomic SETNX) | within one process only | cross-process |
| Cost (RAM) | ~200 MB per replica | ~256 MB total (shared) |
| Cost (dollars) | $0 | $0 for sidecar; ~$15/mo for managed |

The one that actually matters at club's likely scale: **surviving server restart/deploy.** Every `docker compose up server` today drops the cache; sidecar Redis holds it for the next container.

## Deployment shape: sidecar in docker-compose

Drop-in addition to `docker/docker-compose.yml`:

```yaml
services:
  server:
    image: club
    depends_on:
      redis:
        condition: service_healthy
    environment:
      - REDIS_URL=redis://redis:6379
    volumes:
      - club_data:/data

  redis:
    image: redis:7-alpine
    command: >-
      redis-server
      --maxmemory 256mb
      --maxmemory-policy allkeys-lru
      --save ""
      --appendonly no
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5
    # No `ports:` — only reachable via the compose network.

volumes:
  club_data:
```

Rationale for the flags:

- **`--save "" --appendonly no`** — pure in-memory. No RDB snapshots, no AOF. Zero disk I/O. Since every cached value is derivable from the blob store, durability is unnecessary.
- **`--maxmemory 256mb` + `--maxmemory-policy allkeys-lru`** — bounded memory, LRU eviction across the whole keyspace. Matches pub.dev's usage.
- **No `ports:` exposure** — Redis is only reachable from the server container via compose's private network. Prevents accidental public exposure (Redis has no auth by default).
- **Healthcheck + `depends_on: service_healthy`** — server waits for Redis to accept PINGs before starting. Still works if Redis goes down mid-run thanks to degraded-mode (below).

## Implementation contract

Introduce a `DartdocCache` interface with pluggable backends:

```dart
abstract interface class DartdocCache {
  Future<List<int>?> getBytes(String key);
  Future<void> setBytes(String key, List<int> value, {required Duration ttl});
  Future<void> invalidate(String key);
  Future<void> invalidatePrefix(String prefix);
}
```

Backends:

1. **`InMemoryDartdocCache`** — LRU-bounded, per-replica. Default when `REDIS_URL` is unset. This is what club ships today.
2. **`RedisDartdocCache`** — used when `REDIS_URL` is set. Behaves identically from the caller's perspective.
3. **`TieredDartdocCache`** (optional) — wraps both: small L1 in-memory (~10 MB) in front of L2 Redis. Absorbs the ~0.3 ms Redis RTT for hot keys. pub.dev effectively does this via request-local caching.

### Degraded-mode rules (non-negotiable)

Redis must never be a correctness dependency. Only a performance one.

- **Unreachable at boot**: log a warning, fall back to `InMemoryDartdocCache` for the process lifetime. Don't refuse to start.
- **Errors mid-request**: log, skip the cache layer for that call, go straight to the blob store. Don't propagate the error.
- **Reconnects**: transparent, driven by the client library's reconnect logic. No code in the hot path cares.

This lets operators run `docker compose stop redis` to investigate without taking the server down. Also means local dev / CI / single-container deployments can skip Redis entirely.

## Key naming and TTLs

Mirror pub.dev's naming so cache-invalidation logic (on re-publish, on force-republish, on dartdoc regeneration) ports cleanly later:

| Key | TTL | Purpose |
|---|---|---|
| `dartdoc:resolve:{pkg}:{ver}` | 10 min | `latest` → actual completed version |
| `dartdoc:index:{pkg}:{ver}` | 1 h | Parsed `BlobIndex` |
| `dartdoc:status:{pkg}:{ver}:{path}` | 1 h | Page verdict (ok / redirect / missing) |
| `dartdoc:page:{pkg}:{ver}:{path}` | 1 h | Rendered HTML bytes |
| `dartdoc:range:{blobId}:{path}` | 1 h | Raw byte-range bytes (≤ 1 MB) |

Invalidation is narrow:

- **On scoring complete for `(pkg, ver)`**: `DEL dartdoc:index:{pkg}:{ver}`, plus prefix scan `DEL dartdoc:page:{pkg}:{ver}:*`, `DEL dartdoc:status:{pkg}:{ver}:*`.
- **On package retract / delete**: same prefix scan, plus the resolve key.

For long TTLs (1 h) and explicit invalidation, this is safe against stale reads.

## Config surface

New env vars (all optional):

| Var | Default | Meaning |
|---|---|---|
| `REDIS_URL` | unset | e.g. `redis://redis:6379`. When unset, falls back to in-memory. |
| `DARTDOC_CACHE_MAX_MEMORY_MB` | `64` | In-memory cache cap (used when Redis is off, or as L1 when tiered). |
| `DARTDOC_CACHE_TTL_SECONDS` | `3600` | Default TTL applied to all entries. |

These do not change the existing config surface; they slot in alongside the path defaults defined during the `/data` reorg.

## Implementation checklist (for when this is picked up)

1. Pick a Dart Redis client. Candidates: [`package:redis`](https://pub.dev/packages/redis) (minimal RESP), [`package:redis_client`](https://pub.dev/packages/redis_client). Or vendor a ~300-line RESP impl for zero-dep control. pub.dev vendors their own; worth cross-reading `pkg/pub_server_redis/` (if present) in the research tree.
2. Add `DartdocCache` interface in `packages/club_server/lib/src/dartdoc/cache.dart`.
3. Implement `InMemoryDartdocCache` (~150 lines).
4. Implement `RedisDartdocCache` (~200–400 lines depending on client choice).
5. Wire into `bootstrap.dart`: read `REDIS_URL`, pick backend, inject into the dartdoc handler.
6. Update the dartdoc serving code path (already using indexed blob + byte-range reads) to consult the cache.
7. Add the Redis service to `docker/docker-compose.yml` (snippet above).
8. Add `# REDIS_URL=redis://redis:6379` to `docker/.env.example` with a one-line comment: "Optional cache. Without it, each server replica maintains its own in-memory LRU."
9. Add a section to `docs/SELF_HOSTING.md` covering:
   - Redis is optional and acts purely as a cache.
   - Losing Redis doesn't lose data.
   - Redis survives server deploys; an in-memory cache does not.
   - Enable it when you deploy multiple replicas or your cold-start blob-store traffic starts costing you.

Total effort estimate: **1–2 days** on top of the indexed-blob serving rewrite. Main risk is picking a Redis client that's robust enough — vendoring a minimal RESP impl is the conservative fallback.

## What "good enough without Redis" looks like

Until the tripwire conditions at the top of this doc fire, in-memory LRU covers ~95% of the Redis benefit:

- Hot-page latency: indistinguishable (both sub-ms, in-memory is actually slightly faster).
- Per-replica memory cost: ~200 MB for a generous cap. Trivial on any real server.
- Cold start after deploy: ~1 minute of elevated blob-store GETs until the LRU warms. At modest dartdoc traffic (say 50 req/s), maybe 100 extra GETs during warm-up. Noise.

The specific case that flips this verdict is **multi-replica deployment**. As soon as there are two or more server containers serving dartdoc from independent in-memory LRUs, the aggregate cold-start traffic multiplies. That's the moment to wire Redis in.
