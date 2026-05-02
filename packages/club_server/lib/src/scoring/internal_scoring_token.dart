import 'dart:convert';
import 'dart:math';

/// Per-process secret used to authenticate the scoring subprocess back to
/// its own server when pana invokes `dart pub get` on a package whose
/// dependencies are hosted on the same Club instance.
///
/// Why this exists: pana runs in an isolated subprocess with no user
/// credentials. When the package under analysis depends on another
/// private package on the same server, `dart pub get` hits an
/// authenticated endpoint and fails with "package repository requested
/// authentication". We can't ship a real user PAT into the sandbox
/// (that would let an RCE in pana act as that user), and we don't want
/// to make the package endpoints anonymous (Club is a private registry).
///
/// The compromise: a per-process secret that grants read-only access to
/// the pub-spec read endpoints — `GET /api/packages/<pkg>` (version list
/// + manifest) and `GET /api/archives/<pkg>-<v>.tar.gz` (tarball
/// download). Nothing else. The token is generated fresh on each server
/// start and lives in memory only — no DB row, no persistence. A
/// process restart rotates it.
///
/// The bypass is enforced in [authMiddleware]; the secret is written to
/// `<scoringHome>/.config/dart/pub-tokens.json` during sandbox prep so
/// `dart pub` picks it up via the standard token-store mechanism. The
/// scoring HOME is owned by the dropped sandbox UID (see
/// `_chownTreeOrChmod777`), so the file is only readable by the
/// already-trusted child.
///
/// Threat model: a code-execution exploit inside pana could read the
/// token file. The blast radius is bounded to enumerating package
/// metadata + downloading tarballs the sandbox UID could already
/// produce by other means (it has the unpacked package on disk
/// already). It cannot: write, manage users, mint tokens, read auth
/// state, or touch admin endpoints.
class InternalScoringToken {
  InternalScoringToken._(this._secret);

  /// Generate a fresh 256-bit token using a CSPRNG. Called once at
  /// server bootstrap — the same instance is shared by the auth
  /// middleware (for verification) and the scoring service (for
  /// writing into pub-tokens.json).
  factory InternalScoringToken.generate() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    // URL-safe base64 without padding — keeps the token a clean opaque
    // string when it lands in `Authorization: Bearer …` and in the
    // pub-tokens.json file.
    return InternalScoringToken._(
      base64Url.encode(bytes).replaceAll('=', ''),
    );
  }

  /// Construct from an explicit secret. Tests use this to drive the
  /// middleware without depending on CSPRNG output.
  factory InternalScoringToken.forTesting(String secret) =>
      InternalScoringToken._(secret);

  final String _secret;

  /// Constant-time comparison against [candidate]. Returns false on any
  /// mismatch — including length differences. Comparing secrets with
  /// `==` would leak length and shared prefix via timing, even on a
  /// short string like this one.
  bool verify(String candidate) {
    final a = _secret.codeUnits;
    final b = candidate.codeUnits;
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// True when [path] (a request URL path with leading `/`) is one of
  /// the read-only routes the bypass is allowed to cover. Whitelist
  /// only — anything not listed must not authenticate via this token,
  /// even if the secret matches.
  ///
  /// Routes:
  ///   - `/api/packages/<pkg>`                                — version list
  ///   - `/api/packages/<pkg>/versions/<v>`                   — version manifest
  ///   - `/api/archives/<pkg>-<v>.tar.gz`                     — tarball download
  ///
  /// Anything that returns user-authored or admin-only data (auth, OAuth,
  /// admin, account, screenshots, readme assets, scores) is *not* on
  /// this list — pana doesn't need them, and broadening the surface
  /// would give the in-sandbox attacker more to work with.
  static bool isAllowedPath(String path, String method) {
    if (method.toUpperCase() != 'GET') return false;
    if (path.startsWith('/api/archives/') && path.endsWith('.tar.gz')) {
      return true;
    }
    if (!path.startsWith('/api/packages/')) return false;
    // Reject anything that drills past the version manifest. We keep
    // the suffix list explicit so a future `/score`, `/screenshots`,
    // `/readme-assets`, `/content`, etc. doesn't slip into the bypass.
    final tail = path.substring('/api/packages/'.length);
    final parts = tail.split('/');
    // /api/packages/<pkg>
    if (parts.length == 1 && parts[0].isNotEmpty) return true;
    // /api/packages/<pkg>/versions/<v>
    if (parts.length == 3 &&
        parts[0].isNotEmpty &&
        parts[1] == 'versions' &&
        parts[2].isNotEmpty) {
      return true;
    }
    return false;
  }

  /// Render a `pub-tokens.json` body that authorizes this token for
  /// [serverUrl]. The format is what `dart pub token add` produces;
  /// `dart pub get` reads it from `$XDG_CONFIG_HOME/dart/pub-tokens.json`
  /// (or the platform-specific equivalent) at resolution time.
  ///
  /// The URL must match the `hosted:` URL in the package's pubspec
  /// exactly — dart pub does not normalize beyond removing a trailing
  /// slash. Callers should pass the same URL the rest of the server
  /// emits in pub-spec responses.
  String pubTokensJson(Uri serverUrl) {
    return jsonEncode({
      'version': 1,
      'hosts': [
        {
          'url': _stripTrailingSlash(serverUrl.toString()),
          'token': _secret,
        },
      ],
    });
  }

  static String _stripTrailingSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;
}

