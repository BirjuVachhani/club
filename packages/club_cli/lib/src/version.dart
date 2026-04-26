/// Version string burned in at build time.
///
/// Set with `dart compile exe --define=CLUB_CLI_VERSION=<value> ...` (used by
/// `scripts/build-cli.sh`). Falls back to `dev` when the CLI is run via
/// `dart run` or when no value is provided at compile time, so a developer
/// running the source tree always sees `dev`.
const String clubCliVersion = String.fromEnvironment(
  'CLUB_CLI_VERSION',
  defaultValue: 'dev',
);
