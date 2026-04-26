import 'package:club_server/src/auth/loopback_redirect.dart';
import 'package:test/test.dart';

void main() {
  group('isValidLoopbackRedirect', () {
    test('accepts explicit loopback hosts with ports', () {
      expect(isValidLoopbackRedirect('http://localhost:51823/callback'), isTrue);
      expect(isValidLoopbackRedirect('http://127.0.0.1:51823/cb'), isTrue);
      expect(isValidLoopbackRedirect('http://[::1]:51823/cb'), isTrue);
    });

    test('rejects null, empty, and garbage', () {
      expect(isValidLoopbackRedirect(null), isFalse);
      expect(isValidLoopbackRedirect(''), isFalse);
      expect(isValidLoopbackRedirect('not a url'), isFalse);
    });

    test('rejects userinfo tricks (@host)', () {
      // The classic attack: parser thinks host is evil.com, but a naive
      // startsWith('http://localhost') check would greenlight it.
      expect(
        isValidLoopbackRedirect('http://localhost@evil.com:80/cb'),
        isFalse,
      );
      expect(
        isValidLoopbackRedirect('http://user:pass@localhost:8080/cb'),
        isFalse,
      );
    });

    test('rejects look-alike subdomains', () {
      expect(
        isValidLoopbackRedirect('http://localhost.evil.com:8080/cb'),
        isFalse,
      );
      expect(
        isValidLoopbackRedirect('http://127.0.0.1.evil.com:80/cb'),
        isFalse,
      );
    });

    test('rejects non-http schemes', () {
      // Loopback is specifically exempt from the HTTPS requirement, so
      // https on loopback is unexpected and we prefer to reject than to
      // deal with cert chains for 127.0.0.1.
      expect(isValidLoopbackRedirect('https://localhost:443/cb'), isFalse);
      expect(isValidLoopbackRedirect('file:///tmp/cb'), isFalse);
      expect(
        isValidLoopbackRedirect('javascript:alert(1)'),
        isFalse,
      );
      expect(
        isValidLoopbackRedirect('club://localhost:8080/cb'),
        isFalse,
      );
    });

    test('requires an explicit port', () {
      expect(isValidLoopbackRedirect('http://localhost/cb'), isFalse);
      expect(isValidLoopbackRedirect('http://127.0.0.1/cb'), isFalse);
    });

    test('rejects non-loopback IPs', () {
      expect(
        isValidLoopbackRedirect('http://192.168.1.1:8080/cb'),
        isFalse,
      );
      expect(isValidLoopbackRedirect('http://0.0.0.0:8080/cb'), isFalse);
      expect(
        isValidLoopbackRedirect('http://example.com:8080/cb'),
        isFalse,
      );
    });
  });
}
