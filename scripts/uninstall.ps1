<#
.SYNOPSIS
    uninstall.ps1 - Remove a club CLI installation created by install.ps1.

.DESCRIPTION
    Windows counterpart to uninstall.sh. Removes only the paths install.ps1
    writes to:

      <InstallDir>\club.exe          standalone binary
      <InstallDir>\club.cmd          shim used by the bundle layout
      <InstallDir>\club.exe.old-*    leftovers from a self-upgrade
      <InstallDir>\..\club-bundle    bundle dir, only if the archive had lib\

    -Purge additionally deletes %APPDATA%\club (credentials and config) and
    unregisters the tokens `club login` / `club setup` handed to
    `dart pub token add`. Those live in dart's own config rather than ours,
    so deleting %APPDATA%\club alone would leave a live token behind.

.EXAMPLE
    # One-liner:
    iwr -useb https://club.birju.dev/uninstall.ps1 | iex

.EXAMPLE
    # Preview without deleting anything:
    .\uninstall.ps1 -DryRun

.EXAMPLE
    # Remove the binary, credentials, and registered pub tokens:
    .\uninstall.ps1 -Purge

.EXAMPLE
    # Piped through iex, where parameters cannot be passed directly:
    $env:CLUB_PURGE = '1'; iwr -useb https://club.birju.dev/uninstall.ps1 | iex

.PARAMETER InstallDir
    Directory club was installed into. Falls back to $env:CLUB_INSTALL_DIR,
    then to "$env:USERPROFILE\.club\bin". Must match whatever was passed to
    install.ps1.

.PARAMETER Purge
    Also delete %APPDATA%\club and unregister club's dart pub tokens.
    Falls back to $env:CLUB_PURGE.

.PARAMETER DryRun
    Print what would be removed, then exit without deleting anything.
    Falls back to $env:CLUB_DRY_RUN.

.PARAMETER KeepPath
    Leave the install directory in the user PATH. By default, if install.ps1's
    PATH instructions were followed, that entry is removed.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$Purge,
    [switch]$DryRun,
    [switch]$KeepPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Param defaults are evaluated before $env: lookups, so resolve fallbacks
# here rather than in the param block. The env vars exist because piping
# through `iex` gives no way to pass parameters.
if (-not $InstallDir) { $InstallDir = if ($env:CLUB_INSTALL_DIR) { $env:CLUB_INSTALL_DIR } else { "$env:USERPROFILE\.club\bin" } }
if (-not $Purge)      { $Purge      = [bool]$env:CLUB_PURGE }
if (-not $DryRun)     { $DryRun     = [bool]$env:CLUB_DRY_RUN }

# Mirrors clubConfigDir() in packages/club_cli/lib/src/util/paths.dart:
# %APPDATA%\club on Windows, with a USERPROFILE fallback for stripped-down
# accounts where APPDATA is unset.
$configDir = if ($env:APPDATA) {
    Join-Path $env:APPDATA 'club'
} else {
    Join-Path $env:USERPROFILE 'AppData\Roaming\club'
}
$credentials = Join-Path $configDir 'credentials.json'

# install.ps1 keeps the bundle as a sibling of the install dir so a custom
# -InstallDir keeps everything under one parent.
$bundleDir = Join-Path (Split-Path -Parent $InstallDir) 'club-bundle'

# Collect targets that actually exist, so the output never lists paths that
# were never there.
$targets = [System.Collections.Generic.List[string]]::new()
foreach ($candidate in @(
    (Join-Path $InstallDir 'club.exe'),
    (Join-Path $InstallDir 'club.cmd')
)) {
    if (Test-Path $candidate) { $targets.Add($candidate) }
}

# A self-upgrade renames the running .exe aside because Windows will not
# delete the image of a running process. Those survivors are ours to clean.
Get-ChildItem -Path $InstallDir -Filter 'club.exe.old-*' -ErrorAction SilentlyContinue |
    ForEach-Object { $targets.Add($_.FullName) }

if (Test-Path $bundleDir) { $targets.Add($bundleDir) }
if ($Purge -and (Test-Path $configDir)) { $targets.Add($configDir) }

# ── dart pub tokens ──────────────────────────────────────────────────────
# Read the server list before deleting anything, since credentials.json is
# the only record of which servers were ever configured.
$servers = @()
if ($Purge -and (Test-Path $credentials)) {
    try {
        $parsed = Get-Content -Raw -Path $credentials | ConvertFrom-Json
        if ($parsed.servers) {
            $servers = @($parsed.servers.PSObject.Properties | ForEach-Object { $_.Name })
        }
    } catch {
        # A hand-edited or truncated credentials.json should not block the
        # uninstall; the user just gets no automatic token cleanup.
        Write-Host "Note: could not parse $credentials, skipping pub token cleanup."
    }
}

# ── PATH entry ───────────────────────────────────────────────────────────
# install.ps1 does not modify PATH itself, it prints a command for the user
# to run. Undo that only if the exact entry is present.
$pathEntryFound = $false
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$normalizedInstallDir = $InstallDir.TrimEnd('\')
if (-not $KeepPath -and $userPath) {
    $pathEntryFound = @($userPath -split ';' | Where-Object {
        $_.Trim().TrimEnd('\') -ieq $normalizedInstallDir
    }).Count -gt 0
}

if ($targets.Count -eq 0 -and $servers.Count -eq 0 -and -not $pathEntryFound) {
    Write-Host "Nothing to remove."
    Write-Host "  Looked for: $(Join-Path $InstallDir 'club.exe'), $bundleDir$(if ($Purge) { ", $configDir" })"
    if (-not $Purge -and (Test-Path $configDir)) {
        Write-Host ''
        Write-Host "Note: $configDir still contains credentials. Re-run with -Purge to delete it."
    }
    exit 0
}

Write-Host "The following will be removed:"
foreach ($t in $targets) { Write-Host "  - $t" }
foreach ($s in $servers) { Write-Host "  - dart pub token for $s" }
if ($pathEntryFound)     { Write-Host "  - $normalizedInstallDir (from your user PATH)" }

if ($DryRun) {
    Write-Host ''
    Write-Host 'Dry run. Nothing deleted.'
    exit 0
}

# Unregister pub tokens before deleting credentials.json.
if ($servers.Count -gt 0) {
    Write-Host ''
    $dart = Get-Command dart -ErrorAction SilentlyContinue
    if ($dart) {
        foreach ($s in $servers) {
            # dart writes failures to stderr and returns non-zero; swallow
            # the output and branch on the exit code so a missing token
            # reads as a warning rather than a crash.
            & dart pub token remove $s 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  OK  unregistered dart pub token for $s"
            } else {
                Write-Host "  !   could not unregister $s" -ForegroundColor Yellow
                Write-Host "      run: dart pub token remove $s" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host '  !   dart is not on PATH, so these pub tokens were left in place:' -ForegroundColor Yellow
        foreach ($s in $servers) {
            Write-Host "        dart pub token remove $s" -ForegroundColor Yellow
        }
    }
}

$failed = @()
foreach ($t in $targets) {
    try {
        Remove-Item -Path $t -Recurse -Force -ErrorAction Stop
    } catch {
        # Most likely cause: club.exe is running, or a shell has the bundle
        # dir as its working directory. Keep going and report at the end.
        $failed += $t
    }
}

if ($pathEntryFound) {
    # Re-read rather than reusing $userPath: something else may have written
    # to the user PATH between the check above and now, and clobbering that
    # would be a much worse bug than leaving a stale entry.
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $kept = @($current -split ';' | Where-Object {
        $_.Trim() -ne '' -and $_.Trim().TrimEnd('\') -ine $normalizedInstallDir
    })
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    Write-Host ''
    Write-Host "Removed $normalizedInstallDir from your user PATH."
    Write-Host 'Open a new terminal for that to take effect.'
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host 'Some paths could not be removed:' -ForegroundColor Yellow
    foreach ($f in $failed) { Write-Host "  - $f" -ForegroundColor Yellow }
    Write-Host 'Close any shell running club and re-run this script.' -ForegroundColor Yellow
    exit 1
}

Write-Host 'OK  club CLI uninstalled.'

if (-not $Purge -and (Test-Path $configDir)) {
    Write-Host ''
    Write-Host "Note: $configDir was kept, along with any tokens registered with"
    Write-Host '      dart pub. Re-run with -Purge to delete both.'
}
