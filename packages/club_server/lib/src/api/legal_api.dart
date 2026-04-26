import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../legal/defaults.dart';
import '../middleware/auth_middleware.dart';

/// Serves and manages the instance's Privacy Policy and Terms of Use.
///
/// Two pieces of markdown live in [SettingsStore] under the keys
/// [_privacyKey] and [_termsKey]. When either key is absent, the
/// default copy bundled with the software is served instead, so every
/// CLUB deployment has reasonable legal text on day one without any
/// configuration.
///
/// Read endpoints are public — the footer links to them and any user
/// (including unauthenticated visitors and the `dart pub` client) may
/// need to read them. Write and reset endpoints require the
/// server-owner role, matching [Permissions.canManageServerSettings].
class LegalApi {
  LegalApi({required this.settingsStore});

  final SettingsStore settingsStore;

  // Cap the stored markdown so a pathological paste cannot blow up the
  // DB or the page. 256 KiB is well above a realistic legal document.
  static const int _maxBytes = 256 * 1024;

  static const String _privacyKey = 'legal.privacy_md';
  static const String _termsKey = 'legal.terms_md';

  DecodedRouter get router {
    final router = DecodedRouter();

    // Public reads — no auth required.
    router.get('/api/legal/privacy', _getPrivacy);
    router.get('/api/legal/terms', _getTerms);

    // Owner-only writes. A server admin cannot publish or reset the
    // legal copy; that is the server owner's responsibility.
    router.put('/api/admin/legal/privacy', _putPrivacy);
    router.put('/api/admin/legal/terms', _putTerms);
    router.delete('/api/admin/legal/privacy', _resetPrivacy);
    router.delete('/api/admin/legal/terms', _resetTerms);

    return router;
  }

  // ── Public reads ──────────────────────────────────────────────────

  Future<Response> _getPrivacy(Request request) =>
      _readAndRespond(_privacyKey, defaultPrivacyMarkdown);

  Future<Response> _getTerms(Request request) =>
      _readAndRespond(_termsKey, defaultTermsMarkdown);

  Future<Response> _readAndRespond(String key, String fallback) async {
    final stored = await settingsStore.getSetting(key);
    final isCustom = stored != null && stored.isNotEmpty;
    return _json({
      'markdown': isCustom ? stored : fallback,
      'isCustom': isCustom,
    });
  }

  // ── Owner-only writes ────────────────────────────────────────────

  Future<Response> _putPrivacy(Request request) =>
      _writeAndRespond(request, _privacyKey, defaultPrivacyMarkdown);

  Future<Response> _putTerms(Request request) =>
      _writeAndRespond(request, _termsKey, defaultTermsMarkdown);

  Future<Response> _writeAndRespond(
    Request request,
    String key,
    String fallback,
  ) async {
    requireRole(request, UserRole.owner);

    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final markdown = body['markdown'];
    if (markdown is! String) {
      throw const InvalidInputException('markdown must be a string.');
    }
    if (markdown.length > _maxBytes) {
      throw InvalidInputException(
        'markdown is too large (max ${_maxBytes ~/ 1024} KiB).',
      );
    }

    final trimmed = markdown.trim();
    if (trimmed.isEmpty) {
      // Treat an empty save as "revert to default" so the UI can
      // cleanly blank the editor; matches DELETE behaviour.
      await settingsStore.deleteSetting(key);
      return _json({'markdown': fallback, 'isCustom': false});
    }

    await settingsStore.setSetting(key, markdown);
    return _json({'markdown': markdown, 'isCustom': true});
  }

  Future<Response> _resetPrivacy(Request request) =>
      _deleteAndRespond(request, _privacyKey, defaultPrivacyMarkdown);

  Future<Response> _resetTerms(Request request) =>
      _deleteAndRespond(request, _termsKey, defaultTermsMarkdown);

  Future<Response> _deleteAndRespond(
    Request request,
    String key,
    String fallback,
  ) async {
    requireRole(request, UserRole.owner);
    await settingsStore.deleteSetting(key);
    return _json({'markdown': fallback, 'isCustom': false});
  }

  Response _json(Object body) => Response.ok(
    jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );
}
