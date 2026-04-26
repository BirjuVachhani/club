/// `dart pub global` invocations used by `club global activate/deactivate`.
///
/// Runs with inherited stdio so the user sees compile/precompile progress
/// in real time — activating a package can take many seconds, and silent
/// hangs would look broken.
library;

import 'dart:io';

import 'log.dart';

/// Runs `dart pub global activate --hosted-url SERVER PACKAGE
/// [constraint] [extra args]` with inherited stdio.
///
/// Returns the process exit code. A [ProcessException] (e.g. `dart` not on
/// PATH) is surfaced as a clean error + non-zero exit rather than an
/// unhandled throw.
Future<int> runDartPubGlobalActivate({
  required String serverUrl,
  required String package,
  String? constraint,
  List<String> extraArgs = const [],
}) async {
  final args = <String>[
    'pub',
    'global',
    'activate',
    '--hosted-url',
    serverUrl,
    package,
    if (constraint != null && constraint.isNotEmpty) constraint,
    ...extraArgs,
  ];
  return _runInherited(args);
}

/// Runs `dart pub global deactivate <package>` with inherited stdio.
///
/// Deactivation works purely against the local dart pub cache — no club
/// server involvement, no token needed.
Future<int> runDartPubGlobalDeactivate(String package) {
  return _runInherited(['pub', 'global', 'deactivate', package]);
}

Future<int> _runInherited(List<String> args) async {
  try {
    final process = await Process.start(
      'dart',
      args,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  } on ProcessException {
    error('Could not locate `dart` on PATH.');
    hint('Install the Dart SDK: https://dart.dev/get-dart');
    return 127;
  }
}
