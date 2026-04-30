import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:club_core/club_core.dart';
import 'package:logging/logging.dart';

final _log = Logger('DnsResolver');

/// Transient failure — caller should tell the user to retry in a minute
/// rather than claiming the TXT record isn't there.
class DnsTemporaryException implements Exception {
  DnsTemporaryException(this.message);
  final String message;
  @override
  String toString() => 'DnsTemporaryException: $message';
}

/// DNS-over-HTTPS resolver using Cloudflare's `1.1.1.1/dns-query` or
/// Google's `dns.google/resolve` JSON API. Works on any server that can
/// reach HTTPS outbound, even where UDP/53 is blocked.
///
/// By default this runs against *both* providers and accepts the record
/// only if they agree; this defends against single-resolver poisoning
/// and transient one-off failures. Operators can relax via the
/// `requireBothProviders` flag if Cloudflare or Google is unreachable
/// from their network.
class DualDohResolver implements PublisherDnsResolver {
  DualDohResolver({
    HttpClient? httpClient,
    this.requireBothProviders = true,
    this.timeout = const Duration(seconds: 6),
  }) : _client = httpClient ?? HttpClient();

  final HttpClient _client;
  final bool requireBothProviders;
  final Duration timeout;

  static const _cloudflareUrl = 'https://cloudflare-dns.com/dns-query';
  static const _googleUrl = 'https://dns.google/resolve';

  @override
  Future<List<String>> lookupTxt(String name) async {
    // Fan out to both providers in parallel. Even if one is slow we
    // still return quickly when the other succeeds (unless strict mode
    // demands agreement).
    final results = await Future.wait<List<String>?>([
      _queryOne(_cloudflareUrl, name),
      _queryOne(_googleUrl, name),
    ]);

    final cf = results[0];
    final google = results[1];

    if (requireBothProviders) {
      if (cf == null || google == null) {
        throw DnsTemporaryException(
          'Could not reach one of the DNS providers — try again shortly.',
        );
      }
      // Require each record we return to appear in both responses.
      final cfSet = cf.toSet();
      return google.where(cfSet.contains).toList();
    }

    // Permissive: return anything we saw, or throw if neither resolver
    // answered at all.
    if (cf == null && google == null) {
      throw DnsTemporaryException(
        'Neither DNS provider was reachable — try again shortly.',
      );
    }
    return {...?cf, ...?google}.toList();
  }

  Future<List<String>?> _queryOne(String baseUrl, String name) async {
    try {
      final uri = Uri.parse('$baseUrl?name=$name&type=TXT');
      final req = await _client.getUrl(uri).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final res = await req.close().timeout(timeout);
      if (res.statusCode != HttpStatus.ok) {
        _log.fine('DoH $baseUrl returned ${res.statusCode} for $name');
        return null;
      }
      final body = await res.transform(utf8.decoder).join();
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      // `Status` 0 means NOERROR; 3 is NXDOMAIN (name doesn't exist) —
      // that's not a transient failure, it's an authoritative "no".
      final status = decoded['Status'] as int? ?? -1;
      if (status == 3) return const [];
      if (status != 0) {
        _log.fine('DoH $baseUrl rcode=$status for $name');
        return null;
      }

      final answers = (decoded['Answer'] as List?) ?? const [];
      final values = <String>[];
      for (final a in answers) {
        if (a is! Map) continue;
        // Type 16 = TXT. Strip the surrounding quotes that both
        // providers include in their JSON responses. Some records may
        // contain multiple concatenated strings ("a""b"); normalise.
        if (a['type'] != 16) continue;
        final raw = a['data'] as String? ?? '';
        values.add(_unquoteTxt(raw));
      }
      return values;
    } on TimeoutException {
      _log.fine('DoH $baseUrl timed out for $name');
      return null;
    } on SocketException catch (e) {
      _log.fine('DoH $baseUrl network error for $name: $e');
      return null;
    } on HttpException catch (e) {
      _log.fine('DoH $baseUrl http error for $name: $e');
      return null;
    } on FormatException catch (e) {
      _log.fine('DoH $baseUrl bad response for $name: $e');
      return null;
    }
  }

  /// TXT records in the DoH JSON usually come back as `"club-verify=abc"`
  /// (with the surrounding double quotes). Multi-string records look
  /// like `"one""two"`. Google sometimes omits the quotes entirely and
  /// returns the bare value — treat that as the single string verbatim.
  static String _unquoteTxt(String raw) {
    if (!raw.contains('"')) return raw;

    final buf = StringBuffer();
    var inQuote = false;
    var escape = false;
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (escape) {
        buf.write(c);
        escape = false;
        continue;
      }
      if (c == r'\') {
        escape = true;
        continue;
      }
      if (c == '"') {
        inQuote = !inQuote;
        continue;
      }
      if (inQuote) buf.write(c);
    }
    return buf.toString();
  }
}

/// In-memory resolver for tests. Maps names to TXT record lists.
class FakeDnsResolver implements PublisherDnsResolver {
  FakeDnsResolver(this._records);
  final Map<String, List<String>> _records;
  @override
  Future<List<String>> lookupTxt(String name) async =>
      _records[name] ?? const [];
}
