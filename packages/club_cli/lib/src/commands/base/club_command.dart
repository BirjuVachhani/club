/// Shared base class for club CLI commands.
///
/// Centralises the credential lookup + `ClubClient` construction that was
/// duplicated across token/publish commands.
library;

import 'package:args/command_runner.dart';
import 'package:club_api/club_api.dart';

import '../../credentials.dart';
import '../../util/url.dart';

/// Common base for every club command.
///
/// Subclasses can call [clientFor] to obtain an authenticated client for a
/// given server URL, or [tokenFor] to peek at a stored token.
abstract class ClubCommand extends Command<void> {
  /// Build a [ClubClient] for [serverUrl] using a stored credential.
  ///
  /// Throws [UsageException] if the user is not logged in to that server,
  /// so the CLI prints a clean message instead of a stack trace.
  ClubClient clientFor(String serverUrl) {
    final canonical = parseServerInput(serverUrl);
    final token = CredentialStore.getToken(canonical);
    if (token == null) {
      throw UsageException(
        'Not logged in to ${displayServer(canonical)}.',
        'Run: club login ${displayServer(canonical)}',
      );
    }
    return ClubClient(serverUrl: Uri.parse(canonical), token: token);
  }

  /// Lookup a stored token without constructing a client.
  String? tokenFor(String serverUrl) =>
      CredentialStore.getToken(parseServerInput(serverUrl));
}
