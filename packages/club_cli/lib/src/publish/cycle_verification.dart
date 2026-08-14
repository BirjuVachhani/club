/// Post-publish resolution check for packages in a dependency cycle.
///
/// `club publish --auto` normally resolves each package standalone before
/// uploading it (see `isolated_resolution.dart`), which is a stronger check
/// than `dart pub publish` performs. That check cannot run for a package
/// caught in a cycle: whichever member uploads first names a sibling version
/// that is not on the server yet, so `pub get` is guaranteed to fail for
/// reasons that have nothing to do with the package.
///
/// So the check is deferred, not dropped. Once every member of a cycle has
/// been uploaded the loop is closed, and each deferred package is rebuilt and
/// resolved exactly the way a non-deferred publish would have resolved it. A
/// pass here means the same thing a pass during publish means.
///
/// Failure at this point is worth reporting loudly but cannot be undone by
/// aborting: the packages are already on the server. The caller surfaces that
/// distinction to the user.
library;

import 'dart:io';

import '../prepare/package_discovery.dart';
import '../util/log.dart';
import 'archive_extractor.dart';
import 'isolated_resolution.dart';
import 'pubspec_reader.dart';
import 'tarball_builder.dart';

/// Outcome of verifying one deferred package.
class DeferredVerification {
  DeferredVerification({
    required this.packageName,
    required this.ok,
    this.buildError,
  });

  final String packageName;

  /// True when the package resolved standalone against the server.
  final bool ok;

  /// Set when the archive could not even be rebuilt, so resolution never ran.
  final String? buildError;

  /// `dart analyze` output from the resolved copy, when it reported issues.
  ///
  /// Analysis is also deferred for cycle members (there is nothing to resolve
  /// imports against mid-cycle), so it runs here. Reported as a warning: it
  /// does not decide [ok], matching the baseline publish behaviour where
  /// analyze issues are warnings rather than errors.
  String? analyzeOutput;
}

/// Rebuild and resolve every package in [packageNames] standalone.
///
/// [packages] supplies the on-disk location of each package;
/// [pubspecOverrides] the in-memory rewritten pubspec (keyed by package name)
/// that was actually uploaded, so the resolve sees the published bytes rather
/// than the developer's path deps. [versionOverrides] carries the effective
/// version per package when `--version` or `--from-git` changed it.
///
/// Returns one result per name that exists in [packages], in the order given.
Future<List<DeferredVerification>> verifyDeferredResolutions({
  required List<String> packageNames,
  required Map<String, DiscoveredPackage> packages,
  required Map<String, String> pubspecOverrides,
  required String serverUrl,
  required String? serverToken,
  Map<String, String> versionOverrides = const {},
}) async {
  final results = <DeferredVerification>[];

  for (final name in packageNames) {
    final pkg = packages[name];
    if (pkg == null) continue;

    final override = pubspecOverrides[name];
    final versionOverride = versionOverrides[name];
    final pubspec = override != null
        ? parsePubspec(pkg.directory, override, versionOverride: versionOverride)
        : readPubspec(pkg.directory, versionOverride: versionOverride);

    final String archivePath;
    try {
      final built = await TarballBuilder(pkg.directory).build(
        pubspecOverride: override,
        versionOverride: versionOverride,
      );
      archivePath = built.path;
    } on Object catch (e) {
      error('$name: could not rebuild the archive to verify it.\n  $e');
      results.add(
        DeferredVerification(
          packageName: name,
          ok: false,
          buildError: e.toString(),
        ),
      );
      continue;
    }

    final resolution = await resolveInIsolation(
      archivePath: archivePath,
      pubspec: pubspec,
      serverUrl: serverUrl,
      serverToken: serverToken,
      extract: extractPackageArchive,
      errorHint:
          '$name is part of a dependency cycle and is already published. '
          'Every sibling is up too, so this is a real resolution failure '
          'rather than the expected mid-cycle one.',
    );

    final result = DeferredVerification(packageName: name, ok: resolution.ok);

    // Now that the package resolves, the analysis that was skipped during
    // publish can finally run against a tree with a real package_config.
    final resolvedDir = resolution.directory;
    if (resolution.ok && resolvedDir != null) {
      result.analyzeOutput = await _analyze(resolvedDir.path);
      if (result.analyzeOutput != null) {
        warning(
          '$name: `dart analyze` reported issues on the published package:\n'
          '${_indent(result.analyzeOutput!)}',
        );
      }
    }

    disposeIsolatedResolution(resolvedDir);
    _deleteQuietly(archivePath);
    results.add(result);
  }

  return results;
}

/// Runs `dart analyze` in [dir], returning its output when it found issues and
/// null when the package is clean or the SDK is unavailable.
Future<String?> _analyze(String dir) async {
  final ProcessResult result;
  try {
    result = await Process.run('dart', ['analyze'], workingDirectory: dir);
  } on ProcessException {
    return null; // Dart SDK not on PATH; nothing to report.
  }
  if (result.exitCode == 0) return null;

  final out = (result.stdout as String).trim();
  final err = (result.stderr as String).trim();
  final body = out.isNotEmpty ? out : err;
  return body.isEmpty ? null : body;
}

String _indent(String s) => s.split('\n').map((l) => '  $l').join('\n');

void _deleteQuietly(String path) {
  try {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // Best-effort cleanup; the OS reaps the temp directory eventually.
  }
}
