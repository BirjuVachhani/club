/// Resolves which club server should provide a given package for `club add`.
///
/// Thin adapter around [HostingServerResolver]: delegates the fan-out,
/// picker, and pin resolution, then wraps the result in a [ResolvedPackage]
/// that also carries the pubspec constraint string.
///
/// See `resolve/hosting_server_resolver.dart` for the shared server
/// resolution and picker logic, reused by `club global activate`.
library;

import 'package:pub_semver/pub_semver.dart' as semver;

import '../credentials.dart';
import '../resolve/hosting_server_resolver.dart';
import 'add_options.dart';

// Re-export so existing callers (`AddRunner`) that catch `ResolveError`
// continue to compile without importing the new location.
export '../resolve/hosting_server_resolver.dart'
    show ResolveError, ClientFactory;

/// The outcome of resolving one [AddRequest].
class ResolvedPackage {
  ResolvedPackage({
    required this.request,
    required this.serverUrl,
    required this.latestVersion,
  });

  final AddRequest request;
  final String serverUrl;
  final semver.Version latestVersion;

  /// The constraint to write into pubspec.yaml.
  ///
  /// If the user supplied one, it wins verbatim. Otherwise we derive
  /// `^<latest>` — matching `dart pub add`'s default.
  String get constraintString {
    final explicit = request.explicitConstraint;
    if (explicit != null) return explicit.toString();
    return semver.VersionConstraint.compatibleWith(latestVersion).toString();
  }
}

/// Resolves packages across one-or-more club servers, for `club add`.
class PackageResolver {
  PackageResolver({
    required String? serverFlag,
    ClientFactory? clientFactory,
    CredentialReader? credentials,
  }) : _resolver = HostingServerResolver(
         serverFlag: serverFlag,
         clientFactory: clientFactory,
         credentials: credentials,
       );

  final HostingServerResolver _resolver;

  Future<ResolvedPackage> resolve(AddRequest request) async {
    final hit = await _resolver.resolve(
      packageName: request.name,
      pinnedUrl: request.explicitHostedUrl,
    );
    return ResolvedPackage(
      request: request,
      serverUrl: hit.serverUrl,
      latestVersion: hit.latestStableVersion,
    );
  }
}
