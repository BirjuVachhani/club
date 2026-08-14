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
///
/// A GitHub pull request URL is also accepted. [parseGitSource] normalises
/// it to the plain repository clone URL plus a PR number, and the PR head is
/// fetched from `refs/pull/<n>/head`. See [parseGitSource].
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../util/log.dart';

/// A prepared git clone ready to be published.
class GitClone {
  GitClone({
    required this.url,
    required this.root,
    required this.ref,
    this.pullRequest,
  });

  /// The git URL that was cloned.
  final String url;

  /// Absolute path to the local clone directory (the repository root).
  final String root;

  /// The branch, tag, or commit that is checked out.
  final String ref;

  /// The pull request number when this clone came from a PR URL, else null.
  final int? pullRequest;
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

/// Clones [source] into the clone cache (or refreshes an existing clone)
/// and checks out [ref] (a branch, tag, or commit). When [ref] is null/empty
/// the remote default branch is used, unless [source] names a pull request,
/// in which case the PR head is checked out.
///
/// Returns a [GitClone] describing the local checkout. Throws
/// [GitSourceError] on any failure (missing `git`, bad URL, network error,
/// unknown ref, unknown PR).
Future<GitClone> prepareGitClone({
  required GitSource source,
  String? ref,
}) async {
  await _ensureGitAvailable();

  final url = source.cloneUrl;
  final parts = _parseGitUrl(url);
  final root = _cloneRootFor(parts);
  final pr = source.pullRequest;
  // A PR is fetched into `refs/remotes/origin/pr/<n>`, so from the checkout
  // step onward it behaves exactly like a remote branch of that name.
  final wantRef = pr != null ? _prLocalRef(pr) : (ref ?? '').trim();

  heading('Preparing git source');
  detail('repo: ${bold(parts.segments.join('/'))} ${gray('(${parts.host})')}');
  if (pr != null) detail('pr: ${bold('#$pr')} ${gray('(refs/pull/$pr/head)')}');
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
    if (pr != null) {
      await _fetchPullRequest(root: root, pr: pr, repo: parts);
    } else {
      await _shallowFetch(root: root, ref: wantRef);
    }
  } else {
    detail('cloning (shallow)…');
    if (pr != null) {
      await _initRemote(url: url, root: root);
      await _fetchPullRequest(root: root, pr: pr, repo: parts);
    } else {
      await _shallowClone(url: url, root: root, ref: wantRef);
    }
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

  return GitClone(
    url: url,
    root: root,
    ref: checkedOut,
    pullRequest: pr,
  );
}

/// Local remote-tracking branch name a pull request is fetched into.
String _prLocalRef(int pr) => 'pr/$pr';

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

// ── Shallow clone / fetch ───────────────────────────────────────────────────

/// Performs a fresh `--depth 1` clone of [url] into [root], picking the most
/// economical strategy that still works for the kind of ref the user asked
/// for:
///
/// * Empty ref — clone the default branch only, depth 1.
/// * Branch or tag name — clone just that branch/tag, depth 1.
/// * Commit SHA — `git init` then `git fetch --depth 1 origin SHA`, because
///   `git clone --branch` does not accept SHAs. Works on every host that
///   allows fetching commits by SHA (GitHub, GitLab, Gitea default to this
///   via `uploadpack.allowAnySHA1InWant=true`).
Future<void> _shallowClone({
  required String url,
  required String root,
  required String ref,
}) async {
  Directory(p.dirname(root)).createSync(recursive: true);
  if (ref.isEmpty) {
    await _git(
      ['clone', '--depth', '1', '--single-branch', url, root],
      action: 'clone',
    );
    return;
  }
  if (_looksLikeSha(ref)) {
    await _initRemote(url: url, root: root);
    await _git(
      ['fetch', '--depth', '1', 'origin', ref],
      cwd: root,
      action: 'fetch commit "$ref" for',
    );
    return;
  }
  await _git(
    ['clone', '--depth', '1', '--branch', ref, '--single-branch', url, root],
    action: 'clone ref "$ref" for',
  );
}

/// Creates an empty repository at [root] with `origin` pointing at [url].
///
/// Used for the two cases `git clone --branch` cannot express: a bare commit
/// SHA, and a pull request ref.
Future<void> _initRemote({required String url, required String root}) async {
  Directory(root).createSync(recursive: true);
  await _git(['init', '--quiet'], cwd: root, action: 'initialise');
  await _git(
    ['remote', 'add', 'origin', url],
    cwd: root,
    action: 'set the remote of',
  );
}

/// Fetches the head commit of pull request [pr] into
/// `refs/remotes/origin/pr/<n>`, so the checkout step can treat it like any
/// other remote branch.
///
/// GitHub publishes every PR at `refs/pull/<n>/head` on the repository
/// itself, including PRs opened from forks, so no second remote is needed.
/// `--force` matters on the reuse path: a PR branch is routinely rebased or
/// amended, and the new head is frequently not a fast-forward of the old one.
Future<void> _fetchPullRequest({
  required String root,
  required int pr,
  required _GitUrlParts repo,
}) async {
  try {
    await _git(
      [
        'fetch',
        '--depth', '1',
        '--force',
        'origin',
        'refs/pull/$pr/head:refs/remotes/origin/${_prLocalRef(pr)}',
      ],
      cwd: root,
      action: 'fetch pull request #$pr for',
    );
  } on GitSourceError catch (e) {
    throw GitSourceError(
      'Pull request #$pr was not found on ${repo.segments.join('/')}.',
      hint: 'Check the number is right. A PR whose fork was deleted has no '
          'fetchable head, and a private repository needs git credentials '
          'that can read it.\n${e.hint ?? ''}'.trimRight(),
    );
  }
}

/// Refreshes a reusable clone in-place with a `--depth 1` fetch of just the
/// ref the next checkout cares about. Keeps the clone shallow (no full
/// history is ever downloaded into the cache).
Future<void> _shallowFetch({
  required String root,
  required String ref,
}) async {
  if (ref.isNotEmpty) {
    await _git(
      ['fetch', '--depth', '1', '--force', '--tags', 'origin', ref],
      cwd: root,
      action: 'fetch ref "$ref" for',
    );
    return;
  }
  // No ref: refresh the remote's default branch only. Resolve its name from
  // origin/HEAD (set by the original `git clone`); fall back to asking the
  // remote if it's missing (e.g. the dir was last populated by an init+fetch
  // for a SHA and has no symbolic HEAD).
  final branch = await _resolveOriginHeadBranch(root);
  if (branch == null) {
    throw GitSourceError(
      'Could not determine the repository default branch.',
      hint: 'Specify the branch explicitly with --ref.',
    );
  }
  await _git(
    ['fetch', '--depth', '1', '--force', 'origin', branch],
    cwd: root,
    action: 'fetch branch "$branch" for',
  );
}

/// Returns the local short branch name of `origin/HEAD` (e.g. `main`), or
/// null if it cannot be resolved even after asking the remote.
Future<String?> _resolveOriginHeadBranch(String root) async {
  Future<String?> read() => _runOutput(
        ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
        cwd: root,
      );
  var head = await read();
  if (head == null || head.isEmpty) {
    await _runOk(['remote', 'set-head', 'origin', '--auto'], cwd: root);
    head = await read();
  }
  if (head == null || head.isEmpty) return null;
  const prefix = 'origin/';
  return head.startsWith(prefix) ? head.substring(prefix.length) : head;
}

/// True when [ref] is a full 40-character hex commit SHA — the only form
/// `git fetch origin <sha>` accepts. Abbreviated SHAs are rejected by every
/// remote, so they're routed through the branch/tag path instead (where
/// git's "remote branch not found" message points the user at the issue).
bool _looksLikeSha(String ref) =>
    RegExp(r'^[0-9a-f]{40}$').hasMatch(ref);

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

/// What the user passed to `--from-git`, normalised into something git can
/// actually clone plus the pull request it referred to (if any).
class GitSource {
  GitSource({required this.cloneUrl, this.pullRequest});

  /// URL handed to `git clone` / `git remote add`. For a PR URL this is the
  /// plain repository URL with the `/pull/<n>` part removed; for everything
  /// else it is the user's input, untouched.
  final String cloneUrl;

  /// Pull request number when the input was a PR URL, else null.
  final int? pullRequest;

  /// True when this source points at a pull request.
  bool get isPullRequest => pullRequest != null;
}

/// GitHub PR URL: `/<owner>/<repo>/pull/<n>` with any trailing segments
/// (`/files`, `/commits`, `/checks/…`) the browser may have added.
final _githubPrPath = RegExp(r'^/([^/]+)/([^/]+)/pull/(\d+)(?:/.*)?/?$');

/// A PR URL on a forge we do not support yet. Matched only to produce a
/// better error than git's "repository not found".
final _otherForgePrPath = RegExp(
  r'/(?:-/)?(?:merge_requests|pull-requests|pulls)/\d+',
);

/// Hosts whose `/pull/<n>` URLs we know how to resolve.
const _githubHosts = {'github.com', 'www.github.com'};

/// Normalises the raw `--from-git` value into a [GitSource].
///
/// A GitHub pull request URL such as
/// `https://github.com/owner/repo/pull/2` becomes the clone URL
/// `https://github.com/owner/repo.git` plus PR number 2. Query strings and
/// fragments (`?w=1`, `#issuecomment-…`) are ignored, so a URL copied
/// straight out of the browser works.
///
/// Every other form (HTTPS, SSH in either style, nested groups) passes
/// through unchanged with a null [GitSource.pullRequest]; those are
/// validated later by [_parseGitUrl] and by git itself.
///
/// Throws [GitSourceError] for a pull request URL on a forge other than
/// GitHub, which is not supported yet.
GitSource parseGitSource(String raw) {
  final url = raw.trim();
  if (url.isEmpty) {
    throw GitSourceError('Git URL cannot be empty.');
  }

  // SSH and SCP-style URLs never carry a PR path, so skip the web-URL
  // handling entirely and let the existing parser deal with them.
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return GitSource(cloneUrl: url);
  }

  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return GitSource(cloneUrl: url);

  final host = uri.host.toLowerCase();
  final match = _githubPrPath.firstMatch(uri.path);

  if (match == null) {
    if (_otherForgePrPath.hasMatch(uri.path)) {
      throw GitSourceError(
        'Publishing from a pull request currently supports GitHub only.',
        hint: 'Pass the plain repository URL and select the ref yourself, '
            'e.g. --ref refs/merge-requests/1/head.',
      );
    }
    return GitSource(cloneUrl: url);
  }

  if (!_githubHosts.contains(host)) {
    throw GitSourceError(
      'Publishing from a pull request currently supports GitHub only '
      '(got host "$host").',
      hint: 'Pass the plain repository URL and select the ref yourself, '
          'e.g. --ref refs/pull/${match.group(3)}/head.',
    );
  }

  final owner = match.group(1)!;
  final repo = _stripDotGit(match.group(2)!);
  final number = int.parse(match.group(3)!);
  if (number < 1) {
    throw GitSourceError('Invalid pull request number in URL: $raw');
  }

  return GitSource(
    cloneUrl: 'https://$host/$owner/$repo.git',
    pullRequest: number,
  );
}

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
