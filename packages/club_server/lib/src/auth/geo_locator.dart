import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

final _log = Logger('GeoLocator');

/// Point-in-time geolocation snapshot for a client IP. All fields are
/// optional because some providers may not know every IP at every
/// precision level (e.g. IPv6-only CDN egress often lacks a city).
class GeoLocation {
  const GeoLocation({
    this.city,
    this.region,
    this.country,
    this.countryCode,
  });

  final String? city;
  final String? region;
  final String? country;

  /// ISO 3166-1 alpha-2 (e.g. "IN", "US").
  final String? countryCode;

  bool get isEmpty =>
      city == null && region == null && country == null && countryCode == null;
}

/// Resolves a client IP to a best-effort location. Implementations must
/// never throw on network/provider failure — return `null` so the caller
/// can continue without location data.
abstract class GeoLocator {
  Future<GeoLocation?> lookup(String ip);
}

/// ipwho.is-backed locator. Free, key-less, and returns the fields we
/// need in a single GET. The contract is "never throws": every failure
/// path — timeout, TLS failure, non-2xx, `success: false`, body that
/// isn't a JSON object, private IP, or anything else that goes wrong —
/// collapses to `null`. Login must not fail because a third-party
/// geolocation provider is slow, down, or misbehaving.
class IpwhoisGeoLocator implements GeoLocator {
  IpwhoisGeoLocator({
    HttpClient? httpClient,
    this.timeout = const Duration(seconds: 2),
  }) : _client = httpClient ?? HttpClient();

  final HttpClient _client;
  final Duration timeout;

  static const _baseUrl = 'https://ipwho.is';

  @override
  Future<GeoLocation?> lookup(String ip) async {
    if (_isPrivate(ip)) return null;

    try {
      final uri = Uri.parse('$_baseUrl/${Uri.encodeComponent(ip)}');
      final req = await _client.getUrl(uri).timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != HttpStatus.ok) {
        _log.fine('ipwho.is returned ${res.statusCode} for $ip');
        // Drain the body so the HttpClient can reuse the connection
        // rather than leaking it — ignoring any error since we're
        // already bailing on this response.
        await res.drain<void>().timeout(timeout).catchError((_) {});
        return null;
      }
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        _log.fine('ipwho.is non-object body for $ip');
        return null;
      }
      if (decoded['success'] != true) {
        _log.fine('ipwho.is success=false for $ip');
        return null;
      }

      final loc = GeoLocation(
        city: _asString(decoded['city']),
        region: _asString(decoded['region']),
        country: _asString(decoded['country']),
        countryCode: _asString(decoded['country_code']),
      );
      return loc.isEmpty ? null : loc;
    } on TimeoutException {
      _log.fine('ipwho.is timed out for $ip');
      return null;
    } catch (e) {
      // Catch-all safety net. The locator's contract is "never throws"
      // so login can rely on it; anything uncaught above (TLS handshake
      // failures, malformed JSON, unexpected runtime errors) collapses
      // to null here. Logged at fine so it's visible during diagnosis
      // without polluting the normal log stream.
      _log.fine('ipwho.is lookup failed for $ip: $e');
      return null;
    }
  }

  static String? _asString(Object? v) {
    if (v is String && v.isNotEmpty) return v;
    return null;
  }

  static bool _isPrivate(String ip) {
    if (ip == '::1' || ip == '127.0.0.1' || ip.startsWith('127.')) return true;
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('192.168.')) return true;
    // 172.16.0.0/12 = 172.16.0.0 – 172.31.255.255.
    final m = RegExp(r'^172\.(\d+)\.').firstMatch(ip);
    if (m != null) {
      final octet = int.tryParse(m.group(1)!);
      if (octet != null && octet >= 16 && octet <= 31) return true;
    }
    // IPv6 link-local (fe80::/10) and unique-local (fc00::/7).
    if (ip.startsWith('fe80:') ||
        ip.startsWith('fc') ||
        ip.startsWith('fd')) {
      return true;
    }
    return false;
  }
}

/// In-memory locator for tests. Returns pre-seeded results keyed by IP;
/// unknown IPs resolve to `null`.
class FakeGeoLocator implements GeoLocator {
  FakeGeoLocator([Map<String, GeoLocation?> results = const {}])
    : _results = {...results};

  final Map<String, GeoLocation?> _results;

  @override
  Future<GeoLocation?> lookup(String ip) async => _results[ip];
}
