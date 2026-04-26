import 'package:pub_semver/pub_semver.dart';

/// Utilities for semantic version validation and canonicalization.
abstract final class VersionValidator {
  /// Parse and validate a version string.
  /// Returns null if invalid.
  static Version? tryParse(String versionString) {
    try {
      return Version.parse(versionString);
    } on FormatException {
      return null;
    }
  }

  /// Returns the canonical form of a version string, or null if invalid.
  static String? canonicalize(String versionString) {
    final version = tryParse(versionString);
    return version?.toString();
  }

  /// Returns true if the version string is valid semver.
  static bool isValid(String versionString) => tryParse(versionString) != null;

  /// Returns true if the version is a prerelease.
  static bool isPrerelease(String versionString) {
    final version = tryParse(versionString);
    return version?.isPreRelease ?? false;
  }

  /// Compare two version strings. Returns negative if a < b, 0 if equal,
  /// positive if a > b.
  static int compare(String a, String b) {
    final va = Version.parse(a);
    final vb = Version.parse(b);
    return va.compareTo(vb);
  }

  /// Given a list of version strings, return the latest stable version.
  /// Returns null if no stable versions exist.
  static String? latestStable(List<String> versions) {
    Version? best;
    String? bestStr;
    for (final v in versions) {
      final parsed = tryParse(v);
      if (parsed == null || parsed.isPreRelease) continue;
      if (best == null || parsed > best) {
        best = parsed;
        bestStr = v;
      }
    }
    return bestStr;
  }

  /// Given a list of version strings, return the latest (including prereleases).
  static String? latestAny(List<String> versions) {
    Version? best;
    String? bestStr;
    for (final v in versions) {
      final parsed = tryParse(v);
      if (parsed == null) continue;
      if (best == null || parsed > best) {
        best = parsed;
        bestStr = v;
      }
    }
    return bestStr;
  }
}
