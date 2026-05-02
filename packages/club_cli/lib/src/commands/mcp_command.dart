/// `club mcp` command.
///
/// Starts a stdio Model Context Protocol server so AI clients (Claude
/// Desktop, Cursor, Cline, Continue, Zed, …) can browse and reason about
/// packages on a Club server.
///
/// Modes:
///   - No `--server` flag → multi-server mode. Every logged-in server in
///     `~/.config/club/credentials.json` is exposed; tools take an
///     optional `server` argument and `switch_server` mutates the active
///     default.
///   - `--server <url>` (with or without `--token`) → pinned mode.
///     Exactly one server is exposed. `--token` lets the AI client config
///     embed credentials inline without a prior `club login`.
///
/// Stdio is owned by the MCP transport — every line on stdout MUST be a
/// JSON-RPC frame. We flip `silenceStdout` in `log.dart` before any handler
/// can run so transitive `info()`/`hint()` calls don't corrupt the stream.
///
/// Extends [Command] directly rather than `ClubCommand` because there is no
/// single client to build at start-up — the `ServerRegistry` owns one
/// [ClubClient] per registered server. `clientFor`/`tokenFor` from the base
/// class would not be reachable from inside MCP tool handlers anyway.
library;

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_mcp/stdio.dart';

import '../mcp/club_mcp_server.dart';
import '../mcp/server_registry.dart';
import '../util/exit_codes.dart';
// Aliased so we can flip `silenceStdout` and call writers without ambiguity.
// Other commands import unaliased; this command is the one place that
// mutates a top-level field from log.dart.
import '../util/log.dart' as log;
import '../util/url.dart';

class McpCommand extends Command<void> {
  McpCommand() {
    argParser
      ..addOption(
        'server',
        abbr: 's',
        help:
            'Pin the MCP server to one Club host (e.g. myclub.birju.dev). '
            'When omitted, every logged-in server is exposed and tools '
            'take an optional `server` argument. Accepts a full URL too.',
        valueHelp: 'host',
      )
      ..addOption(
        'token',
        abbr: 't',
        help:
            'Bearer token (PAT) to use instead of the stored credential. '
            'Requires --server. Lets AI client configs embed credentials '
            'inline without a prior `club login`.',
        valueHelp: 'pat',
      );
  }

  @override
  String get name => 'mcp';

  @override
  String get description =>
      'Start an MCP server exposing Club packages to AI clients over stdio.';

  @override
  String get invocation => 'club mcp [options]';

  @override
  Future<void> run() async {
    final results = argResults!;
    final serverFlag = (results['server'] as String?)?.trim();
    final tokenFlag = (results['token'] as String?)?.trim();

    if (tokenFlag != null && tokenFlag.isNotEmpty) {
      if (serverFlag == null || serverFlag.isEmpty) {
        throw UsageException(
          '--token requires --server.',
          'club mcp --server <host> --token <pat>',
        );
      }
    }

    final String? canonicalServer;
    if (serverFlag != null && serverFlag.isNotEmpty) {
      try {
        canonicalServer = parseServerInput(serverFlag);
      } on FormatException catch (e) {
        throw UsageException(e.message, 'club mcp --server <host>');
      }
    } else {
      canonicalServer = null;
    }

    // Critical: silence every stdout writer in `log.dart` before the
    // registry construction runs (it might emit warnings via `warning()`,
    // which routes to stderr — fine — but also before *anything* else can
    // write a stray line). MCP frames are line-delimited JSON-RPC; one
    // bad print and the parent process disconnects.
    log.silenceStdout = true;

    final ServerRegistry registry;
    try {
      registry = canonicalServer != null
          ? ServerRegistry.pinned(serverUrl: canonicalServer, token: tokenFlag)
          : ServerRegistry.discovered();
    } on ServerRegistryError catch (e) {
      // Re-allow stderr output for the user-facing error. log.error already
      // routes to stderr, so it's safe even with silenceStdout=true.
      log.silenceStdout = false;
      log.error(e.message);
      if (e.hint != null) log.hint(e.hint!);
      exitCode = ExitCodes.config;
      return;
    }

    final channel = stdioChannel(input: stdin, output: stdout);
    ClubMcpServer(channel, registry);

    // The MCP server lives until stdin closes. stdioChannel uses
    // withCloseGuarantee, so when stdin EOFs the sink's done future
    // completes too — that's our signal to release HTTP clients before
    // the process unwinds.
    try {
      await channel.sink.done;
    } finally {
      registry.closeAll();
    }
  }
}
