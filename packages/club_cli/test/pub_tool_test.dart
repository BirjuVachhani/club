import 'package:club_cli/src/util/pub_tool.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

void main() {
  group('pubToolFor', () {
    test('pure Dart package uses dart pub', () {
      expect(
        pubToolFor(
          Pubspec.parse('''
name: club_cli
environment:
  sdk: ^3.11.0
dependencies:
  path: ^1.9.1
'''),
        ),
        PubTool.dart,
      );
    });

    test('flutter SDK dependency uses flutter pub', () {
      expect(
        pubToolFor(
          Pubspec.parse('''
name: auth_kit
environment:
  sdk: ^3.12.0
dependencies:
  flutter:
    sdk: flutter
'''),
        ),
        PubTool.flutter,
      );
    });

    test('flutter_test in dev_dependencies alone uses flutter pub', () {
      // Root dev_dependencies participate in version solving, so this is
      // enough to make `dart pub get` refuse.
      expect(
        pubToolFor(
          Pubspec.parse('''
name: some_package
environment:
  sdk: ^3.12.0
dependencies:
  meta: ^1.16.0
dev_dependencies:
  flutter_test:
    sdk: flutter
'''),
        ),
        PubTool.flutter,
      );
    });

    test('environment.flutter constraint alone uses flutter pub', () {
      expect(
        pubToolFor(
          Pubspec.parse('''
name: plugin_iface
environment:
  sdk: ^3.12.0
  flutter: ">=3.44.0"
dependencies:
  meta: ^1.16.0
'''),
        ),
        PubTool.flutter,
      );
    });

    test('a non-flutter sdk dependency does not select flutter pub', () {
      expect(
        pubToolFor(
          Pubspec.parse('''
name: uses_other_sdk
environment:
  sdk: ^3.12.0
dependencies:
  some_pkg:
    sdk: fuchsia
'''),
        ),
        PubTool.dart,
      );
    });

    test('a dep literally named flutter but hosted does not select flutter', () {
      // `dart pub` only balks at SDK-sourced Flutter deps. A hosted package
      // that happens to be called `flutter` resolves fine.
      expect(
        pubToolFor(
          Pubspec.parse('''
name: odd_one
environment:
  sdk: ^3.12.0
dependencies:
  flutter: ^1.0.0
'''),
        ),
        PubTool.dart,
      );
    });
  });

  group('PubTool', () {
    test('maps to the expected executables', () {
      expect(PubTool.dart.executable, 'dart');
      expect(PubTool.flutter.executable, 'flutter');
    });
  });
}
