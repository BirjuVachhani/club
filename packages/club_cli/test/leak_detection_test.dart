import 'dart:io';

import 'package:club_cli/src/publish/pubspec_reader.dart';
import 'package:club_cli/src/publish/tarball_builder.dart';
import 'package:club_cli/src/publish/validators/leak_detection.dart';
import 'package:club_cli/src/publish/validators/validator.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

/// A syntactically valid Google API key: `AIza` plus exactly 35 key
/// characters. The length matters — the detector anchors on `\b`, so a key of
/// the wrong length matches nothing and would make these tests pass
/// vacuously.
const apiKey = 'AIzaSyB1234567890abcdefghijklmnopqrstuv';
const awsKey = 'AKIAIOSFODNN7EXAMPLE';

void main() {
  late Directory tmp;

  test('the fixture key is long enough to be detected at all', () {
    expect(apiKey.length, 4 + 35);
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('club-leak-test-');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Writes [files] into the package dir and runs the validator over them.
  Future<List<ValidationFinding>> scan(Map<String, String> files) async {
    for (final entry in files.entries) {
      final file = File(p.join(tmp.path, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    const yaml = 'name: host\nversion: 1.0.0\n';
    final validator = LeakDetectionValidator(
      ValidationContext(
        pubspec: PackagePubspec(
          directory: tmp.path,
          parsed: Pubspec.parse(yaml),
          rawYaml: yaml,
          rawMap: const {'name': 'host', 'version': '1.0.0'},
        ),
        tarball: BuiltTarball(
          path: p.join(tmp.path, 'host-1.0.0.tar.gz'),
          sizeBytes: 1024,
          files: files.keys.toList()..sort(),
        ),
        serverUrl: 'https://club.example',
      ),
    );
    await validator.validate();
    return validator.findings;
  }

  group('Google API keys in generated Firebase config', () {
    test('are allowed in firebase_options.dart', () async {
      final findings = await scan({
        'example/lib/firebase_options.dart':
            "const apiKey = '$apiKey';\n",
      });

      expect(findings, isEmpty);
    });

    test('are allowed in firebase_options.dart at any depth', () async {
      final findings = await scan({
        'lib/firebase_options.dart': "const apiKey = '$apiKey';\n",
      });

      expect(findings, isEmpty);
    });

    test('are allowed in google-services.json', () async {
      final findings = await scan({
        'example/android/app/google-services.json':
            '{"api_key":[{"current_key":"$apiKey"}]}\n',
      });

      expect(findings, isEmpty);
    });

    test('are allowed in GoogleService-Info.plist', () async {
      final findings = await scan({
        'example/ios/Runner/GoogleService-Info.plist':
            '<key>API_KEY</key><string>$apiKey</string>\n',
      });

      expect(findings, isEmpty);
    });
  });

  group('the exemption stays narrow', () {
    test('a Google API key in an ordinary file is still an error', () async {
      final findings = await scan({
        'lib/config.dart': "const key = '$apiKey';\n",
      });

      expect(findings, hasLength(1));
      expect(findings.single.severity, Severity.error);
      expect(findings.single.message, contains('Google API key'));
      expect(findings.single.message, contains('lib/config.dart'));
    });

    test('a similarly named file is not exempt', () async {
      final findings = await scan({
        'lib/my_firebase_options.dart': "const key = '$apiKey';\n",
      });

      expect(findings, hasLength(1));
      expect(findings.single.message, contains('Google API key'));
    });

    test('other credentials in firebase_options.dart still fail', () async {
      final findings = await scan({
        'lib/firebase_options.dart': "const aws = '$awsKey';\n",
      });

      expect(findings, hasLength(1));
      expect(findings.single.severity, Severity.error);
      expect(findings.single.message, contains('AWS access key'));
    });

    test('a private key block in firebase_options.dart still fails', () async {
      final findings = await scan({
        'lib/firebase_options.dart':
            '-----BEGIN RSA PRIVATE KEY-----\nabc\n',
      });

      expect(findings, hasLength(1));
      expect(findings.single.message, contains('private key block'));
    });

    test('a clean package produces no findings', () async {
      final findings = await scan({
        'lib/host.dart': 'int value() => 1;\n',
      });

      expect(findings, isEmpty);
    });
  });
}
