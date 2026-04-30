/// Parsed options + positional arguments for `club global activate`.
library;

export '../../util/exit_codes.dart' show ExitCodes;

class GlobalActivateOptions {
  GlobalActivateOptions({
    required this.packageName,
    this.constraint,
    this.serverFlag,
    this.overwrite = false,
    this.executables = const [],
    this.noExecutables = false,
    this.features,
  });

  /// Package name — the first positional argument.
  final String packageName;

  /// Optional version constraint — the second positional argument. Passed
  /// through verbatim to `dart pub global activate`.
  final String? constraint;

  /// `--server/-s` — forces a specific logged-in club server, skipping
  /// the multi-server picker.
  final String? serverFlag;

  /// `--overwrite` — forwarded to `dart pub global activate`.
  final bool overwrite;

  /// `--executable/-x` — forwarded to `dart pub global activate`. Multiple
  /// values are allowed.
  final List<String> executables;

  /// `--no-executables/-X` — forwarded to `dart pub global activate`.
  final bool noExecutables;

  /// `--features` — forwarded to `dart pub global activate`.
  final String? features;

  /// Build the passthrough arg list for `dart pub global activate`
  /// (excluding the package name, constraint, and `--hosted-url`).
  List<String> buildPassthroughArgs() {
    return [
      if (overwrite) '--overwrite',
      for (final exe in executables) ...['--executable', exe],
      if (noExecutables) '--no-executables',
      if (features != null && features!.isNotEmpty) ...[
        '--features',
        features!,
      ],
    ];
  }
}
