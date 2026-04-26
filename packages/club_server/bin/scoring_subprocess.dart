/// Subprocess entry for scoring a single package version.
///
/// Spawned by [ScoringService] as a short-lived child process. Reads the
/// JSON-encoded [ScoringJob] from the file at argv[0], runs pana on it,
/// and writes the JSON-encoded [ScoringResult] to the file at argv[1].
/// Log lines stream to stderr (the parent pipes them into ScoringLogger).
///
/// Why file paths and not stdin/stdout: pana transitively invokes
/// `dart pub get`, whose build-hook status output goes to *stdout*. That
/// would corrupt a stdout-based result protocol. Using files sidesteps it
/// entirely — pana can print whatever it wants, we read our result from a
/// path we own.
///
/// Exit codes:
///   0 — a result was written to the result path (success OR analysis
///       failure; caller distinguishes via [ScoringResult.success])
///   1 — no result written; parent synthesizes a crash failure
///
/// Why a subprocess and not an isolate: an RCE inside pana (via an analyzer
/// plugin, build hook, or whatever) cannot reach the server's DB handles,
/// blob store, JWT secrets, or open sockets. Dart isolates share the same
/// process; subprocesses don't. See the trust model note at the top of
/// [scoring_worker.dart].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:club_server/src/scoring/scoring_worker.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'scoring_subprocess: usage: scoring_subprocess <job.json> <result.json>',
    );
    exit(1);
  }
  final jobPath = args[0];
  final resultPath = args[1];

  ScoringJob job;
  try {
    final text = await File(jobPath).readAsString();
    final map = jsonDecode(text) as Map<String, dynamic>;
    job = ScoringJob.fromJson(map);
  } catch (e, st) {
    stderr.writeln('scoring_subprocess: invalid job at $jobPath: $e');
    stderr.writeln(st);
    exit(1);
  }

  // Log lines stream to stderr — the parent pipes stderr to ScoringLogger
  // so operator-visible progress shows up in scoring.log in real time.
  void log(String line) {
    stderr.writeln(line);
  }

  try {
    final result = await runAnalysis(job, log: log);
    // Milestones around this window matter: between `runAnalysis` returning
    // and the process exiting there used to be no logs, so a stalled
    // jsonEncode or writeAsString looked identical to a hung pana run.
    log('Encoding result for ${job.packageName} ${job.version}');
    final resultJson = jsonEncode(result.toJson());
    log(
      'Writing result file (${resultJson.length} bytes) for '
      '${job.packageName} ${job.version}',
    );
    await File(resultPath).writeAsString(resultJson);
    log(
      'Result written; exiting cleanly for '
      '${job.packageName} ${job.version}',
    );
    await stderr.flush();
    exit(0);
  } catch (e, st) {
    // runAnalysis catches internally and returns a failure ScoringResult,
    // so reaching this branch means the failure happened in encoding,
    // writing, or somewhere even more catastrophic (OOM, host kill, etc.).
    log(
      'scoring_subprocess: uncaught for ${job.packageName} '
      '${job.version}: $e',
    );
    log('$st');
    // Best-effort: write a structured failure result so the parent can
    // record a real error message instead of falling back to the generic
    // "exited with code 1" synthesis.
    try {
      final failure = ScoringResult(
        packageName: job.packageName,
        version: job.version,
        success: false,
        errorMessage: 'Subprocess uncaught: $e',
      );
      await File(resultPath).writeAsString(jsonEncode(failure.toJson()));
    } catch (writeErr) {
      log(
        'scoring_subprocess: also failed to write failure result for '
        '${job.packageName} ${job.version}: $writeErr',
      );
    }
    await stderr.flush();
    exit(1);
  }
}
