<#
  scripts/install.ps1 — OSA one-command installer for Windows (zero toolchains).

  Windows analogue of scripts/install.sh. Downloads prebuilt release artifacts
  from GitHub Releases and wires up the `osa` command. The user needs NO Elixir,
  Erlang, or Rust: the Windows release zip bundles its own ERTS (built on CI via
  `MIX_ENV=prod mix release osagent`) and the Rust TUI ships as a prebuilt .exe.

  (Prefer to build from source? See scripts/install-source.ps1, which installs
  the full toolchain via winget and compiles locally.)

  Usage (PowerShell 5.1+ or pwsh):
    irm https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.ps1 | iex

  Environment overrides:
    OSA_VERSION   Pin to a release tag (e.g. "v0.4.0"). Default: latest.
    OSA_HOME      Install root. Default: %USERPROFILE%\.osa

  No external PowerShell modules required — only built-in cmdlets are used.
#>

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 defaults to an old TLS; GitHub requires TLS 1.2+.
try {
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$Repo = 'Miosa-osa/OSA'
if ($env:OSA_HOME) { $OsaHome = $env:OSA_HOME } else { $OsaHome = Join-Path $env:USERPROFILE '.osa' }
$ReleaseDir = Join-Path $OsaHome 'release'
$BinDir     = Join-Path $OsaHome 'bin'
$InstallOneLiner = 'irm https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.ps1 | iex'

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
function Write-Info { param([string]$m) Write-Host "  -> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  [ok] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [!] $m" -ForegroundColor Yellow }
function Write-Fail {
  param([string]$m, [int]$code = 1)
  Write-Host "  [x] $m" -ForegroundColor Red
  exit $code
}

# ---------------------------------------------------------------------------
# Banner — cyan/blue ASCII logo (OSA blue identity, never orange).
# ---------------------------------------------------------------------------
Write-Host ''
$logo = @(
  '    ___  ____    _    ',
  '   / _ \/ ___|  / \   ',
  '  | | | \___ \ / _ \  ',
  '  | |_| |___) / ___ \ ',
  '   \___/|____/_/   \_\'
)
foreach ($line in $logo) { Write-Host $line -ForegroundColor Cyan }
Write-Host '  the Optimal System Agent'
Write-Host '  One-command installer - no Elixir / Erlang / Rust required' -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
# Detect architecture — only windows-x64 assets are published.
# ---------------------------------------------------------------------------
$procArch = $env:PROCESSOR_ARCHITECTURE
if (-not [Environment]::Is64BitOperatingSystem -or $procArch -ne 'AMD64') {
  if ($procArch -eq 'ARM64') {
    Write-Warn "No prebuilt binaries are published for Windows arm64 ($procArch) yet."
    Write-Warn 'Build from source instead (requires Elixir + Rust):'
    Write-Warn '  https://github.com/Miosa-osa/OSA#installation'
    Write-Fail 'Unsupported architecture: windows-arm64.' 1
  }
  Write-Fail "Unsupported architecture: $procArch. OSA on Windows requires 64-bit x64 (AMD64)." 1
}
$Platform = 'windows-x64'
Write-Info "Detected platform: $Platform"

$Zip      = "osa-$Platform.zip"
$TuiAsset = "osagent-tui-$Platform.exe"

# ---------------------------------------------------------------------------
# Resolve version (latest or pinned)
# ---------------------------------------------------------------------------
if ($env:OSA_VERSION) {
  $Version = $env:OSA_VERSION
  Write-Info "Using pinned version: $Version"
} else {
  Write-Info 'Resolving latest release...'
  try {
    $meta = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
      -UseBasicParsing -Headers @{ 'User-Agent' = 'osa-installer' }
    $Version = $meta.tag_name
  } catch {
    Write-Fail 'Network error: could not reach the GitHub API. Pin with $env:OSA_VERSION=''v0.4.0''.' 2
  }
  if (-not $Version) { Write-Fail 'Could not determine latest release. Pin with $env:OSA_VERSION=''v0.4.0''.' 2 }
  Write-Ok "Latest release: $Version"
}

$BaseUrl     = "https://github.com/$Repo/releases/download/$Version"
$ReleasesUrl = "https://github.com/$Repo/releases"

# ---------------------------------------------------------------------------
# Download artifacts to a scratch dir
# ---------------------------------------------------------------------------
$Tmp = Join-Path $env:TEMP ("osa-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

$zipPath = Join-Path $Tmp $Zip
$tuiPath = Join-Path $Tmp $TuiAsset

try {
  Write-Info "Downloading $Zip..."
  Invoke-WebRequest -Uri "$BaseUrl/$Zip" -OutFile $zipPath -UseBasicParsing
  Write-Ok "Downloaded $Zip"
} catch {
  Write-Warn "URL: $BaseUrl/$Zip"
  Write-Warn "See releases: $ReleasesUrl"
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
  Write-Fail "Download failed for $Zip." 2
}

try {
  Write-Info "Downloading $TuiAsset..."
  Invoke-WebRequest -Uri "$BaseUrl/$TuiAsset" -OutFile $tuiPath -UseBasicParsing
  Write-Ok "Downloaded $TuiAsset"
} catch {
  Write-Warn "URL: $BaseUrl/$TuiAsset"
  Write-Warn "See releases: $ReleasesUrl"
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
  Write-Fail "Download failed for $TuiAsset." 2
}

# ---------------------------------------------------------------------------
# Verify checksum (mandatory when the sidecar exists; warn-and-skip if it 404s,
# mirroring scripts/install.sh).
# ---------------------------------------------------------------------------
Write-Info 'Verifying checksum...'
$sidecarPath = Join-Path $Tmp "$Zip.sha256"
$haveSidecar = $true
try {
  Invoke-WebRequest -Uri "$BaseUrl/$Zip.sha256" -OutFile $sidecarPath -UseBasicParsing
} catch {
  $haveSidecar = $false
}
if ($haveSidecar) {
  $expected = ((Get-Content -Raw -LiteralPath $sidecarPath).Trim() -split '\s+')[0]
  $actual   = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash
  if ($actual -ine $expected) {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
    Write-Fail 'Checksum mismatch - download may be corrupted. Aborting.' 3
  }
  Write-Ok 'Checksum verified'
} else {
  Write-Warn 'No .sha256 sidecar for this release - skipping verification.'
}

# ---------------------------------------------------------------------------
# Extract OTP release into ~/.osa/release (fresh)
# ---------------------------------------------------------------------------
Write-Info "Installing OTP release to $ReleaseDir..."
if (Test-Path $ReleaseDir) { Remove-Item -Recurse -Force $ReleaseDir }
New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null
try {
  Expand-Archive -LiteralPath $zipPath -DestinationPath $ReleaseDir -Force
} catch {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
  Write-Fail 'Extraction failed.' 3
}

# The Windows mix release emits its boot script as bin\osagent.bat.
$ReleaseBat = Join-Path $ReleaseDir 'bin\osagent.bat'
if (-not (Test-Path $ReleaseBat)) {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
  Write-Fail "Release boot script not found at $ReleaseBat." 3
}
Write-Ok 'Release installed'

# ---------------------------------------------------------------------------
# Install the Rust TUI binary
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$TuiBin = Join-Path $BinDir 'osagent-tui.exe'
Copy-Item -LiteralPath $tuiPath -Destination $TuiBin -Force
Write-Ok "TUI installed to $TuiBin"

# Record install layout so tooling can locate the release.
Set-Content -LiteralPath (Join-Path $OsaHome 'release_root') -Value $ReleaseDir -Encoding ASCII

# Clean up scratch dir now that everything is copied in.
Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Write the launcher pair: osa.cmd (thin shim) + osa.ps1 (real launcher).
#
# osa.cmd lets `osa` work from cmd.exe and any PATH lookup; it hands off to
# osa.ps1, which mirrors the POSIX launcher: loads ~/.osa/.env, boots the
# ERTS-bundled backend (headless `serve`), waits for /health, launches the
# Rust TUI, and tears the backend down on exit.
# ---------------------------------------------------------------------------
Write-Info "Writing launcher to $BinDir\osa.cmd + osa.ps1..."

$osaCmd = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0osa.ps1" %*
'@
Set-Content -LiteralPath (Join-Path $BinDir 'osa.cmd') -Value $osaCmd -Encoding ASCII

$osaPs1 = @'
#Requires -Version 5.1
# osa.ps1 — launcher for the prebuilt OSA install (%USERPROFILE%\.osa).
#
#   osa                 Start backend + TUI (default)
#   osa setup           Configure provider / API keys
#   osa serve           Backend only (headless HTTP API)
#   osa doctor          Health checks
#   osa version         Print version
#   osa opencomputers   Manage the MIOSA host connection
#   osa update          How to update
$ErrorActionPreference = 'Stop'

# Resolve install root from this script's location (bin dir's parent),
# honoring an explicit OSA_HOME override.
if ($env:OSA_HOME) { $OsaHome = $env:OSA_HOME } else { $OsaHome = Split-Path -Parent $PSScriptRoot }
$env:OSA_HOME = $OsaHome

$ReleaseBat = Join-Path $OsaHome 'release\bin\osagent.bat'
$TuiBin     = Join-Path $OsaHome 'bin\osagent-tui.exe'
$LogDir     = Join-Path $OsaHome 'logs'
$EnvFile    = Join-Path $OsaHome '.env'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Load user config (provider/model/keys) before booting the backend, mirroring
# the POSIX launcher which sources ~/.osa/.env. A .env is shell KEY=VALUE format,
# not PowerShell, so parse it line-by-line (dot-sourcing it would throw parse
# errors on Windows). A single malformed line is skipped, not fatal.
if (Test-Path $EnvFile) {
  foreach ($line in Get-Content -LiteralPath $EnvFile) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $eq = $t.IndexOf('=')
    if ($eq -lt 1) { continue }
    $key = $t.Substring(0, $eq).Trim()
    $val = $t.Substring($eq + 1).Trim().Trim('"').Trim("'")
    if ($key) { Set-Item -Path ("Env:" + $key) -Value $val -ErrorAction SilentlyContinue }
  }
}

if (-not (Test-Path $ReleaseBat)) {
  Write-Host "OSA is not installed correctly ($ReleaseBat missing)." -ForegroundColor Red
  Write-Host "Reinstall: irm https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.ps1 | iex" -ForegroundColor Red
  exit 1
}

if ($env:OSA_PORT) { $Port = $env:OSA_PORT } else { $Port = 9089 }
$HealthUrl = "http://localhost:$Port/health"

function Test-Health {
  param([string]$Url)
  try {
    Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2 | Out-Null
    return $true
  } catch { return $false }
}

# Subcommands dispatch straight to the release wrapper.
$cmd  = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }

switch -Exact ($cmd) {
  { $_ -in @('version', '--version', '-v') } { & $ReleaseBat version; exit $LASTEXITCODE }
  'setup'  { & $ReleaseBat setup;  exit $LASTEXITCODE }
  'serve'  { & $ReleaseBat serve;  exit $LASTEXITCODE }
  'doctor' { & $ReleaseBat doctor; exit $LASTEXITCODE }
  'opencomputers' { & $ReleaseBat opencomputers @rest; exit $LASTEXITCODE }
  'update' {
    Write-Host "To update OSA, re-run the installer:"
    Write-Host "  irm https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.ps1 | iex"
    exit 0
  }
  { $_ -in @('help', '--help', '-h') } {
    Write-Host ""
    Write-Host "  OSA Agent - Your OS, Supercharged"
    Write-Host ""
    Write-Host "  Usage:"
    Write-Host "    osa                Start backend + TUI (default)"
    Write-Host "    osa setup          Configure provider / API keys"
    Write-Host "    osa serve          Backend only (headless HTTP API)"
    Write-Host "    osa doctor         Run health checks"
    Write-Host "    osa version        Print version"
    Write-Host "    osa opencomputers  Manage the MIOSA host connection"
    Write-Host "    osa update         Update instructions"
    Write-Host ""
    exit 0
  }
}

# Default: start the backend (if not already up), then launch the TUI.
$backend  = $null
$exitCode = 0
try {
  if (-not (Test-Health $HealthUrl)) {
    $backendLog = Join-Path $LogDir 'backend.log'
    $backend = Start-Process -FilePath $ReleaseBat -ArgumentList 'serve' `
      -PassThru -WindowStyle Hidden -RedirectStandardOutput $backendLog
    for ($i = 0; $i -lt 40; $i++) {
      if (Test-Health $HealthUrl) { break }
      # If serve has already exited, waiting the full window is pointless. The
      # usual cause is the port being held by another process (bind failure).
      if ($backend.HasExited) {
        Write-Host "OSA backend exited during startup - port $Port is likely already in use." -ForegroundColor Yellow
        Write-Host "  - Another OSA instance or process may be bound to :$Port." -ForegroundColor Yellow
        Write-Host "  - Start on a different port:  `$env:OSA_PORT=<number>; osa" -ForegroundColor Yellow
        break
      }
      Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Health $HealthUrl)) {
      Write-Host "  - Inspect the log:  $backendLog"
      Write-Host "  - Run diagnostics:  osa doctor"
    }
  }

  & $TuiBin @args
  $exitCode = $LASTEXITCODE
} finally {
  if ($backend -and -not $backend.HasExited) {
    Stop-Process -Id $backend.Id -Force -ErrorAction SilentlyContinue
  }
}
exit $exitCode
'@
Set-Content -LiteralPath (Join-Path $BinDir 'osa.ps1') -Value $osaPs1 -Encoding UTF8
Write-Ok 'Launcher installed'

# ---------------------------------------------------------------------------
# Wire PATH — add $BinDir to the USER Path (persists for new shells) if absent.
# ---------------------------------------------------------------------------
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$onPath = $false
if ($userPath) {
  foreach ($p in ($userPath -split ';')) {
    if ($p.TrimEnd('\') -eq $BinDir.TrimEnd('\')) { $onPath = $true; break }
  }
}
$pathHint = $false
if (-not $onPath) {
  if ([string]::IsNullOrEmpty($userPath)) {
    $newPath = $BinDir
  } else {
    $newPath = ($userPath.TrimEnd(';') + ';' + $BinDir)
  }
  [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
  # Make it usable in THIS session too.
  $env:Path = ($env:Path.TrimEnd(';') + ';' + $BinDir)
  Write-Ok "Added $BinDir to your USER PATH"
  $pathHint = $true
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "  OSA $Version installed." -ForegroundColor Green
Write-Host ''
if ($pathHint) {
  Write-Host '  Open a NEW terminal, then run:  osa'
} else {
  Write-Host '  Run osa to start.'
}
Write-Host ''
Write-Host "  Update later: $InstallOneLiner" -ForegroundColor DarkGray
Write-Host ''
