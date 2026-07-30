/// Works out how this `club` binary got onto the machine.
///
/// `club upgrade` replaces the CLI by re-running the installer script that
/// put it there, so it first has to know which installer that was — and
/// refuse outright when the answer is "something else entirely", such as
/// Homebrew or a `dart run` from a source checkout. Guessing wrong means
/// either clobbering a package manager's files or reporting success while
/// the old binary stays on PATH.
///
/// Detection is purely path-based. There is deliberately no receipt file:
/// one written only by future installer versions would be absent for every
/// user who is already installed, so the path-based route has to work
/// forever regardless and a second code path would only add a branch that
/// almost nobody exercises.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../version.dart';

/// How this binary was installed.
enum InstallMethod {
  /// A single binary placed by `install.sh`, e.g. `~/.local/bin/club`.
  scriptStandalone,

  /// A `bundle/` directory placed by `install.sh` plus a wrapper script,
  /// used when the build carries native libraries alongside the binary.
  scriptBundle,

  /// A single `club.exe` placed by `install.ps1`.
  scriptStandaloneWindows,

  /// A `club-bundle/` directory placed by `install.ps1` plus a `.cmd` shim.
  scriptBundleWindows,

  /// Installed through Homebrew, which owns upgrades itself.
  homebrew,

  /// Running from source via `dart run`, so there is no installed binary.
  devSource,

  /// Activated through `dart pub global activate`.
  pubGlobal,

  /// Somewhere we do not recognise.
  unknown;

  /// Whether `club upgrade` can replace this installation.
  bool get isUpgradable =>
      this == scriptStandalone ||
      this == scriptBundle ||
      this == scriptStandaloneWindows;
}

/// Where this binary lives and how it got there.
class InstallLocation {
  const InstallLocation({
    required this.method,
    required this.executablePath,
    this.destDir,
    this.bundleDir,
  });

  final InstallMethod method;

  /// The resolved path of the running executable.
  final String executablePath;

  /// Directory the installer should write into, when known.
  ///
  /// Null for every method where [InstallMethod.isUpgradable] is false.
  final String? destDir;

  /// For bundle layouts, the directory replaced wholesale.
  final String? bundleDir;

  bool get isUpgradable => method.isUpgradable;
}

/// Classifies an installation from its path and version alone.
///
/// Pure by design: every environment input is a parameter so the whole
/// table can be exercised without a real install on disk. [detectInstall]
/// is the thin wrapper that reads the actual [Platform] values.
///
/// Order matters, and the tests pin it. In particular the dev-source check
/// runs first, because a Homebrew-installed `dart` running `bin/club.dart`
/// sits under a Homebrew path and would otherwise be reported as a
/// Homebrew install of club itself.
InstallLocation classifyInstall({
  required String resolvedExecutable,
  required String? scriptPath,
  required String runningVersion,
  required bool isWindows,
}) {
  final ctx = p.Context(style: isWindows ? p.Style.windows : p.Style.posix);
  final exe = resolvedExecutable;
  final base = ctx.basename(exe);
  final baseNoExt = base.toLowerCase().endsWith('.exe')
      ? base.substring(0, base.length - 4)
      : base;

  InstallLocation at(InstallMethod method, {String? destDir, String? bundle}) =>
      InstallLocation(
        method: method,
        executablePath: exe,
        destDir: destDir,
        bundleDir: bundle,
      );

  // 1. Running from source. `clubCliVersion` is only ever the literal
  // "dev" when neither CI nor build-cli.sh has burned a real version in,
  // which means `dart run`. The executable name is a second signal for
  // an aot-snapshot build.
  const vmNames = {'dart', 'dartaotruntime'};
  if (runningVersion == 'dev' || vmNames.contains(baseNoExt.toLowerCase())) {
    return at(InstallMethod.devSource);
  }

  final segments = ctx.split(exe);

  // 2. `dart pub global activate`.
  if (scriptPath != null && ctx.split(scriptPath).contains('.pub-cache')) {
    return at(InstallMethod.pubGlobal);
  }

  // 3. Homebrew. The Cellar and libexec markers catch a custom
  // HOMEBREW_PREFIX too. Do not shell out to `brew --prefix` (slow, and
  // fails when brew is absent) and do not read HOMEBREW_PREFIX from the
  // environment — brew only sets it inside its own shell, not for
  // programs the user launches later.
  //
  // Formula/club.rb installs into libexec and symlinks bin/club, but
  // Platform.resolvedExecutable resolves symlinks, so we see the real
  // Cellar path here rather than the symlink.
  if (segments.contains('Cellar') || segments.contains('libexec')) {
    return at(InstallMethod.homebrew);
  }

  // 4 & 5. Bundle layouts: `<share>/bundle/bin/club` on Unix, or
  // `<parent>/club-bundle/bin/club.exe` on Windows.
  if (segments.length >= 3 && segments[segments.length - 2] == 'bin') {
    final bundleName = segments[segments.length - 3];
    final bundleDir = ctx.dirname(ctx.dirname(exe));
    if (isWindows && bundleName == 'club-bundle') {
      return at(InstallMethod.scriptBundleWindows, bundle: bundleDir);
    }
    if (!isWindows && bundleName == 'bundle') {
      return at(InstallMethod.scriptBundle, bundle: bundleDir);
    }
  }

  // 6 & 7. A plain binary placed by one of the installer scripts.
  if (baseNoExt == 'club') {
    return at(
      isWindows
          ? InstallMethod.scriptStandaloneWindows
          : InstallMethod.scriptStandalone,
      destDir: ctx.dirname(exe),
    );
  }

  return at(InstallMethod.unknown);
}

/// Classifies the running binary, reading the real environment.
InstallLocation detectInstall() {
  String? scriptPath;
  try {
    scriptPath = Platform.script.toFilePath();
  } on UnsupportedError {
    // A data: or http: script URI has no file path. Not a case we can
    // classify, and not one worth crashing over.
    scriptPath = null;
  }
  return classifyInstall(
    resolvedExecutable: Platform.resolvedExecutable,
    scriptPath: scriptPath,
    runningVersion: clubCliVersion,
    isWindows: Platform.isWindows,
  );
}
