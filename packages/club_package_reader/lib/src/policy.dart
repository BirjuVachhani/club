/// Knobs for [summarizePackageArchive].
///
/// Every flag gates one behaviour that differs between a public pub.dev-style
/// registry and a self-hosted private one. Each constructor parameter defaults
/// to the pub.dev behaviour; use [ReaderPolicy.club] for the relaxed set we
/// use in club.
///
/// When adding a new toggle:
///   1. Add a `final bool` / `final int` field here with a clear default that
///      matches pub.dev's current behaviour.
///   2. Thread it through the relevant gate inside [summarizePackageArchive]
///      (or the validator function called from it).
///   3. Override it in [ReaderPolicy.club] only if our policy intentionally
///      differs.
class ReaderPolicy {
  /// Reject archives that are missing a `LICENSE` file at the root.
  ///
  /// pub.dev: true. Private registries may legitimately publish
  /// unlicensed internal packages, so club sets this to false.
  final bool requireLicense;

  /// Reject archives that are missing (or have an empty) `README.md`.
  final bool requireReadme;

  /// Reject pubspecs that declare a `publish_to:` value.
  ///
  /// pub.dev requires this field to be absent (or `none`) when publishing.
  /// Private registries typically ignore the field entirely.
  final bool checkPublishTo;

  /// Reject `git:` dependencies in published packages. Recommended true for
  /// any registry — git refs are not reproducible and break offline installs.
  final bool forbidGitDependencies;

  /// Reject hosted dependencies whose URL is not in [allowedHostedUrls].
  ///
  /// Recommended true — a package on registry A should not transitively
  /// pull from registry B without the consumer knowing. The allowlist
  /// expresses *which* registries are trusted; a private club instance
  /// typically allows its own URL plus pub.dev's.
  final bool forbidNonDefaultHostedDependencies;

  /// URLs accepted for `hosted:` dependencies when
  /// [forbidNonDefaultHostedDependencies] is true.
  ///
  /// URLs are compared origin-only (scheme + host + non-default port), with
  /// trailing slashes and case normalised. An empty list means "no explicit
  /// `hosted: url:` allowed"; use the default list (pub.dev) or extend it
  /// with a server's own URL for a self-hosted registry.
  ///
  /// Dependencies that omit `hosted:` entirely (the normal `foo: ^1.0.0`
  /// shorthand) are always treated as default pub — the allowlist only
  /// gates explicit `hosted: url:` forms.
  final List<String> allowedHostedUrls;

  /// Reject emoji characters inside the pubspec `description` field.
  final bool rejectEmojiInDescription;

  /// Reject descriptions matching known Dart/Flutter scaffolding templates
  /// (e.g. `A new Flutter project.`).
  final bool rejectKnownTemplateDescriptions;

  /// Reject READMEs containing leftover TODO markers from Dart/Flutter
  /// scaffolding templates.
  final bool rejectKnownTemplateReadmes;

  /// Run the legacy mixed-case / collision check against pub.dev's hardcoded
  /// tables. Only meaningful for pub.dev itself.
  final bool checkMixedCasePackageNames;

  /// Run the "published before 2022 may have invalid `pub_semver` versions"
  /// rewrite. Inert for any modern archive; leave on to match upstream.
  final bool applyPubSemverOverride;

  const ReaderPolicy({
    this.requireLicense = true,
    this.requireReadme = true,
    this.checkPublishTo = true,
    this.forbidGitDependencies = true,
    this.forbidNonDefaultHostedDependencies = true,
    this.allowedHostedUrls = _defaultPubDevHosts,
    this.rejectEmojiInDescription = true,
    this.rejectKnownTemplateDescriptions = true,
    this.rejectKnownTemplateReadmes = true,
    this.checkMixedCasePackageNames = false,
    this.applyPubSemverOverride = true,
  });

  /// Strict defaults matching pub.dev's behaviour.
  static const pubDev = ReaderPolicy(
    checkMixedCasePackageNames: true,
  );

  /// Relaxed defaults for self-hosted private registries. Accepts dependencies
  /// hosted on pub.dev by default; append the server's own URL via
  /// [copyWith(allowedHostedUrls: [...])] so packages can reference each
  /// other on the same club instance.
  static const club = ReaderPolicy(
    requireLicense: false,
    requireReadme: false,
    checkPublishTo: false,
    rejectEmojiInDescription: false,
    rejectKnownTemplateDescriptions: false,
    rejectKnownTemplateReadmes: false,
  );

  /// Returns true when [url] matches any entry in [allowedHostedUrls] after
  /// origin-only normalisation (scheme + host + non-default port).
  bool isHostedUrlAllowed(String url) {
    final normalised = _normaliseOrigin(url);
    if (normalised == null) return false;
    for (final allowed in allowedHostedUrls) {
      if (_normaliseOrigin(allowed) == normalised) return true;
    }
    return false;
  }

  ReaderPolicy copyWith({
    bool? requireLicense,
    bool? requireReadme,
    bool? checkPublishTo,
    bool? forbidGitDependencies,
    bool? forbidNonDefaultHostedDependencies,
    List<String>? allowedHostedUrls,
    bool? rejectEmojiInDescription,
    bool? rejectKnownTemplateDescriptions,
    bool? rejectKnownTemplateReadmes,
    bool? checkMixedCasePackageNames,
    bool? applyPubSemverOverride,
  }) => ReaderPolicy(
    requireLicense: requireLicense ?? this.requireLicense,
    requireReadme: requireReadme ?? this.requireReadme,
    checkPublishTo: checkPublishTo ?? this.checkPublishTo,
    forbidGitDependencies: forbidGitDependencies ?? this.forbidGitDependencies,
    forbidNonDefaultHostedDependencies:
        forbidNonDefaultHostedDependencies ??
        this.forbidNonDefaultHostedDependencies,
    allowedHostedUrls: allowedHostedUrls ?? this.allowedHostedUrls,
    rejectEmojiInDescription:
        rejectEmojiInDescription ?? this.rejectEmojiInDescription,
    rejectKnownTemplateDescriptions:
        rejectKnownTemplateDescriptions ?? this.rejectKnownTemplateDescriptions,
    rejectKnownTemplateReadmes:
        rejectKnownTemplateReadmes ?? this.rejectKnownTemplateReadmes,
    checkMixedCasePackageNames:
        checkMixedCasePackageNames ?? this.checkMixedCasePackageNames,
    applyPubSemverOverride:
        applyPubSemverOverride ?? this.applyPubSemverOverride,
  );
}

/// Default hosted-URL allowlist: pub.dev canonical + legacy alias. Both
/// resolve to the same backend but pubspecs in the wild use either.
const _defaultPubDevHosts = <String>[
  'https://pub.dev',
  'https://pub.dartlang.org',
];

/// Origin-normalise [url] to `scheme://host[:port]`, lowercasing scheme + host
/// and dropping default ports / trailing slashes / paths. Returns null if
/// [url] can't be parsed as an absolute http/https URL.
String? _normaliseOrigin(String url) {
  Uri u;
  try {
    u = Uri.parse(url.trim());
  } catch (_) {
    return null;
  }
  if (u.scheme.isEmpty || u.host.isEmpty) return null;
  final scheme = u.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  final host = u.host.toLowerCase();
  final defaultPort = scheme == 'https' ? 443 : 80;
  final port = u.hasPort && u.port != defaultPort ? ':${u.port}' : '';
  return '$scheme://$host$port';
}
