/// Fetches and runs the installer script that owns the actual replacement.
///
/// `club upgrade` deliberately does not reimplement download, checksum
/// verification, extraction, and binary placement: `scripts/install.sh`
/// and `scripts/install.ps1` already do all of it, and a second copy would
/// drift out of sync with the release-artifact contract in
/// `.github/workflows/build-cli.yml`.
///
/// Replacing the *running* binary is safe on Unix because `install.sh`
/// uses `install(1)`, which replaces via a temporary file and rename on
/// macOS ("Temporary files are no longer optional" per `man install`) and
/// unlinks the destination before opening it on GNU coreutils. Neither
/// path writes through to the running image. On Windows `install.ps1`
/// renames the live `club.exe` aside before copying, for the same reason.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const _installShUrl = 'https://club.birju.dev/install.sh';
const _installPs1Url = 'https://club.birju.dev/install.ps1';

/// The install one-liner for this platform, used in recovery messages.
String installOneLiner({String? version, String? installDir}) {
  if (Platform.isWindows) {
    final args = <String>[
      if (version != null) '-Version $version',
      if (installDir != null) "-InstallDir '$installDir'",
    ];
    if (args.isEmpty) return 'iwr -useb $_installPs1Url | iex';
    // Piping to iex leaves no way to pass parameters, so a parameterised
    // recovery has to download first.
    return 'iwr -useb $_installPs1Url -OutFile install.ps1; '
        './install.ps1 ${args.join(' ')}';
  }
  final args = <String>[
    if (version != null) '--version $version',
    if (installDir != null) '--install-dir "$installDir"',
  ];
  final suffix = args.isEmpty ? '' : ' -s -- ${args.join(' ')}';
  return 'curl -fsSL $_installShUrl | bash$suffix';
}

/// Something went wrong before the installer could run.
class InstallerScriptException implements Exception {
  InstallerScriptException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads an installer script and runs it.
class InstallerScript {
  InstallerScript({
    HttpClient? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? HttpClient();

  final HttpClient _client;
  final Duration timeout;

  /// Runs the installer, pinned to [version].
  ///
  /// [version] is always passed through so the script never re-resolves
  /// "latest" itself. Without it the script could land on a different
  /// version than the one just reported to the user, which is both
  /// confusing and, on the `--pre` boundary, wrong.
  ///
  /// Returns the script's exit code.
  Future<int> run({
    required String version,
    String? installDir,
    Directory? workDir,
  }) async {
    final tmp =
        workDir ?? Directory.systemTemp.createTempSync('club-upgrade-');
    try {
      final isWindows = Platform.isWindows;
      final name = isWindows ? 'install.ps1' : 'install.sh';
      final file = File(p.join(tmp.path, name));

      await _download(isWindows ? _installPs1Url : _installShUrl, file);

      // A truncated response from a proxy or CDN yields an empty file that
      // `bash` happily runs as a no-op with exit 0, which would look like
      // a successful upgrade that changed nothing. actions/setup-club hit
      // exactly this, which is why it downloads instead of piping too.
      final length = file.lengthSync();
      if (length == 0) {
        throw InstallerScriptException(
          'Downloaded installer was empty. This usually means a network or '
          'proxy problem rather than anything wrong with your install.',
        );
      }

      final process = await Process.start(
        isWindows ? 'powershell' : 'bash',
        [
          if (isWindows) ...[
            '-NoProfile',
            // A downloaded .ps1 invoked by path is blocked by the default
            // execution policy, even though the same content piped to iex
            // is not.
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            file.path,
            '-Version',
            version,
            if (installDir != null) ...['-InstallDir', installDir],
          ] else ...[
            file.path,
            '--version',
            version,
            if (installDir != null) ...['--install-dir', installDir],
          ],
        ],
        mode: ProcessStartMode.inheritStdio,
      );
      return await process.exitCode;
    } on ProcessException catch (e) {
      throw InstallerScriptException(
        'Could not run the installer: ${e.message}',
      );
    } finally {
      if (workDir == null && tmp.existsSync()) {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // A leftover temp dir is not worth failing an upgrade over.
        }
      }
    }
  }

  Future<void> _download(String url, File dest) async {
    try {
      final req = await _client.getUrl(Uri.parse(url)).timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>().timeout(timeout).catchError((_) {});
        throw InstallerScriptException(
          'Could not download the installer from $url '
          '(HTTP ${res.statusCode}).',
        );
      }
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      dest.writeAsStringSync(body);
    } on TimeoutException {
      throw InstallerScriptException('Timed out downloading $url.');
    } on SocketException catch (e) {
      throw InstallerScriptException('Could not reach $url: ${e.message}');
    }
  }

  void close() => _client.close(force: true);
}
