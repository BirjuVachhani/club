# club — Client SDK (club_api)

`club_api` is a publishable Dart package that provides a typed client for
interacting with any club server programmatically.

---

## Installation

```yaml
# pubspec.yaml
dependencies:
  club_api: ^1.0.0
```

```bash
dart pub add club_api
```

---

## Quick Start

```dart
import 'package:club_api/club_api.dart';

void main() async {
  final client = ClubClient(
    serverUrl: Uri.parse('https://club.example.com'),
    token: 'club_a1b2c3d4e5f6...',
  );

  // List all versions of a package
  final pkg = await client.packages.listVersions('my_package');
  print('Latest: ${pkg.latest.version}');

  // Search for packages
  final results = await client.search.query('http');
  for (final hit in results.hits) {
    print('${hit.package} (score: ${hit.score})');
  }

  client.close();
}
```

---

## API Reference

### ClubClient

The main entry point. Provides access to all API sub-clients.

```dart
class ClubClient {
  /// Create a client for the given server.
  ///
  /// [serverUrl] — The club server URL (e.g., https://club.example.com)
  /// [token] — API token (club_...) or session JWT
  /// [httpClient] — Optional custom http.Client (for testing or proxies)
  ClubClient({
    required Uri serverUrl,
    required String token,
    http.Client? httpClient,
  });

  /// Package listing and metadata operations.
  PackagesClient get packages;

  /// Package publishing operations.
  PublishingClient get publishing;

  /// Authentication and token management.
  AuthClient get auth;

  /// Publisher management.
  PublishersClient get publishers;

  /// Search operations.
  SearchClient get search;

  /// Favorites / likes.
  LikesClient get likes;

  /// Admin operations (requires admin token).
  AdminClient get admin;

  /// Close the underlying HTTP client.
  void close();
}
```

---

### PackagesClient

```dart
class PackagesClient {
  /// List all versions of a package (pub spec v2 format).
  Future<PackageData> listVersions(String package);

  /// Get info for a specific version.
  Future<VersionInfo> getVersion(String package, String version);

  /// Download the tarball archive as a byte stream.
  Future<Stream<List<int>>> downloadArchive(String package, String version);

  /// Get package options (discontinued, unlisted).
  Future<PkgOptions> getOptions(String package);

  /// Set package options.
  Future<PkgOptions> setOptions(String package, PkgOptions options);

  /// Get version options (retracted).
  Future<VersionOptions> getVersionOptions(String package, String version);

  /// Set version options (retract/unretract).
  Future<VersionOptions> setVersionOptions(
      String package, String version, VersionOptions options);

  /// Get the publisher that owns this package.
  Future<PackagePublisherInfo> getPublisher(String package);

  /// Transfer package to a publisher.
  Future<PackagePublisherInfo> setPublisher(
      String package, String publisherId);

  /// Get uploaders for a package.
  Future<List<UploaderInfo>> getUploaders(String package);

  /// Add an uploader by email.
  Future<void> addUploader(String package, String email);

  /// Remove an uploader by email.
  Future<void> removeUploader(String package, String email);

  /// Get like count for a package.
  Future<int> getLikeCount(String package);

  /// Get package score (stub in v1).
  Future<VersionScore> getScore(String package, {String? version});

  /// Get all package names (for autocomplete).
  Future<List<String>> listAllNames();
}
```

---

### PublishingClient

```dart
class PublishingClient {
  /// Publish a package from a tarball file.
  ///
  /// This handles the full 3-step upload flow:
  /// 1. GET /api/packages/versions/new
  /// 2. POST tarball to the upload URL
  /// 3. GET finalize URL
  ///
  /// Returns the success message from the server.
  Future<String> publish(Stream<List<int>> tarballBytes, {int? length});

  /// Publish from a file path.
  Future<String> publishFile(String path);

  /// Start an upload session (step 1 only).
  /// Use this for custom upload flows.
  Future<UploadInfo> startUpload();

  /// Upload a tarball to the upload URL (step 2 only).
  Future<Uri> uploadArchive(
      UploadInfo uploadInfo, Stream<List<int>> bytes, {int? length});

  /// Finalize an upload (step 3 only).
  Future<String> finalizeUpload(Uri finalizeUrl);
}
```

---

### AuthClient

```dart
class AuthClient {
  /// Login with email and password. Returns an API token.
  /// Note: This creates a new ClubClient internally or returns a token
  /// that can be used to create one.
  Future<LoginResult> login(String email, String password);

  /// Logout (invalidates the session, not the API token).
  Future<void> logout();

  /// Create a new API token.
  Future<NewTokenResult> createToken({
    required String name,
    List<String> scopes = const ['read', 'write'],
    int? expiresInDays,
  });

  /// List all tokens for the current user.
  Future<List<TokenInfo>> listTokens();

  /// Revoke a token by ID.
  Future<void> revokeToken(String tokenId);
}

class LoginResult {
  final String token;
  final String userId;
  final String email;
  final String? displayName;
  final bool isAdmin;
  final DateTime expiresAt;
}

class NewTokenResult {
  final String id;
  final String name;
  final String secret;    // shown once
  final String prefix;
  final List<String> scopes;
  final DateTime createdAt;
  final DateTime? expiresAt;
}

class TokenInfo {
  final String id;
  final String name;
  final String prefix;
  final List<String> scopes;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? lastUsedAt;
}
```

---

### PublishersClient

```dart
class PublishersClient {
  /// Get publisher info.
  Future<PublisherInfo> get(String publisherId);

  /// Create a publisher (admin only).
  Future<PublisherInfo> create({
    required String id,
    required String displayName,
    String? description,
    String? websiteUrl,
    String? contactEmail,
  });

  /// Update publisher info.
  Future<PublisherInfo> update(String publisherId, {
    String? displayName,
    String? description,
    String? websiteUrl,
    String? contactEmail,
  });

  /// List members of a publisher.
  Future<List<PublisherMemberInfo>> listMembers(String publisherId);

  /// Add a member to a publisher.
  Future<void> addMember(String publisherId, String userId, {
    String role = 'member',
  });

  /// Remove a member from a publisher.
  Future<void> removeMember(String publisherId, String userId);
}
```

---

### SearchClient

```dart
class SearchClient {
  /// Search for packages.
  Future<SearchResult> query(
    String query, {
    int page = 1,
    SearchSort sort = SearchSort.relevance,
  });

  /// Get package name completion data.
  Future<List<String>> completionData();
}

enum SearchSort { relevance, updated, created, likes }

class SearchResult {
  final List<SearchHit> hits;
  final int totalCount;
  final int page;
  final int pageSize;
}

class SearchHit {
  final String package;
  final double score;
}
```

---

### LikesClient

```dart
class LikesClient {
  /// Like a package.
  Future<void> like(String package);

  /// Unlike a package.
  Future<void> unlike(String package);

  /// Get all liked packages for the current user.
  Future<List<String>> likedPackages();
}
```

---

### AdminClient

```dart
class AdminClient {
  /// List all users.
  Future<UserListResult> listUsers({int page = 1, String? emailFilter});

  /// Create a user.
  Future<UserInfo> createUser({
    required String email,
    required String password,
    String? displayName,
    bool isAdmin = false,
  });

  /// Update a user (enable/disable, promote/demote).
  Future<UserInfo> updateUser(String userId, {
    bool? isActive,
    bool? isAdmin,
  });

  /// Delete a package.
  Future<void> deletePackage(String package);

  /// Delete a specific version.
  Future<void> deleteVersion(String package, String version);
}
```

---

## Shared Models

`club_api` re-exports the pub spec v2 DTOs from `club_core`:

- `PackageData` — package with all versions
- `VersionInfo` — single version metadata
- `UploadInfo` — upload URL and fields
- `SuccessMessage` — success response wrapper
- `PkgOptions` — package options (discontinued, unlisted)
- `VersionOptions` — version options (retracted)
- `PackagePublisherInfo` — publisher ownership
- `VersionScore` — scoring data (stub in v1)

---

## Error Handling

All client methods throw typed exceptions:

```dart
try {
  await client.packages.listVersions('nonexistent');
} on ClubNotFoundException catch (e) {
  print('Package not found: ${e.message}');
} on ClubAuthException catch (e) {
  print('Auth failed: ${e.message}');
} on ClubApiException catch (e) {
  print('API error ${e.code}: ${e.message}');
}
```

Exception hierarchy:

```
ClubApiException
  ├── ClubNotFoundException       (404)
  ├── ClubAuthException           (401)
  ├── ClubForbiddenException      (403)
  ├── ClubBadRequestException     (400)
  ├── ClubConflictException       (409)
  └── ClubServerException         (500)
```

---

## Configuration

### Custom HTTP Client

```dart
// Use a custom HTTP client (e.g., for proxies or testing)
final httpClient = http.Client();
final client = ClubClient(
  serverUrl: Uri.parse('https://club.example.com'),
  token: 'club_...',
  httpClient: httpClient,
);
```

### Token from Environment Variable

```dart
final client = ClubClient(
  serverUrl: Uri.parse(Platform.environment['SERVER_URL']!),
  token: Platform.environment['CLUB_TOKEN']!,
);
```

---

## Examples

### CI/CD: Publish a Package

```dart
import 'dart:io';
import 'package:club_api/club_api.dart';

Future<void> main() async {
  final client = ClubClient(
    serverUrl: Uri.parse(Platform.environment['SERVER_URL']!),
    token: Platform.environment['CLUB_TOKEN']!,
  );

  try {
    final message = await client.publishing.publishFile('build/my_package.tar.gz');
    print(message);
  } on ClubApiException catch (e) {
    stderr.writeln('Publish failed: ${e.message}');
    exit(1);
  } finally {
    client.close();
  }
}
```

### Dashboard: List All Packages with Stats

```dart
import 'package:club_api/club_api.dart';

Future<void> main() async {
  final client = ClubClient(
    serverUrl: Uri.parse('https://club.example.com'),
    token: 'club_...',
  );

  final names = await client.packages.listAllNames();
  for (final name in names) {
    final pkg = await client.packages.listVersions(name);
    final likes = await client.packages.getLikeCount(name);
    print('$name: ${pkg.versions.length} versions, $likes likes');
  }

  client.close();
}
```

### Batch Retract Versions

```dart
import 'package:club_api/club_api.dart';

Future<void> retractVersions(
  ClubClient client,
  String package,
  List<String> versions,
) async {
  for (final version in versions) {
    await client.packages.setVersionOptions(
      package, version, VersionOptions(isRetracted: true),
    );
    print('Retracted $package $version');
  }
}
```

---

## Package Structure

```
packages/club_api/
├── lib/
│   ├── src/
│   │   ├── club_client.dart       # ClubClient — main entry point
│   │   ├── packages.dart           # PackagesClient
│   │   ├── publishing.dart         # PublishingClient (3-step upload flow)
│   │   ├── auth.dart               # AuthClient (login, tokens)
│   │   ├── publishers.dart         # PublishersClient
│   │   ├── search.dart             # SearchClient
│   │   ├── likes.dart              # LikesClient
│   │   ├── admin.dart              # AdminClient
│   │   └── exceptions.dart         # ClubApiException hierarchy
│   └── club_api.dart              # Barrel export
├── pubspec.yaml
└── test/
    ├── club_client_test.dart
    ├── packages_test.dart
    └── publishing_test.dart
```

### Dependencies

```yaml
dependencies:
  http: ^1.2.0
  http_parser: ^4.0.2      # Multipart form encoding
  club_core:               # Shared models and DTOs
    path: ../club_core
  crypto: ^3.0.3            # SHA-256 for archive verification
```

When published to pub.dev (or club), the `club_core` path dependency
would be replaced with a version constraint:

```yaml
dependencies:
  http: ^1.2.0
  http_parser: ^4.0.2
  club_core: ^1.0.0
  crypto: ^3.0.3
```
