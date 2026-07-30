import 'dart:io';

import 'package:club_cli/club_cli.dart';
import 'package:club_cli/src/upgrade/update_notice.dart';

Future<void> main(List<String> args) async {
  final runner = buildCommandRunner();
  try {
    await runner.run(args);
  } on Exception catch (e) {
    stderr.writeln(e);
    exit(1);
  }

  // After the command, never before: this makes a network call, and
  // nothing about `club publish` should wait on GitHub. It is also
  // deliberately not inside the try above, so a failed command exits on
  // its own terms without an update hint tacked on.
  await maybeNotifyOfUpdate(command: _commandName(args));
}

/// The first non-flag argument, which is the command name.
String? _commandName(List<String> args) {
  for (final arg in args) {
    if (!arg.startsWith('-')) return arg;
  }
  return null;
}
