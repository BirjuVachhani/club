import 'package:club_core/club_core.dart' show SiteUpload;
import 'dart:io';

/// A prepared static-site archive accompanying a package publish.
class SiteAttachment {
  const SiteAttachment({required this.name, this.file, this.url, this.label});

  final String name;
  final File? file;
  final String? url;
  final String? label;
}

/// Shared validation for externally hosted site targets.
bool isValidSiteUrl(String value) => SiteUpload.validUrl(value);
