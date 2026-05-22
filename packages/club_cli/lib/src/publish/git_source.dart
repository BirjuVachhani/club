/// Git repository source for `club publish --from-git`.
///
/// Clones (or refreshes) a git repository into a cache directory under
/// `~/.club/clones/<host>/<org…>/<repo>` so it can be published exactly
/// like a normal local package. Everything downstream of [prepareGitClone]
/// — `dart pub get`, validation, tarball, upload — is the unchanged publish
/// flow operating on the clone directory.
///
/// A directory left over from a previous run is reused: the remote is
/// re-fetched and the working tree is forced back to a pristine checkout
/// of the requested ref (hard reset + `git clean`), so a reused clone can
/// never carry stale state into a publish.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../util/log.dart';

/// A prepared git clone ready to be published.
class GitClone {
  GitClone({required this.url, required this.root, required this.ref});

  /// The git URL that was cloned.
  final String url;

  /// Absolute path to the local clone directory (the repository root).
  final String root;

  /// The branch, tag, or commit that is checked out.
  final String ref;
}

/// Thrown when a git operation fails. Carries a user-facing [message] and
/// an optional actionable [hint].
class GitSourceError implements Exception {
  GitSourceError(this.message, {this.hint});

  final String message;
  final String? hint;

  @override
  String toString() => message;
}

/// Clones [url] into the clone cache — or refreshes an existing clone — and
/// checks out [ref] (a branch, tag, or commit). When [ref] is null/empty
/// the remote default branch is used.
///
/// Returns a [GitClone] describing the local checkout. Throws
/// [GitSourceError] on any failure (missing `git`, bad URL, network error,
/// unknown ref).
Future<GitClone> prepareGitClone({required String url, String? ref}) async {
  await _ensureGitAvailable();

  final parts = _parseGitUrl(url);
  final root = _cloneRootFor(parts);
  final wantRef = (ref ?? '').trim();

  heading('Preparing git source');
  detail('repo: ${bold(parts.segments.join('/'))} ${gray('(${parts.host})')}');
  detail('cache: $root');

  final exists = Directory(root).existsSync();
  final reusable = exists && await _isMatchingRepo(root, url);

  if (exists && !reusable) {
    // Stale, corrupt, or pointing at a different remote — start clean.
    detail(gray('existing directory is not a reusable clone; recreating'));
    _deleteDir(root);
  }

  final sw = Stopwatch()..start();
  if (reusable) {
    detail('reusing existing clone, fetching latest…');
    await _git(
      ['fetch', 'origin', '--prune', '--tags', '--force'],
      cwd: root,
      action: 'fetch updates for',
    );
  } else {
    Directory(p.dirname(root)).createSync(recursive: true);
    detail('cloning…');
    await _git(['clone', url, root], action: 'clone');
  }

  final checkedOut = await _checkout(root, wantRef);
  final sha = await _runOutput(['rev-parse', '--short', 'HEAD'], cwd: root);
  sw.stop();
  detail(
    '${green('✓')} ${reusable ? 'updated' : 'cloned'}, '
    'checked out ${cyan(checkedOut)}'
    '${sha == null ? '' : gray(' ($sha)')} '
    '${gray('(${formatDuration(sw.elapsed)})')}',
  );

  return GitClone(url: url, root: root, ref: checkedOut);
}

/// Deletes the clone at [root] and prunes now-empty parent directories up
/// to (but not including) `~/.club/clones`. Best-effort — never throws.
void deleteGitClone(String root) {
  try {
    _deleteDir(root);
  } catch (_) {
    // Best-effort; ignore failures and still attempt to prune parents.
  }
  // Prune empty org/host directories left behind, stopping at `clones`
  // (and never walking past the filesystem root).
  try {
    var parent = Directory(p.dirname(root));
    while (parent.path != parent.parent.path) {
      if (p.basename(parent.path) == 'clones') break;
      if (parent.existsSync() && parent.listSync().isNotEmpty) break;
      if (parent.existsSync()) parent.deleteSync();
      parent = parent.parent;
    }
  } catch (_) {
    // Best-effort cleanup; ignore failures.
  }
}

// ── Checkout ────────────────────────────────────────────────────────────────

/// Forces the working tree at [root] onto a pristine checkout of [wantRef]
/// (or the remote default branch when [wantRef] is empty), discarding any
/// local commits, modifications, and untracked/ignored files.
///
/// Returns the name of the ref that was checked out.
Future<String> _checkout(String root, String wantRef) async {
  final target = wantRef.isEmpty ? await _defaultBranch(root) : wantRef;

  // A remote-tracking branch is reset to the remote tip (force-recreating
  // the local branch so any divergence is discarded). A tag or commit is
  // checked out detached.
  final isBranch = await _runOk(
    ['show-ref', '--verify', '--quiet', 'refs/remotes/origin/$target'],
    cwd: root,
  );

  if (isBranch) {
    await _git(
      ['checkout', '--force', '-B', target, 'origin/$target'],
      cwd: root,
      action: 'check out branch "$target" in',
    );
  } else {
    final resolves = await _runOk(
      ['rev-parse', '--verify', '--quiet', '$target^{commit}'],
      cwd: root,
    );
    if (!resolves) {
      throw GitSourceError(
        'Git ref "$target" was not found in the repository.',
        hint: 'Pass a valid branch, tag, or commit via --ref.',
      );
    }
    // Detached checkout of a tag/commit. The follow-up hard reset clears
    // any index or in-progress-operation state a previously interrupted
    // run could have left behind, so the working tree is truly pristine.
    await _git(
      ['checkout', '--force', target],
      cwd: root,
      action: 'check out "$target" in',
    );
    await _git(['reset', '--hard', target], cwd: root, action: 'reset');
  }

  // Discard untracked + ignored files (stale .dart_tool, build/, lockfiles)
  // so the publish sees exactly what is committed at [target].
  await _git(
    ['clean', '-ffdx'],
    cwd: root,
    action: 'remove untracked files in',
  );
  return target;
}

/// Resolves the remote's default branch (e.g. `main` / `master`).
Future<String> _defaultBranch(String root) async {
  var head = await _runOutput(
    ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
    cwd: root,
  );
  if (head == null || head.isEmpty) {
    // origin/HEAD not set (rare for a reused clone) — ask the remote.
    await _runOk(['remote', 'set-head', 'origin', '--auto'], cwd: root);
    head = await _runOutput(
      ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
      cwd: root,
    );
  }
  if (head != null && head.isNotEmpty) {
    const prefix = 'origin/';
    return head.startsWith(prefix) ? head.substring(prefix.length) : head;
  }
  throw GitSourceError(
    'Could not determine the repository default branch.',
    hint: 'Specify the branch explicitly with --ref.',
  );
}

// ── URL parsing ─────────────────────────────────────────────────────────────

/// Host and repository path segments parsed out of a git URL.
class _GitUrlParts {
  _GitUrlParts(this.host, this.segments);

  final String host;

  /// Repository path segments: org, optional subgroups, and repo name.
  final List<String> segments;
}

/// Parses both `https://host/org/repo(.git)` URLs and SCP-style
/// `git@host:org/repo.git` URLs into a host + path segments.
_GitUrlParts _parseGitUrl(String raw) {
  final url = raw.trim();
  if (url.isEmpty) {
    throw GitSourceError('Git URL cannot be empty.');
  }

  String host;
  String path;

  // SCP-like syntax: [user@]host:path — no scheme, ':' before any '/'.
  // The user@ prefix is optional (`host:org/repo.git` is also valid).
  final scp = RegExp(r'^(?:[^/]+@)?([^/:]+):(.+)$').firstMatch(url);
  if (!url.contains('://') && scp != null) {
    host = scp.group(1)!;
    path = scp.group(2)!;
  } else {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw GitSourceError(
        'Could not parse git URL: $raw',
        hint: 'Use an https URL (https://host/org/repo.git) or an '
            'SSH URL (git@host:org/repo.git).',
      );
    }
    host = uri.host;
    path = uri.path;
  }

  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) {
    throw GitSourceError('Git URL has no repository path: $raw');
  }
  segments[segments.length - 1] = _stripDotGit(segments.last);
  if (segments.last.isEmpty) {
    throw GitSourceError('Git URL has no repository name: $raw');
  }
  return _GitUrlParts(host.toLowerCase(), segments);
}

String _stripDotGit(String s) =>
    s.endsWith('.git') ? s.substring(0, s.length - 4) : s;

/// Maps parsed URL parts to `~/.club/clones/<host>/<org…>/<repo>`.
String _cloneRootFor(_GitUrlParts parts) {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    throw GitSourceError(
      'Could not determine the home directory for the clone cache.',
    );
  }
  return p.joinAll([home, '.club', 'clones', parts.host, ...parts.segments]);
}

/// True when [root] is a healthy git work tree whose `origin` remote points
/// at the same repository as [url]. A mismatch (or a non-repo directory)
/// means the cached directory must be recreated rather than reused.
Future<bool> _isMatchingRepo(String root, String url) async {
  final inside = await _runOutput(
    ['rev-parse', '--is-inside-work-tree'],
    cwd: root,
  );
  if (inside != 'true') return false;

  final origin = await _runOutput(['remote', 'get-url', 'origin'], cwd: root);
  if (origin == null) return false;
  return _sameRemote(origin, url);
}

/// Compares two git URLs by host + repository path, ignoring scheme and the
/// `.git` suffix — so the https and SSH forms of the same repo match.
bool _sameRemote(String a, String b) {
  try {
    final pa = _parseGitUrl(a);
    final pb = _parseGitUrl(b);
    return pa.host == pb.host &&
        pa.segments.join('/').toLowerCase() ==
            pb.segments.join('/').toLowerCase();
  } catch (_) {
    return a == b;
  }
}

// ── git process helpers ─────────────────────────────────────────────────────

/// Runs `git` with [args], throwing [GitSourceError] on failure. [action]
/// is a verb phrase folded into the error message, e.g. action `clone`
/// produces "Failed to clone the repository.".
Future<void> _git(
  List<String> args, {
  String? cwd,
  required String action,
}) async {
  final ProcessResult result;
  try {
    result = await Process.run('git', args, workingDirectory: cwd);
  } on ProcessException catch (e) {
    throw GitSourceError(
      'Failed to $action the repository.',
      hint: e.message,
    );
  }
  if (result.exitCode != 0) {
    final err = (result.stderr as String).trim();
    final out = (result.stdout as String).trim();
    final body = err.isNotEmpty ? err : out;
    throw GitSourceError(
      'Failed to $action the repository.',
      hint: body.isEmpty ? null : body,
    );
  }
}

/// Runs `git <args>` and reports whether it exited 0. Never throws.
Future<bool> _runOk(List<String> args, {String? cwd}) async {
  try {
    final r = await Process.run('git', args, workingDirectory: cwd);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Runs `git <args>` and returns trimmed stdout, or null on any failure.
Future<String?> _runOutput(List<String> args, {String? cwd}) async {
  try {
    final r = await Process.run('git', args, workingDirectory: cwd);
    if (r.exitCode != 0) return null;
    return (r.stdout as String).trim();
  } catch (_) {
    return null;
  }
}

/// Throws [GitSourceError] when `git` is not usable on this machine.
Future<void> _ensureGitAvailable() async {
  try {
    final r = await Process.run('git', ['--version']);
    if (r.exitCode != 0) {
      throw GitSourceError('`git` is required for --from-git but failed.');
    }
  } on ProcessException {
    throw GitSourceError(
      '`git` was not found on PATH.',
      hint: 'Install git, then retry --from-git.',
    );
  }
}

void _deleteDir(String path) {
  final d = Directory(path);
  if (d.existsSync()) d.deleteSync(recursive: true);
}
