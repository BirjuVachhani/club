import '../models/site_upload.dart';

/// Replaces a complete site's archive set without exposing partial file writes.
abstract interface class SiteArchiveStore {
  Future<void> open();

  /// Removes live sites and all recovery state before a package name is reused.
  /// A failure must propagate so callers do not delete package metadata.
  Future<void> deletePackage(String package);

  Future<void> replace(
    String package,
    String sourceDirectory,
    List<SiteUpload> sites,
  );
}
