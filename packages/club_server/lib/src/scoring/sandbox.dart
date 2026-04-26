import 'dart:io';

/// Optional OS-level hardening layers applied to scoring subprocesses.
///
/// The three knobs compose, from innermost (closest to the pana binary) to
/// outermost (first `exec`'d by the parent):
///
///   commandPrefix  →  setpriv  →  bash -c 'ulimit …; exec …'  →  pana
///
/// All three default to inactive. Configure them from env vars in bootstrap:
///
/// - `SCORING_SANDBOX_PREFIX` — whitespace-separated argv (e.g.
///   `"bwrap --ro-bind / / --dev /dev --proc /proc --unshare-all"`).
///   Wraps the outer spawn. Ops layer for seccomp/userns/container tooling.
/// - `SCORING_SANDBOX_UID`, `SCORING_SANDBOX_GID` — numeric IDs to drop to
///   via `setpriv`. Linux only. Ignored if `setpriv` isn't on PATH or the
///   server doesn't have CAP_SETUID.
/// - `SCORING_SANDBOX_RLIMITS` — comma-separated `flag=value` pairs passed
///   to a `bash -c 'ulimit …'` wrapper. Example: `v=4000000,t=3600,n=1024`
///   caps virtual memory to 4 GB, CPU time to 1 h, open files to 1024.
///   Non-bash shells not supported.
///
/// On macOS dev machines, `setpriv` and `ulimit` (via bash) still work — the
/// GNU/util-linux flag semantics are what ship with bash on Darwin too —
/// but UID drops require the server to run as root, which is unusual in
/// dev. Leave these unset for dev; turn them on in the Docker image where
/// the entrypoint is root before dropping.
class SandboxConfig {
  const SandboxConfig({
    this.commandPrefix = const [],
    this.dropToUid,
    this.dropToGid,
    this.rlimits = const {},
  });

  /// No hardening — subprocess runs with the server's credentials. Default.
  static const SandboxConfig none = SandboxConfig();

  /// Raw argv prepended to the spawn. Applied outermost, so ops can front
  /// the child with anything: bwrap, firejail, systemd-run --scope, runc
  /// exec, runsc, nsenter, etc. Empty = no prefix.
  final List<String> commandPrefix;

  /// Numeric UID to drop to via `setpriv --reuid`. Linux (and macOS with
  /// util-linux-compat). Null = do not drop UID.
  final int? dropToUid;

  /// Numeric GID to drop to via `setpriv --regid`. Null = do not drop GID.
  final int? dropToGid;

  /// Resource limits applied via `bash -c 'ulimit …; exec "$@"'`. Keys are
  /// `ulimit` short flags (without the leading dash) like `v`, `t`, `n`,
  /// `u`, `f`, `c`. Values are ulimit-native units (usually KB for memory).
  final Map<String, int> rlimits;

  bool get _hasUidDrop => dropToUid != null || dropToGid != null;
  bool get _hasRlimits => rlimits.isNotEmpty;
  bool get _hasPrefix => commandPrefix.isNotEmpty;

  /// Whether any hardening layer is active. Useful for logging.
  bool get isActive => _hasPrefix || _hasUidDrop || _hasRlimits;

  /// One-line description of the active hardening, for log output.
  String describe() {
    if (!isActive) return 'none';
    final parts = <String>[];
    if (_hasPrefix) parts.add('prefix=${commandPrefix.join(" ")}');
    if (_hasUidDrop) {
      parts.add(
        'drop=${dropToUid ?? "-"}:${dropToGid ?? "-"}',
      );
    }
    if (_hasRlimits) {
      parts.add(
        'rlimits=${rlimits.entries.map((e) => "${e.key}=${e.value}").join(",")}',
      );
    }
    return parts.join(' ');
  }

  /// Build the final argv list for spawning [command].
  ///
  /// [command] is what would have run unwrapped: `[executable, ...args]`,
  /// e.g. `['/path/to/dart', 'packages/club_server/bin/scoring_subprocess.dart']`
  /// in dev, or `['/app/build/scoring_subprocess']` in prod.
  ///
  /// On non-Linux hosts the UID-drop layer is skipped (Linux-only tooling)
  /// but the prefix and rlimit layers are applied — bash is universal and
  /// prefix is ops' responsibility.
  List<String> wrap(List<String> command) {
    assert(command.isNotEmpty, 'command must not be empty');

    var result = List<String>.from(command);

    // Innermost: UID/GID drop. Linux-only; on other platforms we silently
    // skip so dev-on-macOS doesn't break.
    if (_hasUidDrop && Platform.isLinux) {
      final setpriv = <String>['setpriv'];
      if (dropToUid != null) setpriv.add('--reuid=$dropToUid');
      if (dropToGid != null) setpriv.add('--regid=$dropToGid');
      setpriv.add('--clear-groups');
      setpriv.add('--');
      result = [...setpriv, ...result];
    }

    // Middle: rlimits via bash. Works on Linux and macOS.
    if (_hasRlimits) {
      final ulimitCmds = rlimits.entries
          .map((e) => 'ulimit -${e.key} ${e.value}')
          .join(' && ');
      result = [
        'bash',
        '-c',
        '$ulimitCmds && exec "\$@"',
        'scoring-sandbox-rlimit', // $0 placeholder; not a real arg
        ...result,
      ];
    }

    // Outer: custom prefix. Applied last so it's the first exec'd.
    if (_hasPrefix) {
      result = [...commandPrefix, ...result];
    }

    return result;
  }

  /// Parse a config triple from env vars. Missing/empty values = no
  /// hardening for that layer.
  factory SandboxConfig.fromEnv(Map<String, String> env) {
    final prefixRaw = env['SCORING_SANDBOX_PREFIX'];
    final prefix = prefixRaw == null || prefixRaw.trim().isEmpty
        ? const <String>[]
        : prefixRaw.trim().split(RegExp(r'\s+'));

    final uid = _tryParseInt(env['SCORING_SANDBOX_UID']);
    final gid = _tryParseInt(env['SCORING_SANDBOX_GID']);

    final rlimitsRaw = env['SCORING_SANDBOX_RLIMITS'];
    final rlimits = <String, int>{};
    if (rlimitsRaw != null && rlimitsRaw.trim().isNotEmpty) {
      for (final pair in rlimitsRaw.split(',')) {
        final eq = pair.indexOf('=');
        if (eq <= 0) continue;
        final flag = pair.substring(0, eq).trim();
        final value = _tryParseInt(pair.substring(eq + 1).trim());
        if (flag.isEmpty || value == null) continue;
        rlimits[flag] = value;
      }
    }

    return SandboxConfig(
      commandPrefix: prefix,
      dropToUid: uid,
      dropToGid: gid,
      rlimits: rlimits,
    );
  }
}

int? _tryParseInt(String? s) {
  if (s == null || s.trim().isEmpty) return null;
  return int.tryParse(s.trim());
}
