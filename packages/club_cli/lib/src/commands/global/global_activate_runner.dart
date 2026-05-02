/// End-to-end orchestration of `club global activate`.
///
/// Steps:
///   1. Resolve which logged-in club server provides the requested package
///      (reusing [HostingServerResolver]).
///   2. Ensure the resolved server's token is registered with
///      `dart pub` (so `dart pub global activate --hosted-url` can read it).
///   3. Shell out to `dart pub global activate` with stdio inherited so
///      compile/precompile progress streams live to the user.
library;

import '../../resolve/hosting_server_resolver.dart';
import '../../util/ensure_pub_token.dart';
import '../../util/log.dart';
import '../../util/prompt.dart';
import '../../util/pub_global.dart';
import '../../util/url.dart';
import 'global_activate_options.dart';

class GlobalActivateRunner {
  GlobalActivateRunner(this.options);

  final GlobalActivateOptions options;

  Future<int> run() async {
    info('');
    info('📦 Activating ${bold(options.packageName)}');

    // ── Resolve the server ──────────────────────────────────────────────────
    final resolver = HostingServerResolver(serverFlag: options.serverFlag);
    final ServerHit hit;
    heading('Resolving server');
    try {
      hit = await resolver.resolve(packageName: options.packageName);
    } on ResolveError catch (e) {
      error(e.message);
      if (e.hint != null) hint(e.hint!);
      return ExitCodes.config;
    } on NonInteractiveError catch (e) {
      error(e.message);
      hint('Pass --server <host> to bypass the interactive picker.');
      return ExitCodes.config;
    }

    // ── Register token with dart pub ────────────────────────────────────────
    // `dart pub global activate --hosted-url` reads credentials from the
    // local dart pub config. Register the resolved server's token now so
    // the underlying invocation doesn't fail with an auth error.
    heading('Registering token with dart pub');
    final tokenOk = await ensureDartPubToken(hit.serverUrl, hit.token);
    if (!tokenOk) return ExitCodes.software;
    detail(
      '${green('✓')} Token registered '
      '${gray('(${displayServer(hit.serverUrl)})')}',
    );

    // ── Delegate to dart pub ────────────────────────────────────────────────
    info('');
    heading('Running dart pub global activate');
    final exit = await runDartPubGlobalActivate(
      serverUrl: hit.serverUrl,
      package: options.packageName,
      constraint: options.constraint,
      extraArgs: options.buildPassthroughArgs(),
    );
    if (exit != 0) return exit;

    info('');
    success(
      'Activated ${bold(options.packageName)} from '
      '${displayServer(hit.serverUrl)}.',
    );
    return ExitCodes.success;
  }
}
