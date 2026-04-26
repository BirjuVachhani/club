# club — OAuth 2.0 Authentication

club implements the OAuth 2.0 Authorization Code flow with PKCE
(RFC 7636) for CLI and third-party application authentication.

This is the same standard used by GitHub CLI, Google Cloud CLI,
Firebase CLI, and Supabase CLI.

---

## Flow Overview

```
CLI                           Browser                        Server
 │                              │                              │
 │  1. Generate PKCE            │                              │
 │     code_verifier            │                              │
 │     code_challenge = S256(v) │                              │
 │                              │                              │
 │  2. Start localhost server   │                              │
 │     on random port           │                              │
 │                              │                              │
 │  3. Open browser ──────────► │                              │
 │     /oauth/authorize?        │                              │
 │       response_type=code     │                              │
 │       client_id=cli          │                              │
 │       redirect_uri=localhost │                              │
 │       code_challenge=...     │                              │
 │       code_challenge_method= │                              │
 │         S256                 │                              │
 │       state=<random>         │                              │
 │                              │  4. Redirect to consent ──►  │
 │                              │     /oauth/consent?          │
 │                              │       request_id=<id>        │
 │                              │                              │
 │                              │  5. User logs in (if needed) │
 │                              │                              │
 │                              │  6. User clicks "Authorize"  │
 │                              │     POST /oauth/approve ───► │
 │                              │     { request_id }           │
 │                              │                              │
 │                              │  ◄── { redirect_url }        │
 │                              │       with ?code=...&state=  │
 │                              │                              │
 │  ◄─── 7. Redirect to ───────│                              │
 │       localhost/callback?    │                              │
 │       code=<code>            │                              │
 │       state=<state>          │                              │
 │                              │                              │
 │  8. Verify state matches     │                              │
 │                              │                              │
 │  9. Exchange code for token ─────────────────────────────►  │
 │     POST /oauth/token                                       │
 │       grant_type=authorization_code                         │
 │       code=<code>                                           │
 │       redirect_uri=<same>                                   │
 │       code_verifier=<original>                              │
 │                              │                              │
 │  ◄──────────────────────────────── { access_token, email }  │
 │                              │                              │
 │  10. Store token locally     │                              │
 │      Done.                   │                              │
```

---

## Security Properties

### PKCE (Proof Key for Code Exchange)

Prevents authorization code interception attacks:

1. CLI generates a random `code_verifier` (43-128 chars, base64url)
2. CLI computes `code_challenge = BASE64URL(SHA256(code_verifier))`
3. CLI sends `code_challenge` in the authorize request
4. Server stores the `code_challenge` with the pending request
5. When CLI exchanges the code, it sends the original `code_verifier`
6. Server computes `SHA256(code_verifier)` and verifies it matches the stored `code_challenge`

Even if an attacker intercepts the authorization code, they can't
exchange it without the `code_verifier` which never left the CLI.

### State Parameter

Prevents CSRF attacks:

1. CLI generates a random `state` value
2. CLI includes `state` in the authorize request
3. Server returns `state` unchanged in the callback
4. CLI verifies the returned `state` matches the original

### Authorization Code Properties

- **Single-use**: consumed immediately on token exchange
- **Short-lived**: expires after 5 minutes (RFC 6749 §4.1.2)
- **Bound to redirect_uri**: must match between authorize and token exchange

---

## Endpoints

### GET /oauth/authorize

Initiates the authorization flow. The browser navigates here.

**Query Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `response_type` | Yes | Must be `code` |
| `client_id` | Yes | Client identifier (e.g., `cli`) |
| `redirect_uri` | Yes | Must be `http://localhost:<port>/...` |
| `code_challenge` | Yes | PKCE S256 challenge |
| `code_challenge_method` | Yes | Must be `S256` |
| `state` | Yes | Random CSRF protection token |
| `scope` | No | Comma-separated: `read,write` (default) |

**Response:** 302 redirect to `/oauth/consent?request_id=<id>`

### GET /oauth/pending/<requestId>

Returns info about a pending authorization request for the consent screen.

**Response:**
```json
{
  "request_id": "abc123",
  "client_id": "cli",
  "scope": "read,write",
  "created_at": "2026-04-09T10:00:00Z"
}
```

### POST /oauth/approve

Called by the web UI after the user clicks "Authorize".
**Requires authentication** (user must be logged in).

**Request:**
```json
{
  "request_id": "abc123"
}
```

**Response:**
```json
{
  "redirect_url": "http://localhost:54321/callback?code=xyz789&state=abc"
}
```

### POST /oauth/token

Token exchange endpoint. Called by the CLI after receiving the code.
**No authentication required** — PKCE verifier proves legitimacy.

**Request** (form-urlencoded or JSON):
```
grant_type=authorization_code
code=<authorization_code>
redirect_uri=<same as authorize>
code_verifier=<original PKCE verifier>
```

**Response:**
```json
{
  "access_token": "club_a1b2c3d4...",
  "token_type": "Bearer",
  "scope": "read,write",
  "email": "user@example.com"
}
```

**Error Response:**
```json
{
  "error": "invalid_grant",
  "error_description": "Authorization code expired or not found."
}
```

---

## CLI Usage

### Browser flow (default)

```bash
club login https://club.example.com
```

Opens browser → user authorizes → token stored automatically.

### Direct token

```bash
club login https://club.example.com --token club_a1b2c3d4...
```

### Terminal prompt (no browser)

```bash
club login https://club.example.com --no-browser
```

Prompts for email/password in the terminal. Useful for SSH sessions.

---

## Token Storage

Tokens are stored in `~/.config/club/credentials.json`:

```json
{
  "defaultServer": "https://club.example.com",
  "servers": {
    "https://club.example.com": {
      "token": "club_a1b2c3d4...",
      "email": "user@example.com",
      "createdAt": "2026-04-09T10:00:00Z"
    }
  }
}
```

---

## Third-Party Integration

Any application can use the OAuth flow to authenticate with club.
The `client_id` is informational — there's no client registration required.

```
GET /oauth/authorize?
  response_type=code&
  client_id=my-app&
  redirect_uri=http://localhost:3000/callback&
  code_challenge=<S256 hash>&
  code_challenge_method=S256&
  state=<random>
```

Implement PKCE (RFC 7636) in your application to secure the flow.
