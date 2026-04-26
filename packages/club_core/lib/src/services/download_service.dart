import '../models/api/package_download_history.dart';
import '../repositories/metadata_store.dart';

/// Handles download tracking: recording events and querying history.
class DownloadService {
  const DownloadService({required MetadataStore store}) : _store = store;

  final MetadataStore _store;

  /// Record a download event for [package]/[version]. Fire-and-forget safe.
  Future<void> record(String package, String version) {
    final date = _todayUtc();
    return _store.recordDownload(package, version, date);
  }

  /// Get the 30-day total for use in VersionScore.
  Future<int> total30Days(String package) =>
      _store.totalDownloads(package, days: 30);

  /// Build the full downloads history response for the API endpoint.
  Future<PackageDownloadHistory> history(String package) async {
    final weeks = await _store.weeklyDownloads(package, weeks: 53);
    final total30 = await _store.totalDownloads(package, days: 30);
    return PackageDownloadHistory(
      packageName: package,
      total30Days: total30,
      weeks: weeks,
    );
  }

  static String _todayUtc() {
    final now = DateTime.now().toUtc();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}
