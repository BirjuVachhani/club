import '../exceptions.dart';

/// Budgets for a publish's static-site attachments.
class SiteLimits {
  const SiteLimits({
    this.count = 20,
    this.archiveBytes = 100 * 1024 * 1024,
    this.totalBytes = 500 * 1024 * 1024,
    this.expandedBytes = 500 * 1024 * 1024,
    this.entries = 10000,
  }) : assert(count > 0, 'Site count budget must permit a site.'),
       assert(archiveBytes > 0, 'Archive budget must permit compressed data.'),
       assert(totalBytes > 0, 'Total budget must permit site uploads.'),
       assert(
         expandedBytes > 0,
         'Expanded budget must permit archive validation.',
       ),
       assert(entries > 0, 'Entry budget must permit index.html.');

  final int count;
  final int archiveBytes;
  final int totalBytes;
  final int expandedBytes;
  final int entries;

  Map<String, int> toJson() => {
    'count': count,
    'archive_bytes': archiveBytes,
    'total_bytes': totalBytes,
    'expanded_bytes': expandedBytes,
    'entries': entries,
  };
}

/// Validated manifest entry. Part identifiers never become arbitrary paths.
class SiteUpload {
  const SiteUpload({
    required this.name,
    this.part,
    this.length,
    this.sha256,
    this.url,
    this.label,
  });

  final String name;
  final String? part;
  final int? length;
  final String? sha256;
  final String? url;
  final String? label;

  static bool validUrl(String value) {
    final uri = Uri.tryParse(value);
    return value == value.trim() &&
        !RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value) &&
        uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  static bool validName(String name) =>
      RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$').hasMatch(name) && name.length <= 128;

  static List<SiteUpload> parse(Object? json, SiteLimits limits) {
    if (json is! Map || json['version'] != 1 || json['sites'] is! List) {
      throw const InvalidInputException('Invalid site upload manifest.');
    }
    final raw = json['sites'] as List;
    if (raw.length > limits.count) {
      throw const InvalidInputException('Too many sites.');
    }
    final names = <String>{};
    final parts = <String>{};
    var total = 0;
    return raw.map((entry) {
      if (entry is! Map) {
        throw const InvalidInputException('Invalid site entry.');
      }
      final name = entry['name'];
      final label = entry['label'];
      if (label != null &&
          (label is! String || label.trim().isEmpty || label.length > 200)) {
        throw const InvalidInputException(
          'Site label must be nonblank and at most 200 characters.',
        );
      }
      if (entry.containsKey('url')) {
        final url = entry['url'];
        if (name is! String ||
            !validName(name) ||
            !names.add(name.toLowerCase()) ||
            url is! String ||
            !validUrl(url) ||
            entry.containsKey('part') ||
            entry.containsKey('length') ||
            entry.containsKey('sha256')) {
          throw const InvalidInputException('Invalid URL site target.');
        }
        return SiteUpload(name: name, url: url, label: label as String?);
      }
      final part = entry['part'];
      final length = entry['length'];
      final hash = entry['sha256'];
      if (name is! String ||
          !validName(name) ||
          !names.add(name.toLowerCase()) ||
          part is! String ||
          !RegExp(r'^site_[0-9]+$').hasMatch(part) ||
          !parts.add(part) ||
          length is! int ||
          length <= 0 ||
          length > limits.archiveBytes ||
          hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw const InvalidInputException(
          'Invalid or duplicate site manifest entry.',
        );
      }
      total += length;
      if (total > limits.totalBytes) {
        throw const InvalidInputException(
          'Site archives exceed total upload limit.',
        );
      }
      return SiteUpload(
        name: name,
        part: part,
        length: length,
        sha256: hash,
        label: label as String?,
      );
    }).toList();
  }
}
