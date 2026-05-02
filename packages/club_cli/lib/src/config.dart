import 'credentials.dart';
import 'util/url.dart';

/// CLI configuration helpers.
class CliConfig {
  /// Resolve the canonical server URL from a CLI flag or stored default.
  ///
  /// [fromArg] may be a bare host (`myclub.birju.dev`) or a full URL —
  /// both are folded to the canonical form via [parseServerInput].
  static String? resolveServer(String? fromArg) {
    if (fromArg != null && fromArg.isNotEmpty) {
      return parseServerInput(fromArg);
    }
    return CredentialStore.getDefaultServer();
  }
}
