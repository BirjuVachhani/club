import 'credentials.dart';

/// CLI configuration helpers.
class CliConfig {
  /// Resolve the server URL from args, env, or stored default.
  static String? resolveServer(String? fromArg) {
    if (fromArg != null && fromArg.isNotEmpty) return fromArg;
    return CredentialStore.getDefaultServer();
  }
}
