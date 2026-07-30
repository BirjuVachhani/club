/// End-to-end orchestration of `club add`.
///
/// Steps:
///   1. Parse positional args into [AddRequest]s.
///   2. For each request, resolve which club server provides it
///      (fanning out or prompting when needed).
///   3. Write all resolved entries into pubspec.yaml atomically.
///   4. Run `pub get` unless `--dry-run`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../publish/pubspec_reader.dart';
import '../util/log.dart';
import '../util/prompt.dart';
import '../util/pub_get.dart';
import '../util/pub_tool.dart';
import '../util/url.dart';
import 'add_options.dart';
import 'descriptor_parser.dart';
import 'package_resolver.dart';
import 'pubspec_writer.dart';

class AddRunner {
  AddRunner(this.options);

  final AddOptions options;

  Future<int> run() async {
    // ── Parse descriptors ───────────────────────────────────────────────────
    final List<AddRequest> requests;
    try {
      requests = parseDescriptors(options.args);
    } on DescriptorParseError catch (e) {
      error(e.message);
      if (e.hint != null) hint(e.hint!);
      return ExitCodes.data;
    }

    final pkgDir = p.absolute(
      options.directory.isEmpty ? Directory.current.path : options.directory,
    );
    if (!File(p.join(pkgDir, 'pubspec.yaml')).existsSync()) {
      error('No pubspec.yaml found in $pkgDir');
      return ExitCodes.noInput;
    }

    info('');
    info(
      '📦 Adding ${bold('${requests.length}')} '
      '${requests.length == 1 ? 'package' : 'packages'}',
    );
    detail('to $pkgDir');

    // ── Resolve each request ────────────────────────────────────────────────
    // Sequential, not parallel: multi-server conflicts trigger interactive
    // pickers, and two pickers racing for stdin would be unusable.
    final resolver = PackageResolver(serverFlag: options.serverFlag);
    final resolved = <ResolvedPackage>[];
    heading('Resolving packages');
    try {
      for (final r in requests) {
        resolved.add(await resolver.resolve(r));
      }
    } on ResolveError catch (e) {
      error(e.message);
      if (e.hint != null) hint(e.hint!);
      return ExitCodes.config;
    } on NonInteractiveError catch (e) {
      error(e.message);
      hint('Pass --server <host> to bypass the interactive picker.');
      return ExitCodes.config;
    }

    // ── Apply edits ─────────────────────────────────────────────────────────
    heading(options.dryRun ? 'Dry-run: preview' : 'Updating pubspec.yaml');
    final changes = await PubspecWriter(
      packageDir: pkgDir,
      dryRun: options.dryRun,
    ).apply(resolved);

    for (final c in changes) {
      final section = c.resolved.request.section.key;
      detail(
        '${green(c.action)} '
        '${bold(c.resolved.request.name)} ${cyan(c.constraint)} '
        '${gray('→ $section')}'
        ' ${gray('(${displayServer(c.resolved.serverUrl)})')}',
      );
    }

    if (options.dryRun) {
      info('');
      box([
        bold('Dry-run complete'),
        gray('pubspec.yaml was not modified.'),
      ]);
      return ExitCodes.success;
    }

    // `club add` resolves the project in place, so it inherits pub's
    // workspace escalation: in a workspace, this resolves the whole
    // workspace. Detect the front-end from this package's pubspec; runPub's
    // retry covers the case where a *sibling* is the one needing Flutter.
    final ok = await runPubGet(pkgDir, tool: _pubToolFor(pkgDir));
    if (!ok) return ExitCodes.data;

    info('');
    success(
      'Added ${changes.length} '
      '${changes.length == 1 ? 'package' : 'packages'}.',
    );
    return ExitCodes.success;
  }

  /// Front-end needed to resolve the package at [dir]. Falls back to
  /// [PubTool.dart] when the pubspec cannot be parsed — [runPub] still
  /// recovers via its Flutter retry.
  PubTool _pubToolFor(String dir) {
    try {
      return pubToolFor(readPubspec(dir).parsed);
    } on Object {
      return PubTool.dart;
    }
  }
}
