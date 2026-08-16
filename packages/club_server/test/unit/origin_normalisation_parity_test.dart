import 'package:club_core/club_core.dart' show normaliseDependencyOrigin;
import 'package:club_package_reader/club_package_reader.dart'
    show normaliseHostedOrigin;
import 'package:test/test.dart';

/// The same question ("is this `hosted:` URL pointing at *this* server?")
/// is answered in two packages, and they must answer identically.
///
/// `club_package_reader.normaliseHostedOrigin` gates whether a package may
/// be published at all. `club_core.normaliseDependencyOrigin` decides
/// whether a dependency joins the public-visibility closure. The
/// implementations are duplicated because `club_core` is deliberately free
/// of the archive/YAML dependencies that `club_package_reader` pulls in.
///
/// A drift between them is a visibility bypass, not a cosmetic bug: a
/// dependency that passed publish validation as "hosted here" but that the
/// closure walk classified as external would let a package be made public
/// while a club-hosted dependency it needs quietly stayed private. This
/// test is the only thing holding the two together, so it lives in the one
/// package that depends on both.
void main() {
  const cases = <String>[
    // Ordinary forms.
    'https://club.example.com',
    'https://club.example.com/',
    'http://localhost:8080',
    'http://127.0.0.1:8080/',
    // Case folding.
    'HTTPS://CLUB.EXAMPLE.COM',
    'HtTps://Club.Example.Com/',
    // Default vs explicit ports.
    'https://club.example.com:443',
    'http://club.example.com:80',
    'https://club.example.com:8443',
    'http://club.example.com:8080',
    // Paths, queries, fragments, and userinfo must all be dropped.
    'https://club.example.com/some/path',
    'https://club.example.com/?a=b',
    'https://club.example.com/#frag',
    'https://user:pass@club.example.com',
    // Whitespace.
    '  https://club.example.com  ',
    // Rejections.
    '',
    '   ',
    'not a url',
    '/relative/path',
    'ftp://club.example.com',
    'file:///etc/passwd',
    'https://',
    'club.example.com',
  ];

  test('both normalisers agree on every case', () {
    for (final input in cases) {
      expect(
        normaliseDependencyOrigin(input),
        normaliseHostedOrigin(input),
        reason:
            'normalisation drift on "$input". club_core and '
            'club_package_reader must classify hosted URLs identically or '
            'the visibility closure and publish validation disagree',
      );
    }
  });

  test('the shared cases actually exercise both outcomes', () {
    // Guards against the parity test passing trivially because every case
    // normalises to null (or every case succeeds).
    final results = cases.map(normaliseDependencyOrigin).toList();
    expect(results.where((r) => r != null), isNotEmpty);
    expect(results.where((r) => r == null), isNotEmpty);
  });

  test('distinct origins do not collapse into one another', () {
    final origins = {
      normaliseDependencyOrigin('https://club.example.com'),
      normaliseDependencyOrigin('http://club.example.com'),
      normaliseDependencyOrigin('https://club.example.com:8443'),
      normaliseDependencyOrigin('https://other.example.com'),
    };
    expect(origins, hasLength(4));
  });
}
