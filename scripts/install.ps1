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

# Sanity: the TUI is executed directly, so it must be a non-empty file.
if ((Get-Item -LiteralPath $tuiPath).Length -eq 0) {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
  Write-Fail "Downloaded $TuiAsset is empty - aborting." 2
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

# Verify the standalone TUI binary too (fetched separately from the zip, so it
# needs its own checksum - supply-chain hardening, M2).
$tuiSidecar = Join-Path $Tmp "$TuiAsset.sha256"
$haveTuiSidecar = $true
try {
  Invoke-WebRequest -Uri "$BaseUrl/$TuiAsset.sha256" -OutFile $tuiSidecar -UseBasicParsing
} catch {
  $haveTuiSidecar = $false
}
if ($haveTuiSidecar) {
  $tuiExpected = ((Get-Content -Raw -LiteralPath $tuiSidecar).Trim() -split '\s+')[0]
  $tuiActual   = (Get-FileHash -Algorithm SHA256 -LiteralPath $tuiPath).Hash
  if ($tuiActual -ine $tuiExpected) {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
    Write-Fail 'Checksum mismatch for the TUI binary - download may be corrupted. Aborting.' 3
  }
  Write-Ok 'Checksum verified (TUI)'
} else {
  Write-Warn 'No .sha256 sidecar for the TUI binary - skipping verification.'
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
if (-not (Test-Path $TuiBin) -or (Get-Item -LiteralPath $TuiBin).Length -eq 0) {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
  Write-Fail "TUI binary missing or empty after install ($TuiBin)." 3
}
# The TUI is launched directly, so prove it actually runs here rather than
# discovering it at first launch.
$tuiReported = ''
try { $tuiReported = ((& $TuiBin --version 2>$null) | Select-Object -First 1) } catch { $tuiReported = '' }
if (-not $tuiReported) {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
  Write-Fail "$TuiBin did not run (--version produced no output)." 3
}
Write-Ok "TUI installed to $TuiBin ($tuiReported)"

# Record install layout so tooling can locate the release, and stamp the
# installed version so `osa update` can compare against the latest release.
Set-Content -LiteralPath (Join-Path $OsaHome 'release_root') -Value $ReleaseDir -Encoding ASCII
Set-Content -LiteralPath (Join-Path $OsaHome 'version') -Value $Version -Encoding ASCII

# Clean up scratch dir now that everything is copied in.
Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Write the launcher pair: osa.cmd (thin shim) + osa.ps1 (real launcher).
#
# osa.cmd lets `osa` work from cmd.exe and any PATH lookup; it hands off to
# osa.ps1, which mirrors the POSIX launcher: loads ~/.osa/.env, warms the
# ERTS-bundled backend as a BACKGROUND DAEMON that survives TUI exit, waits for
# /health, launches the Rust TUI, and owns overdrive + a real in-place update.
# ---------------------------------------------------------------------------
Write-Info "Writing launcher to $BinDir\osa.cmd + osa.ps1..."

$osaCmd = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0osa.ps1" %*
'@
Set-Content -LiteralPath (Join-Path $BinDir 'osa.cmd') -Value $osaCmd -Encoding ASCII

$osaPs1 = @'
#Requires -Version 5.1
# osa.ps1 — the one command to run OSA (prebuilt install under %USERPROFILE%\.osa).
#
#   osa                 Attach the TUI (warms the backend daemon if needed)
#   osa overdrive       Launch in overdrive (full auto) — no approval prompts
#   osa continue        Resume the newest session in this directory
#   osa resume [id]     Resume a specific session (or pick one)
#   osa stop            Stop the background backend daemon
#   osa setup           Configure provider / API keys
#   osa update          Update in place, show what's new, then launch
#   osa doctor          Run backend health checks
#   osa serve           Run the backend in the foreground (headless API)
#   osa version         Print version
#   osa opencomputers   Manage the MIOSA host connection
#   osa help            Show this help
$ErrorActionPreference = 'Stop'
try {
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$Repo = 'Miosa-osa/OSA'

# Resolve install root from this script's location (bin dir's parent),
# honoring an explicit OSA_HOME override.
if ($env:OSA_HOME) { $OsaHome = $env:OSA_HOME } else { $OsaHome = Split-Path -Parent $PSScriptRoot }
$env:OSA_HOME = $OsaHome

$ReleaseBat  = Join-Path $OsaHome 'release\bin\osagent.bat'
$TuiBin      = Join-Path $OsaHome 'bin\osagent-tui.exe'
$LogDir      = Join-Path $OsaHome 'logs'
$RunDir      = Join-Path $OsaHome 'run'
$PidFile     = Join-Path $RunDir 'backend.pid'
$EnvFile     = Join-Path $OsaHome '.env'
$VersionFile = Join-Path $OsaHome 'version'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

# Load user config (provider/model/keys) before booting the backend, mirroring
# the POSIX launcher which sources ~/.osa/.env. A .env is shell KEY=VALUE format,
# not PowerShell, so parse it line-by-line. A malformed line is skipped.
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
  Write-Host "Reinstall: irm https://raw.githubusercontent.com/$Repo/main/scripts/install.ps1 | iex" -ForegroundColor Red
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

function Get-DaemonProcess {
  # Return the live daemon Process, or $null (pidfile first).
  if (Test-Path $PidFile) {
    $p = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($p) {
      $proc = Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue
      if ($proc) { return $proc }
    }
  }
  return $null
}

function Stop-Daemon {
  $proc = Get-DaemonProcess
  if (-not $proc) {
    Write-Host "  No OSA backend is running on :$Port." -ForegroundColor DarkGray
    Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
    return
  }
  Write-Host "  -> Stopping OSA backend (pid $($proc.Id))..." -ForegroundColor Cyan
  # /T kills the whole tree (the .bat wrapper spawns erl as a child); fall back
  # to Stop-Process if taskkill is unavailable.
  try { & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null } catch { }
  Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
  Write-Host "  [ok] Backend stopped." -ForegroundColor Green
}

function Start-Daemon {
  # Detached background daemon that SURVIVES this launcher and the TUI.
  $backendLog = Join-Path $LogDir 'backend.log'
  Write-Host "  -> Starting OSA backend on :$Port (background daemon)" -ForegroundColor Cyan
  $proc = Start-Process -FilePath $ReleaseBat -ArgumentList 'serve' `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput $backendLog
  Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding ASCII
  return $proc
}

function Wait-Health {
  param($Proc, [int]$Max = 40)
  $frames = '|','/','-','\'
  for ($i = 0; $i -lt ($Max * 2); $i++) {
    if (Test-Health $HealthUrl) { Write-Host "`r  " -NoNewline; return 0 }
    if ($Proc -and $Proc.HasExited) { return 2 }
    Write-Host ("`r  {0} warming OSA backend..." -f $frames[$i % 4]) -NoNewline -ForegroundColor Cyan
    Start-Sleep -Milliseconds 500
  }
  Write-Host "`r  " -NoNewline
  return 1
}

function Warn-Overdrive {
  Write-Host "  [!] OVERDRIVE (full auto) - OSA will act without asking for approval." -ForegroundColor Red
  Write-Host "      Only use this in a directory you trust. Confirm inside the TUI to proceed." -ForegroundColor DarkGray
}

function Show-Help {
  Write-Host ""
  Write-Host "    ___  ____    _   "  -ForegroundColor Cyan
  Write-Host "   / _ \/ ___|  / \     OSA - the Optimal System Agent" -ForegroundColor Cyan
  Write-Host "  | | | \___ \ / _ \    Your OS, supercharged." -ForegroundColor Cyan
  Write-Host "  | |_| |___) / ___ \"  -ForegroundColor Cyan
  Write-Host "   \___/|____/_/   \_\" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  Usage: osa [command] [flags]"
  Write-Host ""
  Write-Host "  Commands"
  Write-Host "    osa                  Attach the TUI (warms the backend daemon if needed)"
  Write-Host "    osa overdrive        Launch in overdrive (full auto) - skips approval prompts"
  Write-Host "    osa continue         Resume the newest session in this folder"
  Write-Host "    osa resume [id]      Resume a specific session (or pick one)"
  Write-Host "    osa stop             Stop the background backend daemon"
  Write-Host "    osa setup            Configure provider / API keys"
  Write-Host "    osa update           Update in place, show what's new, then launch"
  Write-Host "    osa doctor           Run backend health checks"
  Write-Host "    osa serve            Run the backend in the foreground (headless API)"
  Write-Host "    osa version          Print version"
  Write-Host "    osa opencomputers    Manage the MIOSA host connection"
  Write-Host "    osa help             Show this help"
  Write-Host ""
  Write-Host "  Flags (forwarded to the TUI)"
  Write-Host "    --overdrive                  Full-auto mode (same as osa overdrive)"
  Write-Host "    --continue                   Resume newest session here"
  Write-Host "    --resume [id]                Resume a session"
  Write-Host "    --permission-mode <mode>     ask . auto-edit . plan . overdrive"
  Write-Host ""
  Write-Host "  The backend keeps running in the background so the next osa is instant." -ForegroundColor DarkGray
  Write-Host "  Stop it any time with osa stop; it also idles down when unused." -ForegroundColor DarkGray
  Write-Host ""
}

# Normalize a version for comparison: drop a leading "v", drop any
# pre-release/build suffix, and strip the display zero-padding from the patch
# component, so the release tag (v1.0.045), the backend (1.0.45) and the TUI's
# padded --version output (1.0.045) all compare equal.
function ConvertTo-NormalizedVersion([string]$v) {
  if (-not $v) { return '' }
  $s = $v.Trim()
  if ($s.StartsWith('v')) { $s = $s.Substring(1) }
  $s = ($s -split '[-+]')[0]
  $p = $s -split '\.'
  if ($p.Count -eq 3 -and ($p | ForEach-Object { $_ -match '^\d+$' }) -notcontains $false) {
    return ('{0}.{1}.{2}' -f [int]$p[0], [int]$p[1], [int]$p[2])
  }
  return $s
}

# The version actually baked into the INSTALLED TUI binary. This is the
# diagnostic that separates "backend updated but the TUI didn't" from a mere
# display bug - the stamp in ~\.osa\version only records what we *intended*.
function Get-InstalledTuiVersion {
  if (-not (Test-Path $TuiBin)) { return '' }
  try {
    $line = (& $TuiBin --version 2>$null) | Select-Object -First 1
    if (-not $line) { return '' }
    return ($line -split '\s+')[-1]
  } catch { return '' }
}

function Test-TuiIsVersion([string]$want) {
  $got = ConvertTo-NormalizedVersion (Get-InstalledTuiVersion)
  if (-not $got) { return $false }
  return ($got -eq (ConvertTo-NormalizedVersion $want))
}

function Update-Osa {
  # Real in-place update: download the prebuilt release + TUI, verify sha256,
  # atomically swap under ~/.osa, print the delta + what's new, then return.
  #
  # Every mutating step below is checked explicitly: an unchecked failure here
  # is how a half-applied update (new backend, old TUI) got reported as success.
  $platform = 'windows-x64'
  $zip = "osa-$platform.zip"
  $tuiAsset = "osagent-tui-$platform.exe"

  $cur = if (Test-Path $VersionFile) { (Get-Content -Raw -LiteralPath $VersionFile).Trim() } else { 'unknown' }
  Write-Host "  -> Current version: $cur" -ForegroundColor Cyan
  Write-Host "  -> Checking for updates..." -ForegroundColor Cyan

  try {
    $meta = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
      -UseBasicParsing -Headers @{ 'User-Agent' = 'osa-updater' }
  } catch {
    Write-Host "  [x] Could not reach the GitHub API. Try again later." -ForegroundColor Red
    return 2
  }
  $latest = $meta.tag_name
  $notes  = $meta.body
  if (-not $latest) { Write-Host "  [x] Could not determine the latest release." -ForegroundColor Red; return 2 }
  if ($latest -eq $cur) {
    # The stamp only records what we INTENDED to install. If a previous update
    # half-applied (backend swapped, TUI not), the stamp says we are current
    # while the TUI still runs old code - and every later `osa update` would
    # no-op forever. Verify against the real binary and self-heal instead.
    if (Test-TuiIsVersion $latest) {
      Write-Host "  [ok] Already up to date ($cur)" -ForegroundColor Green
      return 0
    }
    $tuiNow = Get-InstalledTuiVersion
    if (-not $tuiNow) { $tuiNow = '<unreadable>' }
    Write-Host "  [!] Version stamp says $cur but the TUI binary reports $tuiNow - repairing." -ForegroundColor Yellow
  } else {
    Write-Host "  -> New version available: $latest" -ForegroundColor Cyan
  }

  $base = "https://github.com/$Repo/releases/download/$latest"
  $tmp = Join-Path $env:TEMP ("osa-update-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zipPath = Join-Path $tmp $zip
  $tuiPath = Join-Path $tmp $tuiAsset

  try {
    Write-Host "  -> Downloading $zip..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri "$base/$zip" -OutFile $zipPath -UseBasicParsing
    Write-Host "  -> Downloading $tuiAsset..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri "$base/$tuiAsset" -OutFile $tuiPath -UseBasicParsing
  } catch {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Write-Host "  [x] Download failed. Your existing install is untouched." -ForegroundColor Red
    return 2
  }

  Write-Host "  -> Verifying checksum..." -ForegroundColor Cyan
  $sidecar = Join-Path $tmp "$zip.sha256"
  $haveSidecar = $true
  try { Invoke-WebRequest -Uri "$base/$zip.sha256" -OutFile $sidecar -UseBasicParsing } catch { $haveSidecar = $false }
  if ($haveSidecar) {
    $expected = ((Get-Content -Raw -LiteralPath $sidecar).Trim() -split '\s+')[0]
    $actual   = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash
    if ($actual -ine $expected) {
      Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
      Write-Host "  [x] Checksum mismatch - aborting update." -ForegroundColor Red
      return 3
    }
    Write-Host "  [ok] Checksum verified" -ForegroundColor Green
  } else {
    Write-Host "  [!] No .sha256 sidecar - skipping verification." -ForegroundColor Yellow
  }

  # Verify the TUI binary checksum too (fetched separately - supply-chain, M2).
  $tuiSidecar = Join-Path $tmp "$tuiAsset.sha256"
  $haveTuiSidecar = $true
  try { Invoke-WebRequest -Uri "$base/$tuiAsset.sha256" -OutFile $tuiSidecar -UseBasicParsing } catch { $haveTuiSidecar = $false }
  if ($haveTuiSidecar) {
    $tuiExpected = ((Get-Content -Raw -LiteralPath $tuiSidecar).Trim() -split '\s+')[0]
    $tuiActual   = (Get-FileHash -Algorithm SHA256 -LiteralPath $tuiPath).Hash
    if ($tuiActual -ine $tuiExpected) {
      Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
      Write-Host "  [x] Checksum mismatch for $tuiAsset - aborting update." -ForegroundColor Red
      return 3
    }
    Write-Host "  [ok] Checksum verified ($tuiAsset)" -ForegroundColor Green
  } else {
    Write-Host "  [!] No .sha256 sidecar for $tuiAsset - skipping verification." -ForegroundColor Yellow
  }

  Write-Host "  -> Installing update..." -ForegroundColor Cyan
  Stop-Daemon | Out-Null

  $newRel = Join-Path $OsaHome 'release.new'
  if (Test-Path $newRel) { Remove-Item -Recurse -Force $newRel }
  New-Item -ItemType Directory -Force -Path $newRel | Out-Null
  try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $newRel -Force
  } catch {
    Remove-Item -Recurse -Force $tmp, $newRel -ErrorAction SilentlyContinue
    Write-Host "  [x] Extraction failed - your existing install is untouched." -ForegroundColor Red
    return 3
  }
  if (-not (Test-Path (Join-Path $newRel 'bin\osagent.bat'))) {
    Remove-Item -Recurse -Force $tmp, $newRel -ErrorAction SilentlyContinue
    Write-Host "  [x] Bad release archive - aborting." -ForegroundColor Red
    return 3
  }

  # Stage the new TUI binary BEFORE touching the live release dir, so a failure
  # to write it aborts while the install is still fully consistent. (On Windows
  # this is the step most likely to fail - the .exe can be locked by a running
  # or antivirus-scanned process.)
  try {
    Copy-Item -LiteralPath $tuiPath -Destination "$TuiBin.new" -Force
  } catch {
    Remove-Item -Force "$TuiBin.new" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp, $newRel -ErrorAction SilentlyContinue
    Write-Host "  [x] Could not stage the new TUI binary at $TuiBin.new - aborting update." -ForegroundColor Red
    Write-Host "      Your existing install is untouched. Check disk space and permissions." -ForegroundColor DarkGray
    return 3
  }

  $relDir = Join-Path $OsaHome 'release'
  $relOld = Join-Path $OsaHome 'release.old'
  if (Test-Path $relOld) { Remove-Item -Recurse -Force $relOld }
  if (Test-Path $relDir) { Move-Item -LiteralPath $relDir -Destination $relOld }
  try {
    Move-Item -LiteralPath $newRel -Destination $relDir
  } catch {
    # Put the old release back so the install is not left headless.
    if ((Test-Path $relOld) -and -not (Test-Path $relDir)) {
      Move-Item -LiteralPath $relOld -Destination $relDir -ErrorAction SilentlyContinue
    }
    Remove-Item -Force "$TuiBin.new" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp, $newRel -ErrorAction SilentlyContinue
    Write-Host "  [x] Could not install the new backend release - aborting update." -ForegroundColor Red
    return 3
  }
  if (Test-Path $relOld) { Remove-Item -Recurse -Force $relOld -ErrorAction SilentlyContinue }

  # Swap the TUI binary. This step previously ran unchecked: when it failed the
  # launcher kept starting the OLD TUI while the version stamp was rewritten to
  # the new tag, so `osa update` printed success and the TUI kept showing the
  # old version forever.
  try {
    Move-Item -LiteralPath "$TuiBin.new" -Destination $TuiBin -Force
  } catch {
    Remove-Item -Force "$TuiBin.new" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Write-Host "  [x] Could not replace the TUI binary at $TuiBin." -ForegroundColor Red
    Write-Host "      The backend was updated but the TUI was NOT - the install is INCONSISTENT." -ForegroundColor DarkGray
    Write-Host "      Repair with: irm https://raw.githubusercontent.com/$Repo/main/scripts/install.ps1 | iex" -ForegroundColor Cyan
    return 3
  }

  # Post-swap verification. Only stamp the new version once BOTH halves are on
  # disk and the TUI really reports the version we just installed - a stamp
  # written over a half-applied update makes every later `osa update` a no-op.
  if (-not (Test-Path $ReleaseBat)) {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Write-Host "  [x] Backend boot script missing after update ($ReleaseBat)." -ForegroundColor Red
    return 3
  }
  if (-not (Test-Path $TuiBin) -or (Get-Item -LiteralPath $TuiBin).Length -eq 0) {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Write-Host "  [x] TUI binary missing or empty after update ($TuiBin)." -ForegroundColor Red
    Write-Host "      Repair with: irm https://raw.githubusercontent.com/$Repo/main/scripts/install.ps1 | iex" -ForegroundColor Cyan
    return 3
  }
  if (-not (Test-TuiIsVersion $latest)) {
    $tuiNow = Get-InstalledTuiVersion
    if (-not $tuiNow) { $tuiNow = '<unreadable>' }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Write-Host "  [x] TUI still reports $tuiNow after updating to $latest - the update did not take." -ForegroundColor Red
    Write-Host "      Not stamping the new version, so 'osa update' will retry." -ForegroundColor DarkGray
    Write-Host "      Repair with: irm https://raw.githubusercontent.com/$Repo/main/scripts/install.ps1 | iex" -ForegroundColor Cyan
    return 3
  }
  Write-Host "  [ok] TUI binary verified (reports $(Get-InstalledTuiVersion))" -ForegroundColor Green

  Set-Content -LiteralPath (Join-Path $OsaHome 'release_root') -Value $relDir -Encoding ASCII
  Set-Content -LiteralPath $VersionFile -Value $latest -Encoding ASCII
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

  Write-Host ""
  Write-Host "  [ok] Updated $cur -> $latest" -ForegroundColor Green
  Write-Host ""
  Write-Host "  What's new"
  if ($notes) {
    ($notes -split "`n" | Select-Object -First 30) | ForEach-Object { Write-Host ("    " + $_.TrimEnd()) }
  } else {
    Write-Host "    See https://github.com/$Repo/releases/tag/$latest" -ForegroundColor Cyan
  }
  Write-Host ""
  if ([Environment]::UserInteractive) {
    Read-Host "  Press Enter to launch OSA" | Out-Null
  }
  return 0
}

# ── Subcommand pre-translation (verbs -> TUI flags, then fall through) ──
function Drop-First($arr) { if ($arr.Count -le 1) { @() } else { @($arr[1..($arr.Count - 1)]) } }

$argList = @($args)
$overdrive = $false
if ($argList.Count -ge 1) {
  switch ($argList[0]) {
    'overdrive' { $overdrive = $true; $argList = @(Drop-First $argList) + '--overdrive' }
    'continue'  { $argList = @(Drop-First $argList) + '--continue' }
    'resume' {
      $r = Drop-First $argList
      if ($r.Count -ge 1 -and -not ([string]$r[0]).StartsWith('-')) {
        $rid = $r[0]; $r = Drop-First $r
        $argList = @($r) + '--resume' + $rid
      } else {
        $argList = @($r) + '--resume'
      }
    }
  }
}
foreach ($a in $argList) {
  if ($a -in @('--overdrive', '--dangerously-skip-permissions', '--yolo')) { $overdrive = $true }
}

# ── Subcommand dispatch ───────────────────────────────────────────
$cmd  = if ($argList.Count -ge 1) { [string]$argList[0] } else { '' }
$rest = Drop-First $argList

switch -Exact ($cmd) {
  { $_ -in @('version', '--version', '-v') } {
    # Report BOTH halves. `osa update` swaps a backend release and a separate
    # TUI binary; printing only the backend hides a half-applied update, which
    # is precisely how "I updated but the TUI shows the old version" happens.
    & $ReleaseBat version
    $tuiV = Get-InstalledTuiVersion
    if ($tuiV) { Write-Host "osagent-tui $tuiV" }
    else { Write-Host "osagent-tui <not installed at $TuiBin>" -ForegroundColor Red }
    $stamp = if (Test-Path $VersionFile) { (Get-Content -Raw -LiteralPath $VersionFile).Trim() } else { 'unknown' }
    Write-Host "installed release stamp $stamp"
    if ($stamp -ne 'unknown' -and -not (Test-TuiIsVersion $stamp)) {
      Write-Host "  [!] TUI does not match the installed release stamp - run 'osa update' to repair." -ForegroundColor Yellow
    }
    exit 0
  }
  'setup'  { & $ReleaseBat setup;  exit $LASTEXITCODE }
  'serve'  { & $ReleaseBat serve;  exit $LASTEXITCODE }
  'doctor' { & $ReleaseBat doctor; exit $LASTEXITCODE }
  'opencomputers' { & $ReleaseBat opencomputers @rest; exit $LASTEXITCODE }
  'stop'   { Stop-Daemon; exit 0 }
  'update' {
    $urc = Update-Osa
    if ($urc -ne 0) { exit $urc }
    # fall through to launch on success
  }
  { $_ -in @('help', '--help', '-h') } { Show-Help; exit 0 }
}

# ── Default: warm the daemon (attach instantly if healthy), then TUI ──
if (Test-Health $HealthUrl) {
  Write-Host "  Backend already running on :$Port - attaching." -ForegroundColor DarkGray
} else {
  # Clear a stale pidfile whose process is gone.
  if ((Test-Path $PidFile) -and -not (Get-DaemonProcess)) {
    Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
  }
  $backend = Start-Daemon
  $rc = Wait-Health $backend 40
  if ($rc -eq 2) {
    Write-Host "  [x] Backend exited during startup - port $Port may already be in use." -ForegroundColor Red
    Write-Host "      Start on another port:  `$env:OSA_PORT=<n>; osa   (or run: osa stop)" -ForegroundColor DarkGray
    Write-Host "      Inspect the log: $(Join-Path $LogDir 'backend.log')" -ForegroundColor DarkGray
    Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
    exit 1
  } elseif ($rc -eq 1) {
    Write-Host "  [x] Backend did not become healthy on :$Port in time." -ForegroundColor Red
    Write-Host "      Inspect the log: $(Join-Path $LogDir 'backend.log')   .   Run: osa doctor" -ForegroundColor DarkGray
    exit 1
  }
  Write-Host "  Backend ready. It stays warm in the background - run osa stop to shut it down." -ForegroundColor DarkGray
}

# Show the overdrive warning right before handing off to the TUI.
if ($overdrive) { Warn-Overdrive }

# Launch the TUI. The backend daemon deliberately OUTLIVES this process, so the
# next `osa` attaches instantly. No cleanup - that is the whole point.
$env:OSA_URL = "http://localhost:$Port"
& $TuiBin @argList
exit $LASTEXITCODE
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
Write-Host "  Update later: run 'osa update' (in-place). Or reinstall: $InstallOneLiner" -ForegroundColor DarkGray
Write-Host ''
