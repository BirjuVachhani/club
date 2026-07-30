/// The one-line "a newer club is available" hint.
///
/// Runs after a command has already done its work, so a slow or failing
/// GitHub call can never delay or break what the user actually asked for.
/// At most one network call per [updateCheckInterval]; every other run
/// answers from the cache.
library;

import 'dart:async';
import 'dart:io';

import '../util/log.dart';
import '../util/prompt.dart';
import '../version.dart';
import 'release_resolver.dart';
import 'release_target.dart';
import 'update_check_cache.dart';
import 'upgrade_decision.dart';

/// Commands that must never print the hint.
///
/// `mcp` speaks JSON-RPC on stdout, and `upgrade` reports version state
/// itself, so a second opinion from the cache would just be noise.
const _excludedCommands = {'mcp', 'upgrade'};

/// Set `NO_UPDATE_CHECK` to silence the hint entirely.
const noUpdateCheckEnvVar = 'NO_UPDATE_CHECK';

/// Whether the hint should run at all for this invocation.
///
/// Pure so the skip rules are testable without a network or a clock.
bool shouldCheckForUpdates({
  required String runningVersion,
  required String? command,
  required bool stdoutSilenced,
  required bool inCI,
  required Map<String, String> environment,
}) {
  if (stdoutSilenced) return false;
  if (inCI) return false;
  if (environment.containsKey(noUpdateCheckEnvVar)) return false;

  // No command at all means `club`, `club --version`, or `club --help`.
  // The first two are parsed by scripts (install.sh greps `club --version`,
  // and build-cli.yml compares its whole output against the expected
  // version), so an extra line on stdout there is not cosmetic, it breaks
  // things. The third is already a wall of text.
  if (command == null) return false;
  if (_excludedCommands.contains(command)) return false;

  // A source checkout or a local build-cli.sh build has nothing to
  // upgrade to, and nagging a developer about their own binary is noise.
  if (isDevSourceVersion(runningVersion)) return false;
  final running = tryParseVersion(runningVersion);
  if (running == null || running.isPreRelease) return false;

  return true;
}

/// Prints the hint when a newer release exists, refreshing the cache at
/// most once per [updateCheckInterval].
///
/// Never throws: the caller has already finished its real work, and a
/// failure here must not change the command's exit code.
Future<void> maybeNotifyOfUpdate({
  required String? command,
  UpdateCheckCache? cache,
  ReleaseResolver? resolver,
  DateTime? now,
  Map<String, String>? environment,
}) async {
  try {
    final env = environment ?? _platformEnv();
    if (!shouldCheckForUpdates(
      runningVersion: clubCliVersion,
      command: command,
      stdoutSilenced: silenceStdout,
      inCI: isCI,
      environment: env,
    )) {
      return;
    }

    final store = cache ?? UpdateCheckCache();
    final at = now ?? DateTime.now();
    final cached = store.read();

    String? latest;
    if (cached != null && cached.isFreshAt(at)) {
      latest = cached.latest;
    } else {
      latest = await _refresh(store, resolver, at);
    }

    if (latest == null) return;
    final running = tryParseVersion(clubCliVersion);
    final newest = tryParseVersion(latest);
    if (running == null || newest == null || newest <= running) return;

    hint('A newer club is available: '
        '${gray(clubCliVersion)} → ${green(latest)}. Run: club upgrade');
  } on Object {
    // Best effort by design. Whatever the user ran has already succeeded.
  }
}

/// Fetches the newest installable version and records it.
///
/// Returns null when there is nothing to report, including when the
/// newest release exists but its build artifacts have not been uploaded
/// yet. Caching the gated answer rather than the raw tag is what stops the
/// hint advertising a version that `club upgrade` would then decline to
/// install.
Future<String?> _refresh(
  UpdateCheckCache store,
  ReleaseResolver? injected,
  DateTime at,
) async {
  final resolver = injected ??
      GithubReleaseResolver(timeout: const Duration(seconds: 2));
  try {
    final result = await resolver.resolveLatest(includePreReleases: false);
    String? latest;
    if (result.ok) {
      final target = detectTarget();
      if (target != null && result.release!.hasAssetsFor(target)) {
        latest = result.release!.version;
      }
    }
    // Record the attempt either way, so an unreachable GitHub does not
    // mean a network call on every single invocation.
    store.write(UpdateCheckRecord(checkedAt: at, latest: latest));
    return latest;
  } on Object {
    return null;
  } finally {
    if (injected == null) resolver.close();
  }
}

Map<String, String> _platformEnv() => Platform.environment;
