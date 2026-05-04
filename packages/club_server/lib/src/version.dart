/// Single source of truth for the server's version string.
///
/// Surfaced via `/api/v1/version` (public), the `/api/v1/health` body
/// (public), and the admin update-status endpoint.
///
/// Resolution order:
///   1. `--define=CLUB_SERVER_VERSION=<value>` at compile time (CI).
///   2. The [defaultValue] below, kept in lockstep with
///      `packages/club_server/pubspec.yaml` by `scripts/set-version.sh`.
///
/// Mirrors the [`clubCliVersion`] pattern in `packages/club_cli/lib/src/
/// version.dart` so the CI workflow can inject the tag at build time
/// without dirtying the working tree, and so the runtime advertised
/// version and the published binary version can never drift.
const String kServerVersion = String.fromEnvironment(
  'CLUB_SERVER_VERSION',
  defaultValue: '0.2.0',
);
