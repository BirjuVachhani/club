import 'package:club_core/club_core.dart';
import 'package:test/test.dart';

void main() {
  group('PackageNameValidator', () {
    test('accepts ordinary names', () {
      for (final name in ['http', 'my_package', 'a', 'club_core', 'x1_y2']) {
        expect(
          PackageNameValidator.validate(name),
          isNull,
          reason: '$name should be valid',
        );
      }
    });

    test('rejects shape violations', () {
      expect(PackageNameValidator.validate(''), isNotNull);
      expect(PackageNameValidator.validate('MyPackage'), isNotNull);
      expect(PackageNameValidator.validate('1abc'), isNotNull);
      expect(PackageNameValidator.validate('my-package'), isNotNull);
      expect(PackageNameValidator.validate('a' * 65), isNotNull);
    });

    test('rejects Dart reserved words', () {
      expect(PackageNameValidator.validate('class'), contains('reserved word'));
      expect(PackageNameValidator.validate('typedef'), isNotNull);
    });

    // `/api/packages/versions/new` and friends are the publish flow, and
    // `/api/archives/...` is the download route. Any code that derives "the
    // package this request is about" from the first path segment would read
    // those as reads of a package named `versions` / `archives`. Reserving
    // the names removes the ambiguity at the source rather than requiring
    // every such caller to special-case it.
    test('rejects names that collide with fixed route segments', () {
      for (final name in ['versions', 'archives']) {
        final error = PackageNameValidator.validate(name);
        expect(error, isNotNull, reason: '$name must be rejected');
        expect(error, contains('reserved by this server'));
      }
    });

    test('does not reject names that merely contain a reserved segment', () {
      expect(PackageNameValidator.validate('versions_util'), isNull);
      expect(PackageNameValidator.validate('my_archives'), isNull);
    });

    test('isValid agrees with validate', () {
      expect(PackageNameValidator.isValid('versions'), isFalse);
      expect(PackageNameValidator.isValid('http'), isTrue);
    });
  });
}
