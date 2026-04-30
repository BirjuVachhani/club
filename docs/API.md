# club — API Reference

All endpoints require authentication unless noted otherwise.
Authentication is via `Authorization: Bearer <token>` header.

---

## Table of Contents

- [Pub Repository Spec v2 Endpoints](#pub-repository-spec-v2-endpoints)
- [Authentication API](#authentication-api)
- [Package Admin API](#package-admin-api)
- [Publisher API](#publisher-api)
- [Favorites API](#favorites-api)
- [Search API](#search-api)
- [Admin API](#admin-api)
- [Health API](#health-api)
- [Common Response Formats](#common-response-formats)

---

## Pub Repository Spec v2 Endpoints

These endpoints implement the
[Dart Pub Repository Specification v2](https://github.com/dart-lang/pub/blob/master/doc/repository-spec-v2.md).
They are consumed by `dart pub get`, `dart pub publish`, and `dart pub add`.

### Standard Headers

**Request:**
```
Accept: application/vnd.pub.v2+json
Authorization: Bearer <token>
```

**Response:**
```
Content-Type: application/vnd.pub.v2+json
```

---

### List All Versions of a Package

```
GET /api/packages/<package>
```

Returns all versions of a package. This is the primary endpoint used by
`dart pub get` for dependency resolution.

**Response: `200 OK`**
```json
{
  "name": "my_package",
  "isDiscontinued": false,
  "replacedBy": null,
  "latest": {
    "version": "2.1.0",
    "retracted": false,
    "archive_url": "https://club.example.com/api/archives/my_package-2.1.0.tar.gz",
    "archive_sha256": "a1b2c3d4e5f6...",
    "pubspec": {
      "name": "my_package",
      "version": "2.1.0",
      "description": "A useful package",
      "environment": { "sdk": ">=3.0.0 <4.0.0" },
      "dependencies": { "http": "^1.0.0" }
    },
    "published": "2026-04-01T10:00:00.000Z"
  },
  "versions": [
    {
      "version": "1.0.0",
      "retracted": false,
      "archive_url": "https://club.example.com/api/archives/my_package-1.0.0.tar.gz",
      "archive_sha256": "f6e5d4c3b2a1...",
      "pubspec": { "..." },
      "published": "2026-01-15T08:30:00.000Z"
    },
    {
      "version": "2.0.0",
      "retracted": true,
      "archive_url": "https://club.example.com/api/archives/my_package-2.0.0.tar.gz",
      "archive_sha256": "1a2b3c4d5e6f...",
      "pubspec": { "..." },
      "published": "2026-03-01T12:00:00.000Z"
    },
    {
      "version": "2.1.0",
      "retracted": false,
      "archive_url": "https://club.example.com/api/archives/my_package-2.1.0.tar.gz",
      "archive_sha256": "a1b2c3d4e5f6...",
      "pubspec": { "..." },
      "published": "2026-04-01T10:00:00.000Z"
    }
  ]
}
```

**Notes:**
- Versions are sorted in ascending semantic version order
- `latest` is the latest non-prerelease, non-retracted version
- `archive_url` is an absolute URL to download the tarball
- `archive_sha256` is a hex-encoded SHA-256 of the tarball
- `published` is ISO 8601 UTC timestamp
- `isDiscontinued` and `replacedBy` are only present when applicable
- `retracted` is only present when `true`

**Errors:**
- `404` — Package not found

---

### Inspect a Specific Version (Deprecated)

```
GET /api/packages/<package>/versions/<version>
```

**Response: `200 OK`**
```json
{
  "version": "2.1.0",
  "retracted": false,
  "archive_url": "https://club.example.com/api/archives/my_package-2.1.0.tar.gz",
  "archive_sha256": "a1b2c3d4e5f6...",
  "pubspec": { "..." },
  "published": "2026-04-01T10:00:00.000Z"
}
```

**Errors:**
- `404` — Package or version not found

---

### Download a Package Archive

```
GET /api/archives/<package>-<version>.tar.gz
```

Returns the `.tar.gz` archive. Depending on the blob storage backend:
- **Filesystem**: streams the file directly (200 with `application/gzip`)
- **S3**: redirects to a pre-signed URL (302)

**Response: `200 OK`** (filesystem backend)
```
Content-Type: application/gzip
Content-Length: 45678
<binary tarball bytes>
```

**Response: `302 Found`** (S3 backend)
```
Location: https://s3.example.com/bucket/my_package-2.1.0.tar.gz?X-Amz-Signature=...
```

---

### Legacy Download Redirect

```
GET /packages/<package>/versions/<version>.tar.gz
GET /api/packages/<package>/versions/<version>/archive.tar.gz
```

Both redirect to `/api/archives/<package>-<version>.tar.gz`.

**Response: `303 See Other`**
```
Location: /api/archives/<package>-<version>.tar.gz
```

---

### Start Package Upload

```
GET /api/packages/versions/new
Authorization: Bearer <token>
```

Initiates the publish flow. Returns upload URL and form fields.

**Response: `200 OK`**
```json
{
  "url": "https://club.example.com/api/packages/versions/upload",
  "fields": {
    "upload_id": "550e8400-e29b-41d4-a716-446655440000"
  }
}
```

**Notes:**
- The `url` points back to the club server itself (self-hosted upload)
- The `fields` map contains `upload_id` which must be included in the multipart POST
- Upload sessions expire after 10 minutes

**Errors:**
- `401` — Not authenticated
- `429` — Rate limit exceeded (max 3 concurrent upload sessions per user)

---

### Upload Package Archive

```
POST /api/packages/versions/upload
Content-Type: multipart/form-data
Authorization: Bearer <token>

--boundary
Content-Disposition: form-data; name="upload_id"

550e8400-e29b-41d4-a716-446655440000
--boundary
Content-Disposition: form-data; name="file"; filename="package.tar.gz"
Content-Type: application/gzip

<binary tarball bytes>
--boundary--
```

The tarball is streamed to a temp file on disk (never buffered in memory).

**Response: `302 Found`**
```
Location: /api/packages/versions/newUploadFinish?upload_id=550e8400-e29b-41d4-a716-446655440000
```

The `dart pub` client follows this redirect automatically.

**Errors:**
- `400` — Missing upload_id or file
- `401` — Not authenticated
- `413` — Tarball exceeds max upload size (default 100 MB)

---

### Finalize Package Upload

```
GET /api/packages/versions/newUploadFinish?upload_id=<guid>
Authorization: Bearer <token>
```

Validates the uploaded tarball, stores it permanently, and creates the
package/version records.

**Response: `200 OK`**
```json
{
  "success": {
    "message": "Successfully uploaded my_package version 2.1.0."
  }
}
```

**Validation performed:**
1. Valid `.tar.gz` format
2. Contains valid `pubspec.yaml`
3. Package name is valid (lowercase alphanumeric + underscore, 1-64 chars)
4. Version is canonical semver
5. User is authorized (uploader or publisher admin)
6. Version does not already exist (unless SHA-256 matches — idempotent)
7. Archive size within limits

**Errors:**
- `400` — Validation failed
  ```json
  {"error": {"code": "PackageRejected", "message": "Version 2.1.0 already exists."}}
  ```
- `401` — Not authenticated
- `403` — Not authorized to publish this package

---

## Authentication API

### Login

```
POST /api/auth/login
Content-Type: application/json
```

**No authentication required.**

**Request:**
```json
{
  "email": "user@example.com",
  "password": "secret123"
}
```

**Response: `200 OK`**
```json
{
  "token": "club_a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
  "userId": "550e8400-e29b-41d4-a716-446655440000",
  "email": "user@example.com",
  "displayName": "Jane Doe",
  "isAdmin": false,
  "expiresAt": "2027-04-09T10:00:00.000Z"
}
```

**Notes:**
- Returns an API token (not a JWT session)
- The token is shown once and never retrievable again
- Also sets an HttpOnly session cookie for web UI access

**Errors:**
- `401` — Invalid email or password

---

### Logout

```
POST /api/auth/logout
Authorization: Bearer <token>
```

Clears the session cookie. Does not revoke the API token.

**Response: `200 OK`**
```json
{"status": "ok"}
```

---

### Create API Token

```
POST /api/auth/tokens
Authorization: Bearer <token>
Content-Type: application/json
```

**Request:**
```json
{
  "name": "CI/CD Deploy Token",
  "scopes": ["read", "write"],
  "expiresInDays": 365
}
```

**Response: `201 Created`**
```json
{
  "id": "tok_a1b2c3d4",
  "name": "CI/CD Deploy Token",
  "secret": "club_x9y8z7w6v5u4t3s2r1q0p9o8n7m6l5k4",
  "prefix": "club_x9",
  "scopes": ["read", "write"],
  "createdAt": "2026-04-09T10:00:00.000Z",
  "expiresAt": "2027-04-09T10:00:00.000Z"
}
```

**Notes:**
- `secret` is shown **once** and never retrievable again
- `prefix` is stored for display identification
- `scopes`: `read` (download packages), `write` (publish), `admin` (admin operations)
- `expiresInDays`: optional, default from `CLUB_TOKEN_EXPIRY_DAYS` (365)

---

### List API Tokens

```
GET /api/auth/tokens
Authorization: Bearer <token>
```

**Response: `200 OK`**
```json
{
  "tokens": [
    {
      "id": "tok_a1b2c3d4",
      "name": "CI/CD Deploy Token",
      "prefix": "club_x9",
      "scopes": ["read", "write"],
      "createdAt": "2026-04-09T10:00:00.000Z",
      "expiresAt": "2027-04-09T10:00:00.000Z",
      "lastUsedAt": "2026-04-09T14:30:00.000Z"
    }
  ]
}
```

**Notes:**
- Never returns the raw token
- Shows prefix for identification
- `lastUsedAt` is null if never used

---

### Revoke API Token

```
DELETE /api/auth/tokens/<tokenId>
Authorization: Bearer <token>
```

**Response: `200 OK`**
```json
{"status": "ok"}
```

**Errors:**
- `404` — Token not found or belongs to another user

---

## Package Admin API

### Get Package Options

```
GET /api/packages/<package>/options
Authorization: Bearer <token>
```

**Response: `200 OK`**
```json
{
  "isDiscontinued": false,
  "replacedBy": null,
  "isUnlisted": false
}
```

---

### Set Package Options

```
PUT /api/packages/<package>/options
Authorization: Bearer <token>
Content-Type: application/json
```

Requires: package uploader, publisher admin, or server admin.

**Request:**
```json
{
  "isDiscontinued": true,
  "replacedBy": "new_package"
}
```

**Response: `200 OK`** (returns updated options)

---

### Get Version Options

```
GET /api/packages/<package>/versions/<version>/options
Authorization: Bearer <token>
```

**Response: `200 OK`**
```json
{
  "isRetracted": false
}
```

---

### Set Version Options (Retract/Unretract)

```
PUT /api/packages/<package>/versions/<version>/options
Authorization: Bearer <token>
Content-Type: application/json
```

Requires: package uploader, publisher admin, or server admin.

**Request:**
```json
{
  "isRetracted": true
}
```

**Response: `200 OK`** (returns updated options)

---

### Get Package Uploaders

```
GET /api/packages/<package>/uploaders
Authorization: Bearer <token>
```

Requires: package uploader, publisher admin, or server admin.

**Response: `200 OK`**
```json
{
  "uploaders": [
    {
      "userId": "550e8400-e29b-41d4-a716-446655440000",
      "email": "jane@example.com",
      "displayName": "Jane Doe"
    }
  ]
}
```

---

### Add Package Uploader

```
PUT /api/packages/<package>/uploaders/<email>
Authorization: Bearer <token>
```

Requires: package uploader, publisher admin, or server admin.

**Response: `200 OK`**
```json
{
  "uploaders": [ "..." ]
}
```

**Errors:**
- `404` — User with that email not found
- `409` — User is already an uploader

---

### Remove Package Uploader

```
DELETE /api/packages/<package>/uploaders/<email>
Authorization: Bearer <token>
```

**Errors:**
- `400` — Cannot remove the last uploader

---

### Set Package Publisher

```
PUT /api/packages/<package>/publisher
Authorization: Bearer <token>
Content-Type: application/json
```

Requires: current package uploader AND publisher admin.

**Request:**
```json
{
  "publisherId": "acme"
}
```

**Response: `200 OK`**
```json
{
  "publisherId": "acme"
}
```

---

## Publisher API

### Create Publisher

```
POST /api/publishers
Authorization: Bearer <token>
Content-Type: application/json
```

Requires: server admin.

**Request:**
```json
{
  "id": "acme",
  "displayName": "Acme Corp",
  "description": "Internal packages for Acme Corp",
  "websiteUrl": "https://acme.example.com",
  "contactEmail": "dev@acme.example.com"
}
```

**Response: `201 Created`**
```json
{
  "publisherId": "acme",
  "displayName": "Acme Corp",
  "description": "Internal packages for Acme Corp",
  "websiteUrl": "https://acme.example.com",
  "contactEmail": "dev@acme.example.com",
  "createdAt": "2026-04-09T10:00:00.000Z"
}
```

---

### Get Publisher Info

```
GET /api/publishers/<publisherId>
Authorization: Bearer <token>
```

**Response: `200 OK`** (same format as create response)

---

### Update Publisher

```
PUT /api/publishers/<publisherId>
Authorization: Bearer <token>
Content-Type: application/json
```

Requires: publisher admin or server admin.

---

### List Publisher Members

```
GET /api/publishers/<publisherId>/members
Authorization: Bearer <token>
```

**Response: `200 OK`**
```json
{
  "members": [
    {
      "userId": "550e8400-...",
      "email": "jane@example.com",
      "displayName": "Jane Doe",
      "role": "admin"
    }
  ]
}
```

---

### Add Publisher Member

```
PUT /api/publishers/<publisherId>/members/<userId>
Authorization: Bearer <token>
Content-Type: application/json
```

Requires: publisher admin or server admin.

**Request:**
```json
{
  "role": "member"
}
```

---

### Remove Publisher Member

```
DELETE /api/publishers/<publisherId>/members/<userId>
Authorization: Bearer <token>
```

---

## Favorites API

### Like a Package

```
PUT /api/account/likes/<package>
Authorization: Bearer <token>
```

**Response: `200 OK`**
```json
{
  "package": "my_package",
  "liked": true
}
```

---

### Unlike a Package

```
DELETE /api/account/likes/<package>
Authorization: Bearer <token>
```

**Response: `200 OK`**
```json
{
  "package": "my_package",
  "liked": false
}
```

---

### List Liked Packages

```
GET /api/account/likes
Authorization: Bearer <token>
```

**Response: `200 OK`**
```json
{
  "likedPackages": [
    { "package": "my_package", "liked": true },
    { "package": "other_package", "liked": true }
  ]
}
```

---

### Get Package Like Count

```
GET /api/packages/<package>/likes
Authorization: Bearer <token>
```

**Response: `200 OK`**
```json
{
  "package": "my_package",
  "likes": 42
}
```

---

## Search API

### Search Packages

```
GET /api/search?q=<query>&page=<n>&sort=<field>
Authorization: Bearer <token>
```

**Query Parameters:**

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `q` | string | — | Search query (supports tag filters) |
| `page` | int | 1 | Page number (1-indexed) |
| `sort` | string | `relevance` | Sort: `relevance`, `updated`, `created`, `likes` |

**Query Syntax:**
- `http client` — full-text search
- `sdk:dart` — filter by SDK
- `platform:android` — filter by platform
- `is:discontinued` — filter by status
- Combinable: `http sdk:flutter platform:web`

**Response: `200 OK`**
```json
{
  "packages": [
    {
      "package": "http",
      "score": 0.95
    },
    {
      "package": "http_parser",
      "score": 0.82
    }
  ],
  "totalCount": 42,
  "page": 1,
  "pageSize": 20
}
```

---

### Package Name Completion

```
GET /api/package-name-completion-data
Authorization: Bearer <token>
```

**Response: `200 OK`**
```json
{
  "packages": ["http", "http_parser", "my_package", "..."]
}
```

---

## Admin API

All admin endpoints require server admin role.

### List Users

```
GET /api/admin/users?page=<n>&email=<filter>
Authorization: Bearer <admin-token>
```

**Response: `200 OK`**
```json
{
  "users": [
    {
      "userId": "550e8400-...",
      "email": "jane@example.com",
      "displayName": "Jane Doe",
      "isAdmin": false,
      "isActive": true,
      "createdAt": "2026-01-01T00:00:00.000Z"
    }
  ],
  "totalCount": 15,
  "page": 1
}
```

---

### Create User

```
POST /api/admin/users
Authorization: Bearer <admin-token>
Content-Type: application/json
```

**Request:**
```json
{
  "email": "newuser@example.com",
  "password": "initial-password",
  "displayName": "New User",
  "isAdmin": false
}
```

**Response: `201 Created`**

---

### Update User

```
PUT /api/admin/users/<userId>
Authorization: Bearer <admin-token>
Content-Type: application/json
```

**Request:**
```json
{
  "isActive": false,
  "isAdmin": true
}
```

---

### Delete Package (Admin)

```
DELETE /api/admin/packages/<package>
Authorization: Bearer <admin-token>
```

Permanently deletes a package and all its versions/tarballs.

---

### Delete Package Version (Admin)

```
DELETE /api/admin/packages/<package>/versions/<version>
Authorization: Bearer <admin-token>
```

---

## Health API

### Health Check

```
GET /api/v1/health
```

**No authentication required.**

**Response: `200 OK`** (all healthy)
```json
{
  "status": "ok",
  "checks": {
    "metadata_store": { "status": "ok", "latencyMs": 2 },
    "blob_store": { "status": "ok", "latencyMs": 5 },
    "search_index": { "status": "ok", "latencyMs": 1 }
  },
  "version": "1.0.0",
  "timestamp": "2026-04-09T10:00:00.000Z"
}
```

**Response: `503 Service Unavailable`** (degraded)
```json
{
  "status": "degraded",
  "checks": {
    "metadata_store": { "status": "ok", "latencyMs": 2 },
    "blob_store": { "status": "error", "message": "disk full" },
    "search_index": { "status": "ok", "latencyMs": 1 }
  }
}
```

---

## Common Response Formats

### Success Message

```json
{
  "success": {
    "message": "Operation completed successfully."
  }
}
```

### Error Response

```json
{
  "error": {
    "code": "NotFound",
    "message": "Package 'nonexistent' was not found."
  }
}
```

### Error Codes

| Code | HTTP Status | Description |
|------|-------------|-------------|
| `MissingAuthentication` | 401 | No or invalid Bearer token |
| `InsufficientPermissions` | 403 | Token lacks required scope/role |
| `NotFound` | 404 | Resource does not exist |
| `InvalidInput` | 400 | Malformed request body or parameters |
| `PackageRejected` | 400 | Package upload validation failed |
| `Conflict` | 409 | Resource already exists |
| `RateLimitExceeded` | 429 | Too many requests |
| `InternalError` | 500 | Unexpected server error |

### 401 Response Headers

Per the pub spec, 401 responses include:

```
WWW-Authenticate: Bearer realm="pub", message="Authentication required."
```

### Pagination

List endpoints that support pagination use:

```json
{
  "items": [ "..." ],
  "totalCount": 100,
  "page": 1,
  "pageSize": 20
}
```

Page numbers are 1-indexed. Default page size is 20.

---

## Web Routes

These routes serve HTML pages (not JSON API). They all require an
authenticated session cookie and redirect to `/login` if absent.

| Method | Route | Description |
|--------|-------|-------------|
| GET | `/` | Redirect to `/packages` |
| GET | `/login` | Login page (no auth required) |
| POST | `/login` | Process login form |
| GET | `/logout` | Clear session, redirect to `/login` |
| GET | `/packages` | Package listing with search |
| GET | `/packages/<pkg>` | Package detail (readme tab) |
| GET | `/packages/<pkg>/changelog` | Changelog tab |
| GET | `/packages/<pkg>/versions` | Versions tab |
| GET | `/packages/<pkg>/install` | Install tab |
| GET | `/packages/<pkg>/admin` | Admin tab |
| GET | `/packages/<pkg>/versions/<v>` | Version detail |
| GET | `/publishers` | Publisher list |
| GET | `/publishers/<id>` | Publisher detail |
| GET | `/my-packages` | Current user's packages |
| GET | `/my-liked-packages` | Current user's favorites |
| GET | `/settings/tokens` | Token management |
| POST | `/settings/tokens` | Create token (form) |
| POST | `/settings/tokens/<id>/revoke` | Revoke token (form) |
| GET | `/admin/users` | Admin: user list |
| GET | `/admin/packages` | Admin: package list |
| GET | `/static/<path>` | Static assets (CSS, JS, images) |
