/// Well-known on-disk locations used by the club CLI.
///
/// Centralised so the Windows-versus-Unix branch lives in exactly one
/// place. Everything that persists state under the user's home directory
/// should route through here rather than rebuilding the path itself.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Directory holding the user's club configuration.
///
/// `~/.config/club` on Unix, `%APPDATA%\club` on Windows. This is the
/// directory `credentials.json` lives in, and the one `uninstall.sh
/// --purge` removes, so treat anything written here as user data rather
/// than as a disposable cache.
String clubConfigDir() {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return p.join(appData, 'club');
    }
    // APPDATA is effectively always set on Windows, but a stripped-down
    // service account or a test harness can miss it. Fall back to the
    // profile directory rather than throwing from a getter.
    final profile = Platform.environment['USERPROFILE'] ?? '.';
    return p.join(profile, 'AppData', 'Roaming', 'club');
  }
  return p.join(Platform.environment['HOME'] ?? '.', '.config', 'club');
}
