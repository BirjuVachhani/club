# club — Publisher Verification

Publishers in club come in two flavours:

- **Verified** — id is a domain (`hyperdesigned.dev`). The creator
  proved control by placing a DNS TXT record. Self-service, any
  authenticated member+ user can start a verification.
- **Internal** — id is an arbitrary slug (`our-team`, no dots). Only
  admins create these. Used for teams without a public domain, legacy
  groupings, and pre-verification bootstraps.

The two namespaces can never collide: the presence/absence of a dot in
the id is the partition. Internal slugs are regex-gated to
`^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$` — no dots, ever.

---

## DNS verification flow

The user proves control of a domain by adding a TXT record on a
`_club-verify.<domain>` subdomain. We probe the record via
DNS-over-HTTPS on two providers (Cloudflare + Google) and require
both to agree before marking the publisher verified.

### Sequence

```
Client                      Server                        DNS
  │                           │                            │
  │ POST /verify/start        │                            │
  │ { domain, displayName }   │                            │
  ├──────────────────────────▶│                            │
  │                           │ generate random token      │
  │                           │ store SHA-256(token) with  │
  │                           │ (user_id, domain) UNIQUE   │
  │ { host, value, token }    │                            │
  │◀──────────────────────────┤                            │
  │                           │                            │
  │ — user adds TXT record —  │                            │
  │                           │                            │
  │ POST /verify/complete     │                            │
  │ { domain, displayName }   │                            │
  ├──────────────────────────▶│                            │
  │                           │ GET _club-verify.<domain>  │
  │                           │ TXT via DoH ×2             │
  │                           ├───────────────────────────▶│
  │                           │                            │
  │                           │ check intersection of      │
  │                           │ resolvers' responses for   │
  │                           │ "club-verify=<token>"      │
  │                           │                            │
  │                           │ atomically:                │
  │                           │   - CREATE publisher with  │
  │                           │     verified=true          │
  │                           │   - add user as admin      │
  │                           │   - DELETE pending row     │
  │                           │   - emit publisher.verified│
  │                           │     audit log              │
  │ { publisherId, verified } │                            │
  │◀──────────────────────────┤                            │
```

### Record format

| Field | Value |
|---|---|
| Host | `_club-verify.<domain>` |
| Type | `TXT` |
| Value | `club-verify=<token>` |

`_`-prefixed subdomain instead of apex to avoid colliding with SPF /
DKIM / DMARC records which also live at the apex.

Token is ~43 chars of base64url-encoded random (32 bytes of entropy).
Stored hashed; the raw value exists only in the user's browser session
and whatever they paste into their DNS provider.

### DoH providers and strict mode

`DualDohResolver` in `packages/club_server/lib/src/auth/dns_resolver.dart`
queries both providers in parallel:

- Cloudflare `https://cloudflare-dns.com/dns-query`
- Google `https://dns.google/resolve`

Both receive the same `name` + `type=TXT` query. Strict mode (default)
requires the record to appear in **both** responses before it's
considered valid. This defends against single-resolver poisoning and
transient one-off propagation blips. If either provider is unreachable
the call fails with a temporary error and the UI retries.

A permissive mode (`requireBothProviders: false`) is available for
deployments where one provider is blocked; it accepts the union of
responses.

### Token lifecycle

- **TTL**: `VERIFICATION_TOKEN_TTL_HOURS` env var, default 24. Must be
  long enough to survive enterprise DNS propagation which can be
  hours. Shorter values frustrate users for no real security gain —
  the token is single-use and only grants control of one specific
  domain.
- **Re-use**: calling `/verify/start` again for the same
  `(user_id, domain)` overwrites the prior pending row via SQL
  `ON CONFLICT DO UPDATE`. Users can restart the flow cleanly if
  they lose the token or want a fresh expiry window.
- **Single-use**: successful completion deletes the pending row. A
  fresh start is required to re-verify.
- **Expiry cleanup**: `deleteExpiredVerifications()` exists on the
  store and can be wired to a cron. Not currently scheduled because
  upsert-on-start already replaces stale rows in practice.

### Verification is one-shot, not periodic

Once a publisher is verified, it stays verified until it's deleted.
There is no background job that re-probes the TXT record, and the
`verified` flag never flips back to `false` on its own.

**Rationale.** In a private self-hosted registry, the verified badge
is a *display signal*, not a security boundary. Who can publish to
a publisher's packages is governed by `publisher_members` — the
people, not the DNS. The domain could evaporate entirely and the
legitimate publisher admins would still be the same people holding
the keys. Periodically re-probing DNS only answers the question
"does the ✓ still accurately represent current domain ownership?",
which matters a lot for public registries with reputation signals
(pub.dev, npm) and much less for a team tool where the members list
is the authority.

Periodic re-verification would also introduce a state machine
(verified → lapsed → unverified, grace windows, transient-failure
handling), a cron, and in-UI notifications — a meaningful amount of
surface area for marginal value in our threat model.

**What happens if a domain really changes hands.** Manual path,
intentional:

1. The new owner contacts a server admin.
2. The existing publisher admins transfer or clear their packages
   (publisher deletion is blocked while packages still reference it).
3. A server admin deletes the old publisher via
   `DELETE /api/publishers/<id>`.
4. The new owner runs `/verify/start` for the now-free domain.

This is a few manual steps but it's an infrequent operation, and
the manual review is a feature — it stops a lapsed TXT record from
silently handing ownership to whoever gets the DNS next.

If we ever need display hygiene ("this ✓ might be stale"), the
additive schema extension is:

- `publishers.last_verification_check_at INTEGER NULL`
- `publishers.verification_failure_count INTEGER NOT NULL DEFAULT 0`
- A daily probe that flips `verified = false` after N consecutive
  failures
- A "Re-verify" button on the publisher admin page that walks an
  existing admin through a fresh TXT challenge, updating the
  existing row rather than creating a new one

None of that is built. It can be added later without touching the
happy path.

### Quotas

Per-user cap: `MAX_PUBLISHERS_PER_USER` (default 10). Only counts
*verified* publishers the user is a member of — internal publishers
created by an admin don't count against any user's quota. Prevents a
compromised account from flooding the publishers list.

### Failure modes and UX

| Condition | Server response | UI |
|---|---|---|
| Domain taken (verified or internal) | 409 Conflict | "A publisher with this id already exists" |
| Pending verification expired | 400 "Start a new one" | User restarts flow |
| TXT not found on either provider | `VerificationNotFoundException` | "DNS changes can take a few minutes — try again shortly" |
| DoH provider unreachable | `VerificationTemporaryFailure` | Same retry message |
| User-quota exceeded | 400 with quota message | Surface the limit |

---

## Why we don't offer HTTP file verification

**TL;DR: skipped deliberately. DNS-only is simpler, more secure, and
covers effectively all of our users. If demand materializes we can
add it as a second method later without breaking anything.**

### What it would be

An alternate verification method where the user hosts a file at a
predictable URL — e.g. `https://<domain>/.well-known/club-verify`
containing `club-verify=<token>` — and the server fetches and checks
it. Same pattern as Let's Encrypt HTTP-01 and the HTML-file option
in Google Search Console.

### Why other products support it

- **Managed hosting**: users who control the webapp but not the DNS
  zone (common for some PaaS setups).
- **Corporate DNS change-control**: DNS edits require a ticket, file
  deploys are quick.
- **Piggyback**: pub.dev defers to Google Search Console, which
  already offers HTTP-file and HTML-meta methods. Pub.dev inherits
  those for free without implementing them itself.

### Why we don't need it

1. **Our audience owns their DNS.** club is self-hosted by Dart and
   Flutter teams publishing to domains they control. DNS access is
   effectively universal — Cloudflare, Route 53, Namecheap, Google
   Domains, and every enterprise DNS host supports TXT records.
2. **TXT is strictly simpler.** One method, one test matrix, one
   security model. Second method = second code path, second state
   machine in the wizard, second set of error messages, second
   security review.
3. **HTTP fallback has its own security pitfalls.** Short list of
   things we'd need to get exactly right:
   - HTTPS-only — HTTP would be MITM-able by anyone on-path.
   - No redirect following — `cdn.example.com` → `bank.com` would
     let a CDN operator vouch for any domain they proxy.
   - Strict host header matching — some proxies mangle or drop it.
   - Body size + timeout caps — a cooperating malicious origin could
     feed infinite response bodies or stall.
   - Self-signed cert handling — internal domains often have private
     CAs; we'd need to pick a policy (reject vs allow with warning).
4. **Not piggybacking on anything**. Unlike pub.dev we can't lean on
   an existing verification service. Every method we support we have
   to own.
5. **YAGNI**. A real user saying "I can deploy files but not touch
   DNS" is a specific bit of feedback we don't have yet. If it shows
   up, the current server interfaces let us add `method: 'http'` as
   a branch without restructuring anything:
   - `PublisherService.completeVerification` grows a `method` param
   - `PublisherDnsResolver` sits alongside a new `PublisherHttpProber`
   - The `/verify/start` response includes per-method instructions;
     the UI grows a method picker

### Decision

DNS-only for v1. Document the rationale here so future maintainers
don't quietly reinvent the debate; revisit if user feedback makes it
necessary. The extension points are explicit enough that adding HTTP
later is additive, not a rework.

---

## Internal (admin-created) publishers

These bypass DNS. Admins use them for:

- Teams without a public domain (pre-public-launch products, internal
  tooling groups).
- Legacy groupings migrated from an older setup where the domain has
  changed or doesn't exist.
- Reserved namespaces the company wants to claim without routing
  through user-initiated DNS proofs.

The `POST /api/publishers` endpoint accepts an optional
`initialAdminEmail` so the admin can create the publisher *on behalf
of* a team lead in one call. If omitted the creating admin becomes
the first admin.

The no-dot rule on internal slugs guarantees the internal and
verified namespaces never overlap.

---

## Package transfer and deletion

### Transferring packages between publishers

`PUT /api/packages/<pkg>/publisher` with `{ publisherId }` or
`{ publisherId: null }` handles all three cases:

1. **Uploader-owned → publisher**: actor must be an uploader of the
   package AND a publisher admin of the destination.
2. **Publisher A → publisher B**: actor must admin both sides (server
   admins bypass). Prevents a compromised publisher admin from
   dumping packages into a victim publisher's namespace.
3. **Publisher → uploader-owned** (clear): actor must admin the
   current publisher. If the uploader list would be empty after
   release (common — the package was publisher-owned from first
   publish), the acting user is auto-added as the sole uploader so
   the package is never orphaned.

### Deleting a publisher

`DELETE /api/publishers/<id>` succeeds only when the publisher owns
zero packages. Callers must transfer or clear packages first — cascaded
package deletion would be too destructive for a single API call.

Authorization: publisher admin of that specific publisher, or a server
admin.

---

## Files of interest

- `packages/club_core/lib/src/services/publisher_service.dart` — all
  verification, creation, deletion, and member logic.
- `packages/club_core/lib/src/models/publisher_verification.dart` —
  pending-token model.
- `packages/club_server/lib/src/auth/dns_resolver.dart` — DoH client.
- `packages/club_server/lib/src/api/publisher_api.dart` — HTTP surface.
- `packages/club_db/lib/src/sql/schema.dart` — `publishers.verified`
  and `publisher_verifications` tables.
- `packages/club_web/src/routes/publishers/verify/+page.svelte` —
  two-step verification wizard.
