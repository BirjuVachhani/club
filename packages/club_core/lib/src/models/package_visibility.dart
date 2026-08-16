/// Whether a package is reachable without credentials.
///
/// This is access control, and it is deliberately separate from
/// [Package.isUnlisted] and [Package.isDiscontinued], which are pub.dev-style
/// listing hints that say nothing about *who* may read the package. The two
/// compose: a `public` + unlisted package resolves for anonymous `dart pub`
/// but stays out of the anonymous browse listing.
///
/// Stored as TEXT rather than a boolean so a future `pending` state (an
/// approval step before a package goes out to the internet) can be added
/// without another migration. A database upgraded via `ALTER TABLE` has no
/// CHECK constraint backing the column, so [parse] is the enforcement point
/// on that path: it must reject anything it does not recognise rather than
/// guessing.
enum PackageVisibility {
  /// Credentials required. The default for every package, at every point
  /// where a default is needed.
  private('private'),

  /// Readable by anyone, with no credentials. Every version's bytes are
  /// readable; the anonymous *version list* is additionally filtered to
  /// versions whose club-hosted dependencies are all public (see
  /// `package_versions.public_resolvable`).
  public('public');

  const PackageVisibility(this.wireName);

  /// The value stored in `packages.visibility` and sent over the API.
  final String wireName;

  bool get isPublic => this == PackageVisibility.public;

  /// Parse a stored or wire value.
  ///
  /// Fails closed: an unknown or null value yields [private]. A row that
  /// somehow holds an unrecognised state must not be treated as reachable
  /// by the internet, and a loud crash on read would take down the whole
  /// registry over one bad row. Callers that need to *reject* bad input
  /// (API request bodies) should use [tryParse] and 400 instead.
  static PackageVisibility parse(String? value) =>
      tryParse(value) ?? PackageVisibility.private;

  /// Parse strictly, returning null when [value] is not a known state.
  /// Use this for anything user-supplied so a typo is a 400 rather than a
  /// silent downgrade to [private].
  static PackageVisibility? tryParse(String? value) {
    if (value == null) return null;
    for (final v in PackageVisibility.values) {
      if (v.wireName == value) return v;
    }
    return null;
  }
}
