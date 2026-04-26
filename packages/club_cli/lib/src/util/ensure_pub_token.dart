/// Register a club token with the local `dart pub` installation.
///
/// `dart pub global activate --hosted-url <server>` reads credentials from
/// `~/.config/dart/pub-tokens.json` (i.e. whatever was configured with
/// `dart pub token add`). Commands that delegate to dart pub need to make
/// sure the user's club token is installed there first — otherwise the
/// underlying `dart pub` call fails with an opaque auth error.
///
/// This helper is idempotent: running it repeatedly just overwrites the
/// entry for [serverUrl]. Matches the behaviour of `club setup`.
library;

import 'dart:io';

import 'log.dart';

/// Registers [token] with `dart pub` for [serverUrl].
///
/// Returns true on success. Missing `dart` on PATH is treated as a soft
/// failure — mirrors `pub_get.dart`'s behaviour in locked-down
/// environments where the Dart SDK isn't on PATH.
Future<bool> ensureDartPubToken(String serverUrl, String token) async {
  final Process process;
  try {
    process = await Process.start(
      'dart',
      ['pub', 'token', 'add', serverUrl],
    );
  } on ProcessException {
    detail(yellow('Skipped') + gray(' (could not locate `dart` on PATH)'));
    return true;
  }
  process.stdin.writeln(token);
  await process.stdin.close();
  // Drain both pipes concurrently with exitCode: if the child fills either
  // pipe buffer while the parent is still waiting for exit, both sides
  // deadlock. Future.wait runs all three in parallel.
  final stderrBytes = <int>[];
  final results = await Future.wait<Object>([
    process.stdout.drain<void>().then((_) => 0),
    process.stderr.listen(stderrBytes.addAll).asFuture<void>().then((_) => 0),
    process.exitCode,
  ]);
  final exit = results[2] as int;
  if (exit != 0) {
    final msg = String.fromCharCodes(stderrBytes).trim();
    error(
      'Failed to register token with dart pub for $serverUrl.'
      '${msg.isEmpty ? '' : '\n  $msg'}',
    );
    return false;
  }
  return true;
}
