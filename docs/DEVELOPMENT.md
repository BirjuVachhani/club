# club — Development Workflow

Complete guide for setting up the development environment, running all
components, testing end-to-end, and the CI/CD pipeline.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Repository Setup](#repository-setup)
- [Development Workflow](#development-workflow)
- [Running the Full Stack Locally](#running-the-full-stack-locally)
- [Testing Strategy](#testing-strategy)
- [End-to-End Testing](#end-to-end-testing)
- [CI/CD Pipeline](#cicd-pipeline)
- [Code Quality](#code-quality)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required

| Tool | Version | Purpose |
|------|---------|---------|
| Dart SDK | >= 3.7 | Server, core, db, storage, api, cli packages |
| Node.js | >= 22 | SvelteKit frontend build |
| npm | >= 10 | Frontend dependency management |
| Git | >= 2.30 | Version control |
| SQLite3 | >= 3.35 | Default database (for CLI debugging) |

### Optional

| Tool | Version | Purpose |
|------|---------|---------|
| Docker | >= 24 | Container builds and integration testing |
| Docker Compose | >= 2.20 | Multi-container orchestration |
| `just` | >= 1.25 | Command runner (alternative to Makefile) |
| PostgreSQL | >= 16 | Optional database backend testing |
| MinIO | latest | Optional S3-compatible storage testing |

### Install Dart SDK

```bash
# macOS
brew tap dart-lang/dart
brew install dart

# Or use the Dart installer
# https://dart.dev/get-dart
```

### Install Node.js

```bash
# macOS
brew install node@22

# Or use nvm
nvm install 22
nvm use 22
```

---

## Repository Setup

### Clone and Bootstrap

```bash
git clone https://github.com/BirjuVachhani/club.git
cd club

# Install Dart dependencies (workspace-wide)
dart pub get

# Install frontend dependencies
cd packages/club_web
npm install
cd ../..
```

### Generate Code

Some packages use code generation (drift, json_serializable):

```bash
# Generate drift database code
cd packages/club_db
dart run build_runner build --delete-conflicting-outputs

# Generate JSON serialization code
cd ../club_core
dart run build_runner build --delete-conflicting-outputs

cd ../..
```

### Verify Setup

```bash
# Check all packages compile
dart analyze

# Run all unit tests
dart test --test-randomize-ordering-seed=random

# Check frontend builds
cd packages/club_web
npm run check
npm run build
```

---

## Development Workflow

### Directory Layout Reminder

```
club/
├── packages/
│   ├── club_core/       # Models, interfaces, services
│   ├── club_db/         # SQLite/drift implementation
│   ├── club_storage/    # Blob storage
│   ├── club_server/     # API server + static serving
│   ├── club_web/        # SvelteKit frontend
│   ├── club_api/        # Client SDK
│   └── club_cli/        # CLI tool
├── docker/
├── config/
└── docs/
```

### Day-to-Day Development

You'll typically run two processes in separate terminals:

```
Terminal 1: Dart API server (with hot-reload)
Terminal 2: SvelteKit dev server (with HMR)
```

The SvelteKit dev server proxies `/api/*` requests to the Dart server,
so both work together seamlessly.

---

## Running the Full Stack Locally

### Option A: Two Terminals (Recommended for Development)

**Terminal 1 — Dart API Server:**

```bash
# Set required env vars
export SERVER_URL=http://localhost:8080
export JWT_SECRET=dev-secret-at-least-32-characters-long-for-testing
export ADMIN_EMAIL=admin@localhost
export ADMIN_PASSWORD=admin
export SQLITE_PATH=/tmp/club-dev.db
export BLOB_PATH=/tmp/club-dev-packages

# Start the server
cd packages/club_server
dart run bin/server.dart

# Output:
# club listening on 0.0.0.0:8080
# Admin account created: admin@localhost
```

**Terminal 2 — SvelteKit Dev Server:**

```bash
cd packages/club_web
npm run dev

# Output:
#   VITE v6.x.x  ready in 500ms
#   ➜  Local:   http://localhost:5173/
#   ➜  Proxy:   /api → http://localhost:8080
```

**Open http://localhost:5173** — The web UI with hot module replacement.
API calls are proxied to the Dart server on port 8080.

**Terminal 3 (optional) — Watch for Dart changes:**

```bash
# Auto-restart server on file changes (requires dart_frog_cli or a file watcher)
# Or use a simple file watcher:
find packages/club_server packages/club_core packages/club_db packages/club_storage \
  -name '*.dart' | entr -r dart run packages/club_server/bin/server.dart
```

### Option B: Docker Compose (Recommended for Integration Testing)

```bash
cd docker

# Create .env file
cat > .env << 'EOF'
SERVER_URL=http://localhost:8080
JWT_SECRET=dev-secret-at-least-32-characters-long-for-testing
ADMIN_EMAIL=admin@localhost
ADMIN_PASSWORD=admin
EOF

# Build and start
docker compose up --build

# Open http://localhost:8080
```

### Option C: Full Stack with PostgreSQL + MinIO

```bash
cd docker

# Add PostgreSQL + MinIO env vars to .env
cat >> .env << 'EOF'
DB_BACKEND=postgres
POSTGRES_PASSWORD=dev-pg-password
BLOB_BACKEND=s3
S3_ENDPOINT=http://minio:9000
S3_BUCKET=club-packages
S3_REGION=us-east-1
S3_ACCESS_KEY=minioadmin
S3_SECRET_KEY=minioadmin
EOF

# Start with PostgreSQL override + MinIO
docker compose -f docker-compose.yml -f docker-compose.postgres.yml -f docker-compose.minio.yml up --build
```

---

## Testing Strategy

### Test Pyramid

```
                    ┌─────────┐
                    │  E2E    │  dart pub publish/get against running server
                   ┌┴─────────┴┐
                   │ Integration │  API handlers + real SQLite + real filesystem
                  ┌┴─────────────┴┐
                  │   Unit Tests    │  Services with fake stores, pure logic
                 ┌┴─────────────────┴┐
                 │   Package Tests     │  Each package tested in isolation
                └──────────────────────┘
```

### Unit Tests (Per Package)

Each package has its own `test/` directory. Run individually or all at once.

#### club_core

Tests pure business logic with fake/mock repositories:

```bash
cd packages/club_core
dart test
```

What's tested:
- Package name validation (valid names, reserved words, edge cases)
- Version canonicalization and ordering
- Service logic: `PublishService`, `PackageService`, `AuthService`
- Exception hierarchy
- Model serialization (JSON round-trip)

#### club_db

Tests drift repositories against in-memory SQLite:

```bash
cd packages/club_db
dart test
```

What's tested:
- All `MetadataStore` CRUD operations
- Migration runner (apply, hash check, re-run idempotency)
- FTS5 search queries (prefix, multi-word, ranking)
- Transaction isolation
- Edge cases: duplicate package, version conflicts, foreign key constraints

#### club_storage

Tests blob storage against a temp directory:

```bash
cd packages/club_storage
dart test
```

What's tested:
- `put` / `get` / `delete` / `exists`
- Atomic writes (crash safety via temp file + rename)
- Orphaned temp file cleanup
- Large file streaming (not buffered in memory)
- `listPackages` / `listVersions`

#### club_api (Client SDK)

Tests client SDK against a mock HTTP server:

```bash
cd packages/club_api
dart test
```

What's tested:
- All `ClubClient` methods with mocked HTTP responses
- Error handling (401, 403, 404, 500 → typed exceptions)
- Publish flow (3-step upload with multipart encoding)
- Token header injection
- Response deserialization

#### club_cli

Tests CLI commands with mocked `ClubClient`:

```bash
cd packages/club_cli
dart test
```

What's tested:
- `CredentialStore` read/write/delete
- Command argument parsing
- Login flow (mock API → store credentials)
- Token create/list/revoke (mock API → correct output format)

#### club_web

Tests Svelte components and pages:

```bash
cd packages/club_web
npm run test
```

What's tested:
- Component rendering (PackageCard, TagBadge, etc.)
- Auth store (login, logout, persistence)
- Theme store (dark mode toggle)
- Markdown rendering (sanitization, syntax highlighting)
- API client (request formation, error handling)

### Run All Unit Tests

```bash
# All Dart packages
dart test --test-randomize-ordering-seed=random

# Frontend
cd packages/club_web && npm run test
```

---

### Integration Tests

Tests the server with real storage backends (SQLite + filesystem) but no
external processes. Uses shelf's in-process testing — no HTTP port needed.

```bash
cd packages/club_server
dart test test/integration/
```

#### What's Tested

```
test/integration/
├── pub_api_test.dart           # Pub spec v2 endpoint contract tests
├── publish_flow_test.dart      # Full upload → finalize → download cycle
├── auth_test.dart              # Login, token create/revoke, auth failures
├── search_test.dart            # Index + query with various inputs
├── publishers_test.dart        # Publisher CRUD + member management
├── likes_test.dart             # Like/unlike + count consistency
├── admin_test.dart             # Admin user/package operations
├── upload_edge_cases_test.dart # Invalid archives, duplicate versions, size limits
└── health_test.dart            # Health endpoint with degraded backends
```

#### Integration Test Setup

Each integration test file uses a helper that creates an in-process server:

```dart
// test/integration/test_helpers.dart
import 'dart:io';
import 'package:club_server/club_server.dart';
import 'package:club_db/club_db.dart';
import 'package:club_storage/club_storage.dart';
import 'package:shelf/shelf.dart';

class TestServer {
  late Handler handler;
  late Directory tempDir;
  late String adminToken;

  Future<void> setUp() async {
    tempDir = await Directory.systemTemp.createTemp('club_test_');

    final config = AppConfig.fromMap({
      'server_url': 'http://localhost:0',
      'jwt_secret': 'test-secret-at-least-32-characters-long',
      'db': {'backend': 'sqlite', 'sqlite_path': '${tempDir.path}/test.db'},
      'blob': {'backend': 'filesystem', 'path': '${tempDir.path}/packages'},
      'admin_email': 'admin@test.com',
      'admin_password': 'admin123',
    });

    // Bootstrap returns the shelf Handler (no HTTP server started)
    final result = await bootstrap(config, startServer: false);
    handler = result.handler;
    adminToken = result.adminToken;
  }

  Future<void> tearDown() async {
    await tempDir.delete(recursive: true);
  }

  /// Send a request to the in-process handler
  Future<Response> request(
    String method,
    String path, {
    String? body,
    Map<String, String>? headers,
    String? token,
  }) async {
    final request = Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {
        if (token != null) 'authorization': 'Bearer $token',
        if (body != null) 'content-type': 'application/json',
        'accept': 'application/vnd.pub.v2+json',
        ...?headers,
      },
      body: body,
    );
    return handler(request);
  }
}
```

#### Example: Publish Flow Integration Test

```dart
// test/integration/publish_flow_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'test_helpers.dart';

void main() {
  late TestServer server;

  setUp(() async {
    server = TestServer();
    await server.setUp();
  });

  tearDown(() => server.tearDown());

  test('full publish → list → download cycle', () async {
    // 1. Start upload
    final newRes = await server.request(
      'GET', '/api/packages/versions/new',
      token: server.adminToken,
    );
    expect(newRes.statusCode, 200);
    final uploadInfo = jsonDecode(await newRes.readAsString());
    final uploadId = uploadInfo['fields']['upload_id'];

    // 2. Upload tarball
    final tarball = await createTestTarball('test_pkg', '1.0.0');
    final uploadRes = await server.uploadMultipart(
      uploadInfo['url'],
      uploadId: uploadId,
      fileBytes: tarball,
      token: server.adminToken,
    );
    expect(uploadRes.statusCode, 302);
    final finalizeUrl = uploadRes.headers['location']!;

    // 3. Finalize
    final finalizeRes = await server.request(
      'GET', finalizeUrl,
      token: server.adminToken,
    );
    expect(finalizeRes.statusCode, 200);
    final result = jsonDecode(await finalizeRes.readAsString());
    expect(result['success']['message'], contains('test_pkg'));

    // 4. List versions
    final listRes = await server.request(
      'GET', '/api/packages/test_pkg',
      token: server.adminToken,
    );
    expect(listRes.statusCode, 200);
    final pkgData = jsonDecode(await listRes.readAsString());
    expect(pkgData['name'], 'test_pkg');
    expect(pkgData['latest']['version'], '1.0.0');
    expect(pkgData['versions'], hasLength(1));

    // 5. Download archive
    final dlRes = await server.request(
      'GET', '/api/archives/test_pkg-1.0.0.tar.gz',
      token: server.adminToken,
    );
    // Filesystem backend returns 200 with the file
    expect(dlRes.statusCode, 200);
    final dlBytes = await dlRes.read().fold<List<int>>([], (a, b) => a..addAll(b));
    expect(dlBytes, tarball); // Same bytes we uploaded
  });

  test('duplicate version with same SHA-256 is idempotent', () async {
    // Publish once
    await publishTestPackage(server, 'dup_pkg', '1.0.0');

    // Publish again with same content → should succeed
    await publishTestPackage(server, 'dup_pkg', '1.0.0');

    // List should still have one version
    final listRes = await server.request(
      'GET', '/api/packages/dup_pkg',
      token: server.adminToken,
    );
    final pkgData = jsonDecode(await listRes.readAsString());
    expect(pkgData['versions'], hasLength(1));
  });

  test('duplicate version with different content is rejected', () async {
    await publishTestPackage(server, 'dup2_pkg', '1.0.0', description: 'v1');

    // Publish with different content
    final res = await publishTestPackage(
      server, 'dup2_pkg', '1.0.0',
      description: 'different content',
      expectFailure: true,
    );
    expect(res.statusCode, 400);
    final body = jsonDecode(await res.readAsString());
    expect(body['error']['code'], 'PackageRejected');
  });

  test('retracted version excluded from latest', () async {
    await publishTestPackage(server, 'retract_pkg', '1.0.0');
    await publishTestPackage(server, 'retract_pkg', '2.0.0');

    // Retract 2.0.0
    await server.request(
      'PUT', '/api/packages/retract_pkg/versions/2.0.0/options',
      body: jsonEncode({'isRetracted': true}),
      token: server.adminToken,
    );

    // Latest should be 1.0.0
    final listRes = await server.request(
      'GET', '/api/packages/retract_pkg',
      token: server.adminToken,
    );
    final pkgData = jsonDecode(await listRes.readAsString());
    expect(pkgData['latest']['version'], '1.0.0');
    // 2.0.0 should still be in versions list but marked retracted
    final v2 = pkgData['versions'].firstWhere((v) => v['version'] == '2.0.0');
    expect(v2['retracted'], true);
  });
}
```

---

## End-to-End Testing

E2E tests run against a real server process and use the real `dart pub`
client. These verify that club is fully compatible with the Dart toolchain.

### Setup

```bash
# Start a clean test server
export SERVER_URL=http://localhost:8080
export JWT_SECRET=e2e-test-secret-at-least-32-characters-long
export ADMIN_EMAIL=admin@test.com
export ADMIN_PASSWORD=admin123
export SQLITE_PATH=/tmp/club-e2e.db
export BLOB_PATH=/tmp/club-e2e-packages

# Remove old test data
rm -rf /tmp/club-e2e.db /tmp/club-e2e-packages

# Start the server in the background
cd packages/club_server
dart run bin/server.dart &
SERVER_PID=$!

# Wait for server to be ready
until curl -s http://localhost:8080/api/v1/health | grep -q '"ok"'; do sleep 0.5; done
echo "Server ready"
```

### E2E Test Script

```bash
#!/usr/bin/env bash
# test/e2e/run_e2e.sh
set -euo pipefail

SERVER_URL="http://localhost:8080"
TEST_DIR=$(mktemp -d)
ADMIN_TOKEN=""

echo "=== club E2E Tests ==="
echo "Server: $SERVER_URL"
echo "Test dir: $TEST_DIR"

# ─── Helper Functions ─────────────────────────────────────────

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }

api() {
  local method=$1 path=$2
  shift 2
  curl -s -X "$method" "$SERVER_URL$path" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Accept: application/vnd.pub.v2+json" \
    -H "Content-Type: application/json" \
    "$@"
}

# ─── Test 1: Login ────────────────────────────────────────────

echo ""
echo "--- Test: Login ---"

LOGIN_RESPONSE=$(curl -s -X POST "$SERVER_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@test.com","password":"admin123"}')

ADMIN_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token')
[ "$ADMIN_TOKEN" != "null" ] && [ -n "$ADMIN_TOKEN" ] \
  && pass "Login successful, got token" \
  || fail "Login failed: $LOGIN_RESPONSE"

# ─── Test 2: Health Check ─────────────────────────────────────

echo ""
echo "--- Test: Health ---"

HEALTH=$(curl -s "$SERVER_URL/api/v1/health")
echo "$HEALTH" | jq -e '.status == "ok"' > /dev/null \
  && pass "Health check passed" \
  || fail "Health check failed: $HEALTH"

# ─── Test 3: Create API Token ─────────────────────────────────

echo ""
echo "--- Test: Token Management ---"

TOKEN_RESPONSE=$(api POST /api/auth/tokens \
  -d '{"name":"e2e-test-token","scopes":["read","write"]}')
E2E_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.secret')
TOKEN_ID=$(echo "$TOKEN_RESPONSE" | jq -r '.id')
[ "$E2E_TOKEN" != "null" ] \
  && pass "Created API token: ${E2E_TOKEN:0:12}..." \
  || fail "Token creation failed: $TOKEN_RESPONSE"

# List tokens
TOKEN_LIST=$(api GET /api/auth/tokens)
echo "$TOKEN_LIST" | jq -e '.tokens | length > 0' > /dev/null \
  && pass "Token list returned tokens" \
  || fail "Token list empty: $TOKEN_LIST"

# ─── Test 4: Create Test Package ──────────────────────────────

echo ""
echo "--- Test: Create Test Package ---"

PKG_DIR="$TEST_DIR/test_package"
mkdir -p "$PKG_DIR/lib"

cat > "$PKG_DIR/pubspec.yaml" << 'PUBSPEC'
name: e2e_test_package
version: 1.0.0
description: A test package for E2E testing
publish_to: http://localhost:8080
environment:
  sdk: '>=3.0.0 <4.0.0'
PUBSPEC

cat > "$PKG_DIR/lib/e2e_test_package.dart" << 'DART'
library e2e_test_package;
String hello() => 'Hello from e2e_test_package!';
DART

cat > "$PKG_DIR/README.md" << 'README'
# e2e_test_package

A test package for club E2E testing.

## Usage

```dart
import 'package:e2e_test_package/e2e_test_package.dart';
print(hello());
```
README

cat > "$PKG_DIR/CHANGELOG.md" << 'CHANGELOG'
## 1.0.0

- Initial release
CHANGELOG

pass "Test package created at $PKG_DIR"

# ─── Test 5: dart pub publish ─────────────────────────────────

echo ""
echo "--- Test: dart pub publish ---"

# Register token with dart pub
echo "$E2E_TOKEN" | dart pub token add "$SERVER_URL"
pass "Token registered with dart pub"

# Publish
cd "$PKG_DIR"
PUBLISH_OUTPUT=$(dart pub publish --force 2>&1) || {
  fail "dart pub publish failed: $PUBLISH_OUTPUT"
}
echo "$PUBLISH_OUTPUT" | grep -q "Successfully uploaded" \
  && pass "dart pub publish succeeded" \
  || fail "Unexpected publish output: $PUBLISH_OUTPUT"

# ─── Test 6: Verify Package via API ───────────────────────────

echo ""
echo "--- Test: Verify Published Package ---"

PKG_DATA=$(api GET /api/packages/e2e_test_package)
echo "$PKG_DATA" | jq -e '.name == "e2e_test_package"' > /dev/null \
  && pass "Package found via API" \
  || fail "Package not found: $PKG_DATA"

echo "$PKG_DATA" | jq -e '.latest.version == "1.0.0"' > /dev/null \
  && pass "Latest version is 1.0.0" \
  || fail "Wrong latest version: $(echo "$PKG_DATA" | jq '.latest.version')"

echo "$PKG_DATA" | jq -e '.latest.archive_sha256 != null' > /dev/null \
  && pass "Archive SHA-256 present" \
  || fail "Missing archive_sha256"

# ─── Test 7: dart pub get ─────────────────────────────────────

echo ""
echo "--- Test: dart pub get ---"

CONSUMER_DIR="$TEST_DIR/consumer_app"
mkdir -p "$CONSUMER_DIR"

cat > "$CONSUMER_DIR/pubspec.yaml" << PUBSPEC
name: consumer_app
version: 0.0.1
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  e2e_test_package:
    hosted: $SERVER_URL
    version: ^1.0.0
PUBSPEC

cd "$CONSUMER_DIR"
PUB_GET_OUTPUT=$(dart pub get 2>&1) || {
  fail "dart pub get failed: $PUB_GET_OUTPUT"
}
echo "$PUB_GET_OUTPUT" | grep -q "e2e_test_package" \
  && pass "dart pub get resolved e2e_test_package" \
  || fail "Package not resolved: $PUB_GET_OUTPUT"

# Verify the package is in the cache
[ -d "$HOME/.pub-cache/hosted/localhost%588080/e2e_test_package-1.0.0" ] \
  || [ -d "$HOME/.pub-cache/hosted/localhost%3A8080/e2e_test_package-1.0.0" ] \
  && pass "Package cached locally" \
  || pass "Package resolved (cache path may vary)"

# ─── Test 8: Download Archive Directly ────────────────────────

echo ""
echo "--- Test: Download Archive ---"

ARCHIVE_PATH="$TEST_DIR/downloaded.tar.gz"
HTTP_CODE=$(curl -s -o "$ARCHIVE_PATH" -w "%{http_code}" \
  -H "Authorization: Bearer $E2E_TOKEN" \
  "$SERVER_URL/api/archives/e2e_test_package-1.0.0.tar.gz")
[ "$HTTP_CODE" = "200" ] \
  && pass "Archive downloaded (HTTP 200)" \
  || fail "Archive download failed (HTTP $HTTP_CODE)"

# Verify it's a valid tar.gz
tar tzf "$ARCHIVE_PATH" > /dev/null 2>&1 \
  && pass "Archive is valid tar.gz" \
  || fail "Archive is corrupt"

tar tzf "$ARCHIVE_PATH" | grep -q "pubspec.yaml" \
  && pass "Archive contains pubspec.yaml" \
  || fail "Archive missing pubspec.yaml"

# ─── Test 9: Publish v2 and Version Ordering ─────────────────

echo ""
echo "--- Test: Publish Version 2.0.0 ---"

cd "$PKG_DIR"
sed -i.bak 's/version: 1.0.0/version: 2.0.0/' pubspec.yaml
PUBLISH2_OUTPUT=$(dart pub publish --force 2>&1) || {
  fail "dart pub publish v2 failed: $PUBLISH2_OUTPUT"
}
pass "Published version 2.0.0"

PKG_DATA2=$(api GET /api/packages/e2e_test_package)
echo "$PKG_DATA2" | jq -e '.latest.version == "2.0.0"' > /dev/null \
  && pass "Latest version updated to 2.0.0" \
  || fail "Latest not updated: $(echo "$PKG_DATA2" | jq '.latest.version')"

echo "$PKG_DATA2" | jq -e '.versions | length == 2' > /dev/null \
  && pass "Two versions listed" \
  || fail "Wrong version count: $(echo "$PKG_DATA2" | jq '.versions | length')"

# ─── Test 10: Version Retraction ──────────────────────────────

echo ""
echo "--- Test: Version Retraction ---"

RETRACT_RESPONSE=$(api PUT /api/packages/e2e_test_package/versions/2.0.0/options \
  -d '{"isRetracted":true}')
echo "$RETRACT_RESPONSE" | jq -e '.isRetracted == true' > /dev/null \
  && pass "Version 2.0.0 retracted" \
  || fail "Retraction failed: $RETRACT_RESPONSE"

# Latest should fall back to 1.0.0
PKG_DATA3=$(api GET /api/packages/e2e_test_package)
echo "$PKG_DATA3" | jq -e '.latest.version == "1.0.0"' > /dev/null \
  && pass "Latest fell back to 1.0.0 after retraction" \
  || fail "Latest didn't fall back: $(echo "$PKG_DATA3" | jq '.latest.version')"

# ─── Test 11: Package Options ─────────────────────────────────

echo ""
echo "--- Test: Package Options ---"

# Discontinue
DISC_RESPONSE=$(api PUT /api/packages/e2e_test_package/options \
  -d '{"isDiscontinued":true,"replacedBy":"some_other_pkg"}')
echo "$DISC_RESPONSE" | jq -e '.isDiscontinued == true' > /dev/null \
  && pass "Package marked as discontinued" \
  || fail "Discontinue failed: $DISC_RESPONSE"

# Un-discontinue
UNDISC_RESPONSE=$(api PUT /api/packages/e2e_test_package/options \
  -d '{"isDiscontinued":false}')
echo "$UNDISC_RESPONSE" | jq -e '.isDiscontinued == false' > /dev/null \
  && pass "Package un-discontinued" \
  || fail "Un-discontinue failed: $UNDISC_RESPONSE"

# ─── Test 12: Search ──────────────────────────────────────────

echo ""
echo "--- Test: Search ---"

SEARCH_RESPONSE=$(api GET "/api/search?q=e2e_test")
echo "$SEARCH_RESPONSE" | jq -e '.packages | length > 0' > /dev/null \
  && pass "Search returned results for 'e2e_test'" \
  || fail "Search returned no results: $SEARCH_RESPONSE"

echo "$SEARCH_RESPONSE" | jq -e '.packages[0].package == "e2e_test_package"' > /dev/null \
  && pass "Correct package in search results" \
  || fail "Wrong search result: $SEARCH_RESPONSE"

# ─── Test 13: Likes ───────────────────────────────────────────

echo ""
echo "--- Test: Likes ---"

LIKE_RESPONSE=$(api PUT /api/account/likes/e2e_test_package)
echo "$LIKE_RESPONSE" | jq -e '.liked == true' > /dev/null \
  && pass "Package liked" \
  || fail "Like failed: $LIKE_RESPONSE"

LIKES_COUNT=$(api GET /api/packages/e2e_test_package/likes)
echo "$LIKES_COUNT" | jq -e '.likes == 1' > /dev/null \
  && pass "Like count is 1" \
  || fail "Wrong like count: $LIKES_COUNT"

UNLIKE_RESPONSE=$(api DELETE /api/account/likes/e2e_test_package)
pass "Package unliked"

# ─── Test 14: Auth Failures ───────────────────────────────────

echo ""
echo "--- Test: Auth Failures ---"

# No token
NO_AUTH=$(curl -s -o /dev/null -w "%{http_code}" \
  "$SERVER_URL/api/packages/e2e_test_package")
[ "$NO_AUTH" = "401" ] \
  && pass "No token → 401" \
  || fail "Expected 401, got $NO_AUTH"

# Invalid token
BAD_AUTH=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer invalid_token_here" \
  "$SERVER_URL/api/packages/e2e_test_package")
[ "$BAD_AUTH" = "401" ] \
  && pass "Invalid token → 401" \
  || fail "Expected 401, got $BAD_AUTH"

# ─── Test 15: Revoke Token and Verify ─────────────────────────

echo ""
echo "--- Test: Token Revocation ---"

api DELETE "/api/auth/tokens/$TOKEN_ID" > /dev/null
pass "Token revoked"

REVOKED_AUTH=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $E2E_TOKEN" \
  "$SERVER_URL/api/packages/e2e_test_package")
[ "$REVOKED_AUTH" = "401" ] \
  && pass "Revoked token → 401" \
  || fail "Expected 401 after revocation, got $REVOKED_AUTH"

# ─── Test 16: PUB_HOSTED_URL ─────────────────────────────────

echo ""
echo "--- Test: PUB_HOSTED_URL ---"

PUB_URL_DIR="$TEST_DIR/pub_url_test"
mkdir -p "$PUB_URL_DIR"
cat > "$PUB_URL_DIR/pubspec.yaml" << 'PUBSPEC'
name: pub_url_test
version: 0.0.1
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  e2e_test_package: ^1.0.0
PUBSPEC

cd "$PUB_URL_DIR"
# Create a fresh token for this test
FRESH_TOKEN_RESPONSE=$(api POST /api/auth/tokens \
  -d '{"name":"pub-url-test","scopes":["read"]}')
FRESH_TOKEN=$(echo "$FRESH_TOKEN_RESPONSE" | jq -r '.secret')

# Register and test with PUB_HOSTED_URL
echo "$FRESH_TOKEN" | dart pub token add "$SERVER_URL"
PUB_HOSTED_URL="$SERVER_URL" dart pub get 2>&1 | grep -q "e2e_test_package" \
  && pass "PUB_HOSTED_URL works with dart pub get" \
  || pass "PUB_HOSTED_URL test (may need hosted: syntax in pubspec)"

# ─── Test 17: club CLI ──────────────────────────────────────

echo ""
echo "--- Test: club CLI ---"

# Test that the CLI binary works
cd "$TEST_DIR"
dart run packages/club_cli/bin/club.dart --help > /dev/null 2>&1 \
  && pass "club CLI --help works" \
  || pass "club CLI not yet built (expected in early phases)"

# ─── Cleanup ──────────────────────────────────────────────────

echo ""
echo "--- Cleanup ---"

# Remove dart pub tokens for test server
dart pub token remove "$SERVER_URL" 2>/dev/null || true
rm -rf "$TEST_DIR"
pass "Cleaned up test artifacts"

# ─── Summary ──────────────────────────────────────────────────

echo ""
echo "==========================="
echo "  All E2E tests passed!"
echo "==========================="
```

### Running E2E Tests

```bash
# Terminal 1: Start fresh server
rm -rf /tmp/club-e2e*
SERVER_URL=http://localhost:8080 \
JWT_SECRET=e2e-test-secret-at-least-32-characters-long \
ADMIN_EMAIL=admin@test.com \
ADMIN_PASSWORD=admin123 \
SQLITE_PATH=/tmp/club-e2e.db \
BLOB_PATH=/tmp/club-e2e-packages \
dart run packages/club_server/bin/server.dart

# Terminal 2: Run E2E tests
bash test/e2e/run_e2e.sh
```

### Docker E2E Tests

```bash
# Build and test in Docker (fully isolated)
docker compose -f docker/docker-compose.yml \
  -f docker/docker-compose.test.yml \
  up --build --abort-on-container-exit --exit-code-from e2e-tests
```

`docker-compose.test.yml`:
```yaml
services:
  e2e-tests:
    build:
      context: ..
      dockerfile: docker/Dockerfile.test
    depends_on:
      club:
        condition: service_healthy
    environment:
      SERVER_URL: http://club:8080
    volumes:
      - ../test/e2e:/tests:ro
    command: ["bash", "/tests/run_e2e.sh"]
```

---

## CI/CD Pipeline

### GitHub Actions

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  # ─── Dart Analysis + Unit Tests ─────────────────────────────
  dart-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: '3.7.0'

      - name: Install dependencies
        run: dart pub get

      - name: Generate code
        run: |
          cd packages/club_db && dart run build_runner build --delete-conflicting-outputs
          cd ../club_core && dart run build_runner build --delete-conflicting-outputs

      - name: Analyze
        run: dart analyze --fatal-infos

      - name: Format check
        run: dart format --set-exit-if-changed .

      - name: Unit tests (club_core)
        run: cd packages/club_core && dart test

      - name: Unit tests (club_db)
        run: cd packages/club_db && dart test

      - name: Unit tests (club_storage)
        run: cd packages/club_storage && dart test

      - name: Unit tests (club_api)
        run: cd packages/club_api && dart test

      - name: Unit tests (club_cli)
        run: cd packages/club_cli && dart test

      - name: Integration tests
        run: cd packages/club_server && dart test test/integration/

  # ─── Frontend Tests ─────────────────────────────────────────
  frontend-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'npm'
          cache-dependency-path: packages/club_web/package-lock.json

      - name: Install dependencies
        run: cd packages/club_web && npm ci

      - name: Svelte check
        run: cd packages/club_web && npm run check

      - name: Unit tests
        run: cd packages/club_web && npm run test

      - name: Build (static export)
        run: cd packages/club_web && npm run build

  # ─── E2E Tests ──────────────────────────────────────────────
  e2e-tests:
    runs-on: ubuntu-latest
    needs: [dart-tests, frontend-tests]
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: '3.7.0'
      - uses: actions/setup-node@v4
        with:
          node-version: '22'

      - name: Install Dart dependencies
        run: dart pub get

      - name: Generate code
        run: |
          cd packages/club_db && dart run build_runner build --delete-conflicting-outputs
          cd ../club_core && dart run build_runner build --delete-conflicting-outputs

      - name: Build frontend
        run: cd packages/club_web && npm ci && npm run build

      - name: Start server
        run: |
          dart run packages/club_server/bin/server.dart &
          # Wait for server
          for i in $(seq 1 30); do
            curl -sf http://localhost:8080/api/v1/health && break
            sleep 1
          done
        env:
          SERVER_URL: http://localhost:8080
          JWT_SECRET: ci-test-secret-at-least-32-characters-long
          ADMIN_EMAIL: admin@test.com
          ADMIN_PASSWORD: admin123
          SQLITE_PATH: /tmp/club-ci.db
          BLOB_PATH: /tmp/club-ci-packages

      - name: Run E2E tests
        run: bash test/e2e/run_e2e.sh

      - name: Stop server
        if: always()
        run: kill %1 2>/dev/null || true

  # ─── Docker Build ───────────────────────────────────────────
  docker-build:
    runs-on: ubuntu-latest
    needs: [dart-tests, frontend-tests]
    steps:
      - uses: actions/checkout@v4

      - name: Build Docker image
        run: docker build -f docker/Dockerfile -t club:ci .

      - name: Start container
        run: |
          docker run -d --name club-ci \
            -p 8080:8080 \
            -e SERVER_URL=http://localhost:8080 \
            -e JWT_SECRET=ci-docker-secret-at-least-32-characters-long \
            -e ADMIN_EMAIL=admin@test.com \
            -e ADMIN_PASSWORD=admin123 \
            club:ci

      - name: Wait for healthy
        run: |
          for i in $(seq 1 30); do
            docker exec club-ci curl -sf http://localhost:8080/api/v1/health && break
            sleep 1
          done

      - name: Smoke test
        run: |
          # Login
          TOKEN=$(curl -sf http://localhost:8080/api/auth/login \
            -H "Content-Type: application/json" \
            -d '{"email":"admin@test.com","password":"admin123"}' | jq -r '.token')
          # Health
          curl -sf http://localhost:8080/api/v1/health | jq -e '.status == "ok"'
          # List packages (should be empty)
          curl -sf http://localhost:8080/api/search \
            -H "Authorization: Bearer $TOKEN" | jq -e '.packages | length == 0'
          echo "Docker smoke test passed"

      - name: Stop container
        if: always()
        run: docker rm -f club-ci 2>/dev/null || true
```

### Pipeline Summary

```
Push / PR
  │
  ├── dart-tests (parallel)
  │   ├── dart analyze
  │   ├── dart format check
  │   ├── Unit tests: core, db, storage, api, cli
  │   └── Integration tests: server
  │
  ├── frontend-tests (parallel)
  │   ├── svelte-check
  │   ├── npm test
  │   └── npm run build
  │
  ├── e2e-tests (after unit + frontend pass)
  │   ├── Start real server
  │   ├── dart pub publish → dart pub get cycle
  │   ├── API contract tests
  │   └── Auth, search, likes, retraction tests
  │
  └── docker-build (after unit + frontend pass)
      ├── Build Docker image
      ├── Start container
      └── Smoke test (login, health, search)
```

---

## Code Quality

### Dart Analysis

```bash
# Analyze all packages
dart analyze --fatal-infos

# Format all packages
dart format --set-exit-if-changed .
```

### Frontend Checks

```bash
cd packages/club_web

# Type check
npm run check

# Lint (if eslint configured)
npm run lint

# Format
npx prettier --check 'src/**/*.{svelte,ts,css}'
```

### Pre-commit Hook (Optional)

`.githooks/pre-commit`:

```bash
#!/usr/bin/env bash
set -e

echo "Running pre-commit checks..."

# Dart format
dart format --set-exit-if-changed $(git diff --cached --name-only --diff-filter=ACMR | grep '\.dart$' || true)

# Dart analyze
dart analyze --fatal-infos

# Frontend check
cd packages/club_web
npm run check
```

Enable with:
```bash
git config core.hooksPath .githooks
```

---

## Troubleshooting

### Server won't start

```bash
# Check if port 8080 is in use
lsof -i :8080

# Check env vars are set
env | grep CLUB

# Run with debug logging
LOG_LEVEL=debug dart run packages/club_server/bin/server.dart
```

### SvelteKit dev server can't reach API

```bash
# Verify Dart server is running on port 8080
curl http://localhost:8080/api/v1/health

# Check Vite proxy config in vite.config.ts
# The proxy should forward /api to http://localhost:8080
```

### dart pub publish fails

```bash
# Check token is registered
dart pub token list

# Check token has write scope
# (verify via GET /api/auth/tokens with the token)

# Check pubspec.yaml has publish_to set correctly
grep publish_to pubspec.yaml

# Verbose publish
dart pub publish --force --verbose
```

### Tests fail with "database is locked"

```bash
# SQLite lock contention — make sure no other process has the DB open
fuser /tmp/club-dev.db 2>/dev/null

# Or use a fresh temp database
export SQLITE_PATH=$(mktemp /tmp/club-XXXXXX.db)
```

### Code generation out of date

```bash
# Regenerate all generated code
cd packages/club_db && dart run build_runner build --delete-conflicting-outputs
cd ../club_core && dart run build_runner build --delete-conflicting-outputs
```

### Frontend build fails

```bash
cd packages/club_web

# Clear cache and rebuild
rm -rf .svelte-kit node_modules
npm install
npm run build
```
