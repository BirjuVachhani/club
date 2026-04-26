<#
.SYNOPSIS
    install.ps1 - Download the club CLI from a GitHub Release and put it on PATH.

.DESCRIPTION
    Windows counterpart to install.sh. Resolves the latest release tag (or
    a pinned version), downloads the matching .zip + SHA256SUMS.txt, verifies
    the checksum, and copies the binary into the install directory.

.EXAMPLE
    # One-liner (newest release, including pre-releases):
    iwr -useb https://club.birju.dev/install.ps1 | iex

.EXAMPLE
    # Pin a version when piped through iex:
    $env:CLUB_VERSION = '0.1.0'; iwr -useb https://club.birju.dev/install.ps1 | iex

.EXAMPLE
    # Direct invocation with named parameters:
    .\install.ps1 -Version 0.1.0 -InstallDir "$env:LOCALAPPDATA\Programs\club\bin"

.PARAMETER Version
    Specific release tag to install (e.g. '0.1.0'). Falls back to
    $env:CLUB_VERSION, then to the newest release on GitHub.

.PARAMETER InstallDir
    Directory to copy club.exe into. Falls back to $env:CLUB_INSTALL_DIR,
    then to "$env:USERPROFILE\.club\bin".

.PARAMETER Repo
    GitHub owner/repo to download from. Falls back to $env:CLUB_REPO,
    then to 'BirjuVachhani/club'. Provided so forks can ship their own
    builds without modifying the script.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Version,
    [string]$InstallDir,
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
# Suppress the Invoke-WebRequest progress bar. On PowerShell 5.1 it
# writes to the host stream and can both slow downloads massively and
# garble output when the script is piped through `iex`.
$ProgressPreference = 'SilentlyContinue'

# Param defaults are evaluated before $env: lookups, so resolve fallbacks
# here rather than in the param block.
if (-not $Version)     { $Version     = $env:CLUB_VERSION }
if (-not $InstallDir)  { $InstallDir  = if ($env:CLUB_INSTALL_DIR) { $env:CLUB_INSTALL_DIR } else { "$env:USERPROFILE\.club\bin" } }
if (-not $Repo)        { $Repo        = if ($env:CLUB_REPO) { $env:CLUB_REPO } else { 'BirjuVachhani/club' } }

# Only x64 Windows builds exist today; arm64 Windows would need a new
# matrix entry in build-cli.yml first.
$target = 'windows-x64'

# Resolve the tag. /releases/latest skips pre-releases; /releases?per_page=1
# returns the newest entry of any kind, matching install.sh's behaviour.
if (-not $Version) {
    Write-Host "Resolving latest release from $Repo..."
    $headers = @{ Accept = 'application/vnd.github+json' }
    # @() forces array context — Invoke-RestMethod can unwrap a 1-element
    # JSON array into a single object, which would break $releases[0].
    $releases = @(Invoke-RestMethod -Headers $headers -UseBasicParsing `
        -Uri "https://api.github.com/repos/$Repo/releases?per_page=1")
    if ($releases.Count -eq 0) {
        throw "No releases found for $Repo."
    }
    $tag = $releases[0].tag_name
} else {
    $tag = $Version
}

$resolvedVersion = $tag -replace '^v',''
$archiveName = "club-cli-$resolvedVersion-$target.zip"
$sumsName = 'SHA256SUMS.txt'
$base = "https://github.com/$Repo/releases/download/$tag"

# Detect any existing installation so we can print an accurate
# upgrade/reinstall/install message and, in the PATH-hint section,
# warn if some *other* club.exe is shadowing the one we install.
$installedPath = $null
$installedVersion = $null
$candidates = @(
    (Join-Path $InstallDir 'club.exe'),
    (Join-Path $InstallDir 'club.cmd'),
    (Join-Path (Split-Path -Parent $InstallDir) 'club-bundle\bin\club.exe')
)
foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { $installedPath = $candidate; break }
}
if (-not $installedPath) {
    $cmd = Get-Command club -ErrorAction SilentlyContinue
    if ($cmd) { $installedPath = $cmd.Source }
}
if ($installedPath) {
    try {
        $versionOutput = & $installedPath --version 2>&1 | Out-String
        $match = [regex]::Match($versionOutput, '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?')
        if ($match.Success) { $installedVersion = $match.Value }
    } catch {
        # Binary exists but --version failed; treat as unknown version.
    }
}

if ($installedVersion) {
    if ($installedVersion -eq $resolvedVersion) {
        Write-Host "Reinstalling club $resolvedVersion ($target) over existing $installedPath"
    } else {
        Write-Host "Upgrading club $installedVersion -> $resolvedVersion ($target)"
    }
} else {
    Write-Host "Installing club CLI $resolvedVersion ($target)"
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("club-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    $archivePath = Join-Path $tmp $archiveName
    $sumsPath = Join-Path $tmp $sumsName

    Write-Host "  | downloading $archiveName"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$archiveName" -OutFile $archivePath
    } catch {
        throw "Could not download $base/$archiveName - check the release exists and includes a $target build. ($($_.Exception.Message))"
    }

    Write-Host "  | downloading $sumsName"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$sumsName" -OutFile $sumsPath
    } catch {
        throw "Release $tag has no $sumsName - refusing to install without a checksum. ($($_.Exception.Message))"
    }

    Write-Host "  | verifying checksum"
    $expected = $null
    foreach ($line in Get-Content $sumsPath) {
        # SHA256SUMS lines look like: "<hex>  <name>" or "<hex>  *<name>"
        # (the leading '*' marks binary mode in GNU coreutils output).
        $parts = $line -split '\s+', 2
        if ($parts.Length -eq 2) {
            $name = $parts[1].TrimStart('*').Trim()
            if ($name -eq $archiveName) {
                $expected = $parts[0].ToLower()
                break
            }
        }
    }
    if (-not $expected) {
        throw "Checksum for $archiveName not found in $sumsName."
    }

    $actual = (Get-FileHash -Algorithm SHA256 -Path $archivePath).Hash.ToLower()
    if ($actual -ne $expected) {
        throw "Checksum mismatch! expected=$expected actual=$actual"
    }

    Expand-Archive -Path $archivePath -DestinationPath $tmp -Force
    $stage = Join-Path $tmp "club-cli-$resolvedVersion-$target"
    $exeSrc = Join-Path $stage 'bin\club.exe'
    if (-not (Test-Path $exeSrc)) {
        throw "Archive layout unexpected - no executable at $exeSrc."
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

    # Mirror install.sh: if the bundle ships a non-empty lib/ directory
    # (future native deps), keep it next to the binary so the dynamic
    # loader can find it. dart build cli emits these alongside bin/.
    $libSrc = Join-Path $stage 'lib'
    $libFiles = @()
    if (Test-Path $libSrc) {
        $libFiles = @(Get-ChildItem -Path $libSrc -ErrorAction SilentlyContinue)
    }

    if ($libFiles.Count -gt 0) {
        # Windows DLL resolution requires the lib/ files to sit next to
        # the .exe being executed. Copying just the .exe to $InstallDir
        # would fail to load. Keep the bundle intact in a share dir and
        # drop a tiny .cmd shim on PATH that forwards to it.
        #
        # The share dir lives as a sibling of $InstallDir so a custom
        # --install-dir (e.g. a CI temp path) keeps the bundle within
        # the same parent — important for hermetic CI environments
        # where $env:LOCALAPPDATA persists across jobs.
        $shareDir = Join-Path (Split-Path -Parent $InstallDir) 'club-bundle'
        if (Test-Path $shareDir) { Remove-Item $shareDir -Recurse -Force }
        New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
        Copy-Item -Path (Join-Path $stage 'bin') -Destination (Join-Path $shareDir 'bin') -Recurse
        Copy-Item -Path $libSrc                  -Destination (Join-Path $shareDir 'lib') -Recurse

        $bundleExe = Join-Path $shareDir 'bin\club.exe'
        $wrapper = Join-Path $InstallDir 'club.cmd'
        # ASCII encoding avoids a UTF-8 BOM that cmd.exe chokes on.
        Set-Content -Path $wrapper -Encoding ASCII -Value @(
            '@echo off',
            "`"$bundleExe`" %*"
        )
        Write-Host "Installed bundle to: $shareDir"
        Write-Host "Wrapper at:          $wrapper"
    } else {
        Copy-Item -Path $exeSrc -Destination (Join-Path $InstallDir 'club.exe') -Force
        # A previous install may have used the bundle layout (exe + DLLs
        # in a sibling share dir with a .cmd shim on PATH). Running the
        # new standalone .exe works, but leaving the old bundle around
        # (and the stale .cmd shim earlier on PATH) will keep routing
        # users to the old binary. Clean both up.
        $staleBundle = Join-Path (Split-Path -Parent $InstallDir) 'club-bundle'
        if (Test-Path $staleBundle) {
            Remove-Item -Path $staleBundle -Recurse -Force -ErrorAction SilentlyContinue
        }
        $staleCmd = Join-Path $InstallDir 'club.cmd'
        if (Test-Path $staleCmd) {
            Remove-Item -Path $staleCmd -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Installed to: $(Join-Path $InstallDir 'club.exe')"
    }

    # PATH hint. We only check the current process's PATH; persistent
    # User-scope PATH would require Get-ItemProperty under HKCU which
    # adds noise for not much value here.
    $onPath = ($env:Path -split ';') -contains $InstallDir
    Write-Host ''
    if ($onPath) {
        Write-Host "OK  $InstallDir is on your PATH."
        # If another club binary earlier on PATH is shadowing the one we
        # just installed, flag it — otherwise the user "upgrades" but
        # `club --version` keeps reporting the old binary.
        $resolved = Get-Command club -ErrorAction SilentlyContinue
        $expected = @(
            (Join-Path $InstallDir 'club.exe'),
            (Join-Path $InstallDir 'club.cmd')
        )
        if ($resolved -and -not ($expected -contains $resolved.Source)) {
            Write-Host ''
            Write-Host "Warning: another 'club' binary is shadowing the one we just installed:"
            Write-Host "         on PATH:   $($resolved.Source)"
            Write-Host "         installed: $(Join-Path $InstallDir 'club.exe')"
            Write-Host "         Remove it or put $InstallDir earlier in your PATH so the"
            Write-Host "         upgraded binary takes effect."
        } else {
            Write-Host "    Try: club --version"
        }
    } else {
        Write-Host "Note: $InstallDir is NOT on your PATH yet."
        Write-Host "      Add it for your user with:"
        Write-Host "        [Environment]::SetEnvironmentVariable('Path', `"$InstallDir;`$([Environment]::GetEnvironmentVariable('Path','User'))`", 'User')"
        Write-Host "      Then open a new terminal."
    }
} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
