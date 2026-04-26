/// Mirrors dart pub's
/// [`PubspecTypoValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/pubspec_typo.dart):
/// warns about pubspec field names that look like typos of known fields.
library;

import 'validator.dart';

class PubspecTypoValidator extends Validator {
  PubspecTypoValidator(super.context);

  /// List of keys recognised by pub; kept in sync with
  /// https://github.com/dart-lang/pub/blob/master/lib/src/validator/pubspec_typo.dart
  static const List<String> _known = [
    'name',
    'version',
    'description',
    'homepage',
    'repository',
    'issue_tracker',
    'documentation',
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
    'environment',
    'executables',
    'publish_to',
    'false_secrets',
    'flutter',
    'screenshots',
    'platforms',
    'funding',
    'topics',
    'ignored_advisories',
    'workspace',
    'resolution',
  ];

  @override
  String get name => 'PubspecTypoValidator';

  @override
  Future<void> validate() async {
    var count = 0;
    for (final key in context.pubspec.rawMap.keys) {
      if (_known.contains(key)) continue;

      var bestRatio = 100.0;
      var closest = '';
      for (final valid in _known) {
        final ratio = _editDistance(key, valid) / (valid.length + key.length);
        if (ratio < bestRatio) {
          bestRatio = ratio;
          closest = valid;
        }
      }

      // 0.21 is pub's magic threshold based on common typos observed on
      // pub.dev.
      if (bestRatio > 0 && bestRatio < 0.21) {
        warning(
          '"$key" is not a key recognized by pub - '
          'did you mean "$closest"?',
        );
        count++;
        if (count == 3) break;
      }
    }
  }

  int _editDistance(String a, String b) {
    final n = a.length;
    final m = b.length;
    final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = 0; i <= n; i++) {
      dp[i][0] = i;
    }
    for (var j = 0; j <= m; j++) {
      dp[0][j] = j;
    }
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        dp[i][j] = [
          dp[i - 1][j] + 1,
          dp[i][j - 1] + 1,
          dp[i - 1][j - 1] + cost,
        ].reduce((a, b) => a < b ? a : b);
      }
    }
    return dp[n][m];
  }
}
