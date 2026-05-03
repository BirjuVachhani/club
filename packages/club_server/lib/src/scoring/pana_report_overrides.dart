/// Club-specific adjustments to the pana report.
///
/// Pana is built for pub.dev's threat model: anyone can publish under
/// any name and claim a repo, so pana enforces checks that establish
/// "this package was actually published from the repo it claims." Some
/// of those checks make no sense on a private Club registry, where
/// uploaders are already authenticated. Rather than fork pana, we
/// post-process its report to re-grant points for those specific
/// checks.
///
/// Each override is intentionally narrow — pattern-matched against the
/// exact pana wording for the failure case we know is spurious. If
/// pana changes its wording in a future release, the matcher will fail
/// to fire and the score will revert to pana's verdict (a deduction
/// you'll notice). That's the safe direction: false negatives on the
/// override beat silently inflating scores when pana's check has been
/// changed and might now be valid.
library;

/// Applies all club-specific overrides to a pana `Summary.toJson()`
/// map in place. Returns silently if the structure doesn't match what
/// we expect (older/newer pana, partial failure, etc.) — overriding is
/// best-effort.
void applyClubOverrides(Map<String, dynamic> summaryJson) {
  final report = summaryJson['report'];
  if (report is! Map<String, dynamic>) return;
  final sections = report['sections'];
  if (sections is! List) return;

  for (final s in sections) {
    if (s is! Map<String, dynamic>) continue;
    if (s['id'] != 'convention') continue;
    _maybeRegrantPublishTo(s);
  }
}

/// Re-grant the "Provide a valid `pubspec.yaml`" criterion when the
/// SOLE failure is that the repo's pubspec defines `publish_to`. Pana
/// checks `containsKey('publish_to')` (see pana's check_repository.dart),
/// so `publish_to: none` — the standard way to lock a private package
/// against accidental pub.dev publishes — fails identically to a
/// hostile redirect URL would. On a Club server this verification
/// does not apply: uploaders are pre-authenticated.
///
/// We rewrite the criterion to status `[*]` 10/10 with a one-line
/// explanation, then bump the section's `grantedPoints` and `status`.
/// Top-level totals are derived from the sections (it's a getter on
/// the live object, and the JSON shape doesn't store them), so callers
/// computing a new total must sum from the modified sections list.
void _maybeRegrantPublishTo(Map<String, dynamic> section) {
  final mdSummary = section['summary'];
  if (mdSummary is! String) return;
  final granted = section['grantedPoints'];
  final max = section['maxPoints'];
  if (granted is! int || max is! int) return;
  if (granted >= max) return; // already passed

  final rewritten = _rewritePublishToCriterion(mdSummary);
  if (rewritten == null) return;

  section['summary'] = rewritten;
  final newGranted = granted + 10;
  section['grantedPoints'] = newGranted;
  section['status'] = newGranted >= max
      ? 'passed'
      : (newGranted > 0 ? 'partial' : 'failed');
}

/// Returns the rewritten section markdown if the publish_to criterion
/// failed solely due to the publish_to check, else null.
///
/// Detection rules (all must hold):
///   1. The criterion `### [x] 0/10 points: Provide a valid \`pubspec.yaml\``
///      exists.
///   2. Its body contains exactly one issue. Pana renders an `Issue`
///      with a suggestion as a `<details><summary>...</summary>...</details>`
///      block, and an issue without a suggestion as a leading `* ` bullet.
///      Multiple issues mean other things are wrong too — bail.
///   3. The single issue is the "Failed to verify repository URL" one,
///      and its suggestion text contains pana's verbatim sentence about
///      the repository defining `publish_to`.
String? _rewritePublishToCriterion(String md) {
  final headRe = RegExp(
    r'^### \[x\] 0/10 points: Provide a valid `pubspec\.yaml`',
    multiLine: true,
  );
  final headMatch = headRe.firstMatch(md);
  if (headMatch == null) return null;

  // Body of this criterion: from end-of-heading line up to the next
  // `### [` heading (or end of string if it's the last criterion).
  final bodyStart = headMatch.end;
  final remainder = md.substring(bodyStart);
  final nextHeadRe = RegExp(r'^### \[', multiLine: true);
  final nextMatch = nextHeadRe.firstMatch(remainder);
  final bodyEnd = nextMatch == null ? md.length : bodyStart + nextMatch.start;
  final body = md.substring(bodyStart, bodyEnd);

  // Count issues. Pana issue rendering (see _common.dart):
  //   - With suggestion or span:  <details><summary>desc</summary>…</details>
  //   - Without:                  * desc
  final detailsCount = '<summary>'.allMatches(body).length;
  final bulletIssueCount = RegExp(
    r'^\* ',
    multiLine: true,
  ).allMatches(body).length;
  if (detailsCount + bulletIssueCount != 1) return null;
  if (detailsCount != 1) return null;
  if (!body.contains('Failed to verify repository URL.')) return null;
  if (!body.contains('from the repository defines `publish_to`')) return null;

  // Replacement criterion. Keep the wording explicit so the audit
  // trail in the report makes clear we adjusted the score.
  const replacement =
      '### [*] 10/10 points: Provide a valid `pubspec.yaml`\n\n'
      "Adjusted by Club: pana failed this check because the repository's "
      '`pubspec.yaml` defines a `publish_to` key. On a private Club registry '
      'this is the expected configuration (it prevents accidental publishes '
      "to pub.dev), so pana's check does not apply and the points are "
      're-granted.\n\n';

  return md.substring(0, headMatch.start) +
      replacement +
      md.substring(bodyEnd);
}
