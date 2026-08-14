/// The optional "publish as which version?" step for `--from-git`.
///
/// Publishing from a git URL or a pull request is often a republish of
/// someone else's code onto your own server, where the version in the
/// source pubspec is not the one you want to occupy. This step offers a
/// chance to say so, pre-filled with whatever the flow would otherwise
/// have used, so pressing Enter changes nothing.
///
/// The step is skipped whenever an answer cannot be asked for or has
/// already been given: a non-interactive shell, CI, `--force`, or an
/// explicit `--version`.
library;

import 'package:pub_semver/pub_semver.dart' as semver;

import '../util/log.dart';
import '../util/prompt.dart';

/// Returns a human-readable problem with [raw] as a version, or null when
/// it is valid semver.
///
/// Used both to validate what the user types at the prompt and to check a
/// `--version` value before any work happens.
String? versionFormatError(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return 'Version cannot be empty.';
  try {
    semver.Version.parse(value);
    return null;
  } on FormatException {
    return 'Not valid semver: "$value". Try 1.2.3, 1.2.3-beta.1, or '
        '1.2.3+build5.';
  }
}

/// Runs the version step and returns the version the user chose, or null to
/// mean "leave it alone" (each package keeps whatever version it would have
/// published with).
///
/// [detected] is the version the publish would use if nothing is entered.
/// Pass null in `--auto` mode, where each package has its own version and
/// there is no single default to show; a value entered there applies to
/// every package in the stack.
Future<String?> promptPublishVersion({
  required bool isAuto,
  String? detected,
  int? pullRequest,
}) async {
  heading('Version');

  if (isAuto) {
    detail('every package publishes with its own version');
    if (pullRequest != null) {
      detail(gray('suffixed for PR #$pullRequest, e.g. 1.2.0-pr$pullRequest'));
    }
    detail(gray('enter a version to publish the whole stack as that '
        'version instead'));
  } else if (detected != null) {
    detail(
      'detected: ${cyan(detected)}'
      '${pullRequest == null ? '' : gray(' (PR #$pullRequest)')}',
    );
  }

  final answer = await askText(
    isAuto ? '   Publish all packages as' : '   Publish as',
    defaultValue: detected,
    validate: versionFormatError,
  );

  final choice = normalizeVersionChoice(answer, detected);
  if (choice == null) {
    detail(gray(isAuto
        ? 'keeping each package\'s own version'
        : 'keeping the detected version'));
  } else {
    detail('publishing as ${cyan(choice)}');
  }
  return choice;
}

/// Turns a raw prompt answer into a version override, or null for "change
/// nothing".
///
/// An answer equal to [detected] is the user retyping what was already
/// offered, which is not an override: returning null keeps the publish on
/// its normal path (including the `(PR #n)` label rather than
/// `(overridden)`). In `--auto` there is no default, so an empty reply
/// arrives as null and means the same thing.
String? normalizeVersionChoice(String? answer, String? detected) =>
    (answer == null || answer == detected) ? null : answer;
