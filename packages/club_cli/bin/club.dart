import 'dart:io';

import 'package:club_cli/club_cli.dart';

Future<void> main(List<String> args) async {
  final runner = buildCommandRunner();
  try {
    await runner.run(args);
  } on Exception catch (e) {
    stderr.writeln(e);
    exit(1);
  }
}
