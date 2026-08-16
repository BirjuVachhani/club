import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../middleware/request_url.dart';

/// Builds the aggregated list-row metadata for [package]: publisher,
/// uploaders, license, and screenshots.
///
/// Shared by the per-package `/api/packages/<package>/list-info` endpoint
/// and the batched `/api/discover` endpoint, so list pages can get this
/// data without an N+1 of follow-up fetches.
///
/// That sharing is exactly why [scope] is required. The uploader block
/// carries email addresses, and `/api/discover` embeds this payload for
/// every hit on a search results page. One missed redaction here would
/// hand an anonymous visitor the email address of every uploader of every
/// package matching a search term, in a single response. Under
/// [VisibilityScope.anonymous] the uploader block is reduced to display
/// names.
///
/// Returns `null` when the package does not exist.
Future<Map<String, dynamic>?> buildListInfo(
  MetadataStore metadataStore,
  PackageService packageService,
  Request request,
  String package, {
  required VisibilityScope scope,
}) async {
  final pkg = await metadataStore.lookupPackage(package);
  if (pkg == null) return null;

  // Publisher (if any).
  Map<String, dynamic>? publisherBlock;
  if (pkg.publisherId != null) {
    final pub = await metadataStore.lookupPublisher(pkg.publisherId!);
    if (pub != null) {
      publisherBlock = {
        'id': pub.id,
        'displayName': pub.displayName,
        'verified': pub.verified,
      };
    }
  }

  // Uploaders — derive display name / email (first uploader wins as the
  // fallback author shown in the list).
  final uploaderIds = await packageService.getUploaders(package);
  final uploaders = <Map<String, dynamic>>[];
  for (final id in uploaderIds) {
    final user = await metadataStore.lookupUserById(id);
    if (user != null) {
      uploaders.add({
        // Display name is attribution, which a public package page wants.
        // The email address is contact information the uploader never
        // agreed to publish, so it is omitted rather than obfuscated:
        // a masked address is still an address.
        if (!scope.publicOnly) 'email': user.email,
        'displayName': user.displayName,
      });
    }
  }

  // License — pana's Summary stores `licenses: [{path, spdxIdentifier}]`
  // inside reportJson. Return the first non-empty SPDX id.
  String? license;
  final latestVersion = pkg.latestVersion;
  if (latestVersion != null) {
    final score = await metadataStore.lookupScore(package, latestVersion);
    final raw = score?.reportJson;
    if (raw != null && raw.isNotEmpty) {
      try {
        final report = jsonDecode(raw) as Map<String, dynamic>;
        final licenses = report['licenses'] as List?;
        if (licenses != null) {
          for (final entry in licenses) {
            if (entry is Map<String, dynamic>) {
              final spdx = entry['spdxIdentifier'] as String?;
              if (spdx != null && spdx.isNotEmpty) {
                license = spdx;
                break;
              }
            }
          }
        }
      } catch (_) {
        // Malformed report — ignore; license stays null.
      }
    }
  }

  // Screenshots for the latest version, shaped the same as the `/content`
  // endpoint so list-page consumers can pipe the array straight into the
  // ScreenshotGallery component without reshaping.
  final screenshots = <Map<String, Object?>>[];
  if (latestVersion != null) {
    final pv = await metadataStore.lookupVersion(package, latestVersion);
    if (pv != null && pv.screenshots.isNotEmpty) {
      final baseUrl = resolveBaseUrl(request);
      for (var i = 0; i < pv.screenshots.length; i++) {
        final s = pv.screenshots[i];
        final ext = screenshotExtOf(s.path);
        screenshots.add({
          'url': baseUrl
              .resolve(
                '/api/packages/$package/versions/$latestVersion'
                '/screenshots/$i.$ext',
              )
              .toString(),
          'description': s.description,
          'path': s.path,
          'mimeType': s.mimeType,
        });
      }
    }
  }

  return {
    'publisher': publisherBlock,
    'uploaders': uploaders,
    'license': license,
    'screenshots': screenshots,
  };
}
