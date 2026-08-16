import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';

/// Package visibility: inspect what a change would do, then do it.
///
/// Split out of `package_admin_api.dart` rather than folded into it
/// because these two endpoints are the only place in the server that can
/// put source code on the internet. Keeping them in one small file makes
/// the whole surface reviewable at a glance.
class VisibilityApi {
  VisibilityApi({
    required this.visibilityService,
    required this.packageService,
    required this.metadataStore,
  });

  final VisibilityService visibilityService;
  final PackageService packageService;
  final MetadataStore metadataStore;

  DecodedRouter get router {
    final router = DecodedRouter();

    router.get('/api/packages/<package>/visibility', _get);
    router.post('/api/packages/<package>/visibility/preview', _preview);
    router.put('/api/packages/<package>/visibility', _apply);

    return router;
  }

  /// Current state, plus whether this caller could change it. The UI uses
  /// the second half to decide between showing a control and showing an
  /// explanation.
  Future<Response> _get(Request request, String package) async {
    final pkg = await metadataStore.lookupPackage(package);
    if (pkg == null) throw NotFoundException.package(package);

    final user = getAuthUser(request);
    final enabled = await visibilityService.isEnabled();
    final canManage = user == null
        ? false
        : await _mayManage(package, user, throwOnDenial: false);

    return _json({
      'package': package,
      'visibility': pkg.visibility.wireName,
      'changedAt': pkg.visibilityChangedAt?.toIso8601String(),
      'changedBy': pkg.visibilityChangedBy,
      'publicPackagesEnabled': enabled,
      'permittedByEnvironment': visibilityService.isPermittedByEnvironment,
      'canManage': canManage && enabled,
    });
  }

  /// Dry run. Returns the closure, what it would cost, and what it would
  /// break, changing nothing.
  ///
  /// A POST rather than a GET because the request carries the operator's
  /// current selection, which is a set that does not belong in a query
  /// string. It is still side-effect free.
  Future<Response> _preview(Request request, String package) async {
    final user = requireAuthUser(request);
    await _mayManage(package, user);

    final body = await _readBody(request);
    final target = _requireTarget(body);
    final selected = _readSelected(body);

    final preview = await visibilityService.preview(
      package: package,
      target: target,
      selected: selected,
    );

    return _json(preview.toJson());
  }

  /// Apply the change.
  ///
  /// Requires `confirm` to echo the package name. Typed confirmation is
  /// deliberate friction: going public cannot be undone for anything
  /// already downloaded, and it exposes the entire published history
  /// rather than just the current version.
  Future<Response> _apply(Request request, String package) async {
    final user = requireAuthUser(request);
    await _mayManage(package, user);

    if (!await visibilityService.isEnabled()) {
      throw const ForbiddenException(
        'Public packages are not enabled on this server. A server admin '
        'must enable them before any package can be made public.',
      );
    }

    final body = await _readBody(request);
    final target = _requireTarget(body);

    final confirm = body['confirm'];
    if (confirm != package) {
      throw InvalidInputException(
        'Confirmation mismatch. Send "confirm": "$package" to apply this '
        'change.',
      );
    }

    // Absent `closure` means "the whole closure", which is the default the
    // UI opens with and the only selection that leaves no version
    // unresolvable. An explicit empty list is a different statement and is
    // honoured as such: flip only the target.
    final closure = body.containsKey('closure')
        ? {..._readSelected(body) ?? const <String>{}, package}
        : (await visibilityService.preview(
            package: package,
            target: target,
          )).selected.toSet();

    final result = await visibilityService.apply(
      package: package,
      target: target,
      closure: closure,
      actorUserId: user.userId,
      acceptBreakage: body['acceptBreakage'] == true,
    );

    return _json(result.toJson());
  }

  // ── Helpers ────────────────────────────────────────────────

  /// Who may change visibility.
  ///
  /// Package admins (an uploader or a publisher admin) by default, which
  /// is the self-serve model. Operators who want a human in the loop turn
  /// on `public_visibility_requires_admin`, because `isPackageAdmin` is
  /// true for any single direct uploader and one uploader publishing
  /// company source to the internet is a decision some organisations want
  /// reviewed.
  Future<bool> _mayManage(
    String package,
    AuthenticatedUser user, {
    bool throwOnDenial = true,
  }) async {
    if (await visibilityService.requiresServerAdmin()) {
      if (!user.role.isAtLeast(UserRole.admin)) {
        if (throwOnDenial) {
          throw const ForbiddenException(
            'This server requires a server admin to change package '
            'visibility.',
          );
        }
        return false;
      }
      return true;
    }

    final isAdmin = await packageService.isPackageAdmin(package, user.userId);
    if (!isAdmin) {
      if (throwOnDenial) {
        throw ForbiddenException.notUploader(package);
      }
      return false;
    }
    return true;
  }

  PackageVisibility _requireTarget(Map<String, dynamic> body) {
    final raw = body['visibility'] ?? body['target'];
    // Strict parse: a typo must be a 400, never a silent fall back to
    // private (which would report success while doing nothing) or to
    // public (which would be catastrophic).
    final parsed = PackageVisibility.tryParse(raw as String?);
    if (parsed == null) {
      throw const InvalidInputException(
        'Field "visibility" must be "public" or "private".',
      );
    }
    return parsed;
  }

  Set<String>? _readSelected(Map<String, dynamic> body) {
    final raw = body['closure'] ?? body['selected'];
    if (raw == null) return null;
    if (raw is! List) {
      throw const InvalidInputException(
        'Field "closure" must be an array of package names.',
      );
    }
    return {
      for (final entry in raw)
        if (entry is String && entry.isNotEmpty) entry,
    };
  }

  Future<Map<String, dynamic>> _readBody(Request request) async {
    final raw = await request.readAsString();
    if (raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('not an object');
      return Map<String, dynamic>.from(decoded);
    } on FormatException {
      throw const InvalidInputException('Request body must be a JSON object.');
    }
  }

  Response _json(Map<String, Object?> payload) => Response.ok(
    jsonEncode(payload),
    headers: {'content-type': 'application/json'},
  );
}
