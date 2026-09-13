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
# This very script. `osa update` has to be able to replace it - see
# Update-Launcher for why, and for why replacing it is only half the job.
$LauncherSelf   = Join-Path $OsaHome 'bin\osa.ps1'
$LauncherRawBase = if ($env:OSA_LAUNCHER_RAW_BASE) { $env:OSA_LAUNCHER_RAW_BASE }
                   else { "https://raw.githubusercontent.com/$Repo" }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

# Load user config (provider/model/keys) before booting the backend, mirroring
# the POSIX launcher which sources ~/.osa/.env. A .env is shell KEY=VALUE format,
# not PowerShell, so parse it line-by-line. A malformed line is skipped.
#
# NON-DESTRUCTIVE (mirrors the POSIX launcher): the file supplies DEFAULTS only.
# A variable already present in the environment WINS, so `$env:OLLAMA_MODEL='x';
# osa` is not silently clobbered by whatever ~/.osa/.env last saved.
if (Test-Path $EnvFile) {
  foreach ($line in Get-Content -LiteralPath $EnvFile) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    if ($t -match '^export\s+') { $t = $t -replace '^export\s+', '' }
    $eq = $t.IndexOf('=')
    if ($eq -lt 1) { continue }
    $key = $t.Substring(0, $eq).Trim()
    $val = $t.Substring($eq + 1).Trim().Trim('"').Trim("'")
    if (-not $key) { continue }
    $existing = [Environment]::GetEnvironmentVariable($key, 'Process')
    if ([string]::IsNullOrEmpty($existing)) {
      Set-Item -Path ("Env:" + $key) -Value $val -ErrorAction SilentlyContinue
    }
  }
}

if (-not (Test-Path $ReleaseBat)) {
  Write-Host "OSA is not installed correctly ($ReleaseBat missing)." -ForegroundColor Red
  Write-Host "Reinstall: irm https://raw.githubusercontent.com/$Repo/main/scripts/install.ps1 | iex" -ForegroundColor Red
  exit 1
}

if ($env:OSA_PORT) { $Port = $env:OSA_PORT } else { $Port = 9089 }
# 127.0.0.1, NOT localhost. The backend binds IPv4 only, but Windows resolves
# "localhost" to ::1 first and the IPv6 attempt STALLS rather than refusing,
# consuming the whole -TimeoutSec 2 budget in Test-Health below before IPv4 is
# ever tried. Test-Health therefore returned $false against a perfectly healthy
# daemon, so every launch tried to start a SECOND backend on the taken port and
# died with "port 9089 may already be in use".
$HealthUrl = "http://127.0.0.1:$Port/health"

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
  # Fall back to whoever actually holds the PORT. The pidfile records the
  # cmd.exe wrapper, but `erl` is its child and outlives it when the wrapper is
  # killed alone - leaving a backend that owns :$Port and that `osa stop` could
  # not see. That is the "No OSA backend is running" / "port may already be in
  # use" deadlock: stop reports nothing to stop, and start cannot bind.
  try {
    $owner = (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
              Select-Object -First 1).OwningProcess
    if ($owner) {
      $proc = Get-Process -Id ([int]$owner) -ErrorAction SilentlyContinue
      if ($proc) { return $proc }
    }
  } catch { }
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
  # The stock release .bat has NO `serve` command (see copy_osagent_wrapper in
  # mix.exs): it printed "ERROR: Unknown command serve" and exited instantly, so
  # the daemon never started and Wait-Health's early-exit branch mis-reported it
  # as a port conflict. Dispatch through `eval`, like the POSIX bin/osagent
  # wrapper - CLI.serve() also runs migrate!() and seed_workspace(), which a
  # bare release `start` skips.
  $proc = Start-Process -FilePath $ReleaseBat -ArgumentList 'eval','OptimalSystemAgent.CLI.serve()' `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput $backendLog
  Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding ASCII
  return $proc
}

# ── Disk vs RAM version skew, and its automatic repair ─────────────────────
#
# Mirrors bin/osa and the POSIX launcher. OSA's backend deliberately outlives
# the TUI, so a daemon started before an update keeps serving the OLD code from
# memory while the new code sits on disk - and the TUI then reports the
# daemon's version, making the update look like it never shipped. OSA absorbs
# that cost itself; telling the user to run `osa stop` first is not acceptable.

function Get-DaemonVersion {
  try {
    $r = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 3
    $m = [regex]::Match($r.Content, '"version"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
  } catch { }
  return ''
}

# $true when the live daemon matches what is INSTALLED (or nothing to compare).
function Test-DaemonMatchesInstall {
  $inst = Get-InstalledTuiVersion
  if (-not $inst) { return $true }
  if (-not (Test-Health $HealthUrl)) { return $true }
  $run = Get-DaemonVersion
  if (-not $run) { return $true }
  return ((ConvertTo-NormalizedVersion $run) -eq (ConvertTo-NormalizedVersion $inst))
}

# Stop the backend, then POLL until :$Port really stops answering. The PORT,
# not the PID, is the contract: anything still listening is what the TUI would
# attach to. Returns $true when the port is free.
function Stop-BackendConfirmed {
  Stop-Daemon | Out-Null
  for ($i = 0; $i -lt 40; $i++) {
    if (-not (Test-Health $HealthUrl)) { return $true }
    Start-Sleep -Milliseconds 250
  }
  return (-not (Test-Health $HealthUrl))
}

# Is anyone relying on this daemon right now? Observed from OUTSIDE, because
# the daemon being judged runs OLD code and would not report any field added
# for this purpose. Returns a reason string, or '' when idle.
function Get-DaemonBusyReason {
  $tuiName = [System.IO.Path]::GetFileNameWithoutExtension($TuiBin)
  if (Get-Process -Name $tuiName -ErrorAction SilentlyContinue) {
    return 'another OSA session is attached to it'
  }
  $backendLog = Join-Path $LogDir 'backend.log'
  if (Test-Path $backendLog) {
    $age = (Get-Date) - (Get-Item $backendLog).LastWriteTime
    if ($age.TotalSeconds -lt 15) { return 'it is still writing output (mid-turn)' }
  }
  return ''
}

# Repair skew before the attach decision. $true = proceed, $false = hard error.
function Repair-StaleDaemon {
  if (Test-DaemonMatchesInstall) { return $true }
  $inst = Get-InstalledTuiVersion
  $run  = Get-DaemonVersion
  $busy = Get-DaemonBusyReason

  if ($busy) {
    if ([Environment]::UserInteractive) {
      Write-Host "  [!] The backend is running an older build ($run -> $inst), but $busy." -ForegroundColor Yellow
      $reply = Read-Host '  Restart it anyway? This ends that work. [y/N]'
      if ($reply -notmatch '^(y|Y|yes|YES)$') {
        Write-Host "  Left it running - attaching to $run." -ForegroundColor DarkGray
        return $true
      }
    } else {
      Write-Host "  [!] A stale OSA backend is running on :$Port." -ForegroundColor Yellow
      Write-Host "      installed: $inst" -ForegroundColor DarkGray
      Write-Host "      running:   $run  <- this is what the TUI will display" -ForegroundColor DarkGray
      Write-Host "      It was left alone because it is busy; it will be refreshed automatically once idle." -ForegroundColor DarkGray
      return $true
    }
  }

  Write-Host '  -> Backend was running an older build - restarting...' -ForegroundColor Cyan
  if (-not (Stop-BackendConfirmed)) {
    Write-Host "  [x] The old backend on :$Port would not stop." -ForegroundColor Red
    Write-Host "      It reports $run but $inst is installed, so attaching would silently" -ForegroundColor DarkGray
    Write-Host '      run the OLD build. OSA will not do that.' -ForegroundColor DarkGray
    return $false
  }
  Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
  return $true
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

# ── The launcher has to update ITSELF ───────────────────────────────────────
#
# Update-Osa downloaded the backend release and the TUI binary but never
# osa.ps1, the launcher itself. So every launcher fix - the stale-daemon
# auto-restart above, the honest "Updated to X" wording, this very function -
# only ever reached a user who re-ran install.ps1 by hand. That is PERMANENT
# staleness. Mirrors the POSIX launcher in scripts/install.sh exactly.
#
# SOURCE OF TRUTH: raw scripts/install.ps1 at the RELEASE TAG being installed,
# never `main`. install.ps1 GENERATES this launcher, so the tag's install.ps1 is
# by construction the launcher that shipped with these binaries; a git tag is an
# immutable ref, so the fetch is version-matched by the URL itself; and it needs
# no new release asset, so it works for every release that already exists.

# Carve osa.ps1 back out of an install.ps1 - the inverse of the here-string it
# was written from. A PowerShell here-string terminator must sit at column 0,
# so `'@` on its own line is unambiguous.
function Get-LauncherFromInstaller([string]$path) {
  $lines = Get-Content -LiteralPath $path -ErrorAction Stop
  $out = New-Object System.Collections.Generic.List[string]
  $inBody = $false
  foreach ($l in $lines) {
    if (-not $inBody) {
      if ($l -match "^\`$osaPs1\s*=\s*@'") { $inBody = $true }
      continue
    }
    if ($l -eq "'@") { break }
    $out.Add($l)
  }
  return $out.ToArray()
}

# Would it be safe to let these lines become the `osa` command? Every check is a
# "no" that must be impossible to get wrong: a truncated download, a captive
# portal's HTML or a GitHub 404 body must never overwrite a working launcher.
function Test-LauncherCandidate([string[]]$lines) {
  if (-not $lines -or $lines.Count -eq 0) {
    Write-Host "  [x] The downloaded launcher is empty." -ForegroundColor Red
    return $false
  }
  if ($lines.Count -lt 200) {
    Write-Host "  [x] The downloaded launcher is only $($lines.Count) lines - truncated." -ForegroundColor Red
    return $false
  }
  # Sentinels: three lines only the OSA launcher has, spread from its head to
  # its very last line, so a body that is merely PowerShell-shaped still fails.
  foreach ($m in @("`$Repo = 'Miosa-osa/OSA'", 'function Update-Osa {', '& $TuiBin @argList')) {
    if (-not ($lines | Where-Object { $_.Contains($m) })) {
      Write-Host "  [x] The downloaded launcher is not the OSA launcher (missing: $m)." -ForegroundColor Red
      return $false
    }
  }
  # The PowerShell equivalent of `bash -n`: parse it without running it.
  $text = ($lines -join "`n")
  $errors = $null
  try {
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
  } catch {
    Write-Host "  [x] The downloaded launcher could not be parsed." -ForegroundColor Red
    return $false
  }
  if ($errors -and $errors.Count -gt 0) {
    Write-Host "  [x] The downloaded launcher is not valid PowerShell ($($errors.Count) parse error(s))." -ForegroundColor Red
    Write-Host "      $($errors[0].Message)" -ForegroundColor DarkGray
    return $false
  }
  return $true
}

# Replace $LauncherSelf with the launcher belonging to release $Tag, then hand
# the rest of the update over to it.
#
# THE SELF-REFERENCE PROBLEM APPLIES HERE TOO: PowerShell parses the whole
# script file before running a line of it, so rewriting osa.ps1 on disk does not
# change the code that is running. On a successful replacement this function
# therefore does NOT return - it relaunches the new osa.ps1 and exits with its
# status, the closest thing PowerShell has to the POSIX launcher's `exec`. The
# `update` verb and the user's remaining argv are replayed; the post-download
# phase state travels in the environment so the child re-downloads nothing.
#
# Returns 0 only to mean "carry on in THIS process": the launcher was already
# identical, or we are the handed-off child. Non-zero is a hard, already
# reported failure - never a silent fallback to the old launcher.
function Update-Launcher {
  param(
    [string]$Tag,
    [string]$OldVer = 'unknown',
    [bool]$UpToDate = $false,
    [string]$NotesFile = '',
    [string[]]$ReplayArgs = @()
  )

  if (-not (Test-Path -LiteralPath $LauncherSelf)) {
    Write-Host "  [x] Cannot refresh the launcher - $LauncherSelf does not exist." -ForegroundColor Red
    Write-Host "      Reinstall: irm https://raw.githubusercontent.com/$Repo/main/scripts/install.ps1 | iex" -ForegroundColor Cyan
    return 3
  }

  Write-Host "  -> Refreshing the launcher for $Tag..." -ForegroundColor Cyan
  $ltmp = Join-Path $env:TEMP ("osa-launcher-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $ltmp | Out-Null
  $lsrc = Join-Path $ltmp 'install.ps1'
  $lurl = "$LauncherRawBase/$Tag/scripts/install.ps1"
  try {
    Invoke-WebRequest -Uri $lurl -OutFile $lsrc -UseBasicParsing
  } catch {
    Remove-Item -Recurse -Force $ltmp -ErrorAction SilentlyContinue
    Write-Host "  [x] Could not download the launcher for $Tag." -ForegroundColor Red
    Write-Host "      $lurl" -ForegroundColor DarkGray
    Write-Host "      The backend and TUI ARE updated; $LauncherSelf is still the OLD launcher." -ForegroundColor DarkGray
    Write-Host "      Repair with: irm https://raw.githubusercontent.com/$Repo/main/scripts/install.ps1 | iex" -ForegroundColor Cyan
    return 2
  }

  $candidate = @()
  try { $candidate = Get-LauncherFromInstaller $lsrc } catch { $candidate = @() }
  if (-not (Test-LauncherCandidate $candidate)) {
    Remove-Item -Recurse -Force $ltmp -ErrorAction SilentlyContinue
    Write-Host "      Your working launcher was NOT touched. Nothing was overwritten." -ForegroundColor DarkGray
    Write-Host "      Repair with: irm https://raw.githubusercontent.com/$Repo/main/scripts/install.ps1 | iex" -ForegroundColor Cyan
    return 3
  }

  # Compared as LINES, not bytes: Set-Content's line endings are the platform's,
  # so a byte comparison would report a difference on every run and rewrite a
  # launcher that is in fact identical.
  $curLines = @()
  try { $curLines = @(Get-Content -LiteralPath $LauncherSelf) } catch { $curLines = @() }
  if (($curLines -join "`n") -eq ($candidate -join "`n")) {
    Write-Host "  [ok] Launcher already current (unchanged in $Tag)" -ForegroundColor Green
    Remove-Item -Recurse -Force $ltmp -ErrorAction SilentlyContinue
    return 0
  }

  # Loop guard. The child is marked before relaunch and checks the mark here.
  # An update that relaunches forever is far worse than one that finishes under
  # one-generation-old logic - and we say so out loud rather than hiding it.
  if ($env:OSA_UPDATE_REEXECED) {
    Write-Host "  [!] The launcher changed again after the hand-off; continuing with the current one." -ForegroundColor Yellow
    Write-Host "      Relaunching a second time is refused by design (loop guard)." -ForegroundColor DarkGray
    Remove-Item -Recurse -Force $ltmp -ErrorAction SilentlyContinue
    return 0
  }

  # Backup, stage beside the target, swap, then re-verify what actually landed.
  # The backup is the whole safety net: a half-finished swap must leave a
  # WORKING `osa`, never none at all.
  $lbak = "$LauncherSelf.bak"
  $lnew = "$LauncherSelf.new"
  try {
    Copy-Item -LiteralPath $LauncherSelf -Destination $lbak -Force
  } catch {
    Remove-Item -Recurse -Force $ltmp -ErrorAction SilentlyContinue
    Write-Host "  [x] Could not back up the current launcher to $lbak - refusing to replace it." -ForegroundColor Red
    return 3
  }
  try {
    Set-Content -LiteralPath $lnew -Value $candidate -Encoding UTF8
  } catch {
    Remove-Item -Force $lnew -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $ltmp -ErrorAction SilentlyContinue
    Write-Host "  [x] Could not stage the new launcher at $lnew." -ForegroundColor Red
    Write-Host "      Your launcher is untouched. Check disk space and permissions." -ForegroundColor DarkGray
    return 3
  }
  try {
    Move-Item -LiteralPath $lnew -Destination $LauncherSelf -Force
  } catch {
    Remove-Item -Force $lnew -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $ltmp -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $LauncherSelf)) {
      Copy-Item -LiteralPath $lbak -Destination $LauncherSelf -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  [x] Could not replace the launcher at $LauncherSelf." -ForegroundColor Red
    Write-Host "      The previous launcher was restored from $lbak." -ForegroundColor DarkGray
    return 3
  }
  Remove-Item -Recurse -Force $ltmp -ErrorAction SilentlyContinue

  # What is on disk NOW is what the relaunch below will run. Verify that, not
  # the candidate we verified a moment ago.
  $landed = @()
  try { $landed = @(Get-Content -LiteralPath $LauncherSelf) } catch { $landed = @() }
  if (-not (Test-LauncherCandidate $landed)) {
    Copy-Item -LiteralPath $lbak -Destination $LauncherSelf -Force -ErrorAction SilentlyContinue
    Write-Host "  [x] The installed launcher did not verify - restored the previous one from $lbak." -ForegroundColor Red
    return 3
  }
  Write-Host "  [ok] Launcher updated ($LauncherSelf)" -ForegroundColor Green

  # Hand off. Everything the successor must not redo travels in the environment.
  Write-Host "  -> Handing off to the new launcher to finish this update..." -ForegroundColor Cyan
  $env:OSA_UPDATE_REEXECED  = '1'
  $env:OSA_UPDATE_PHASE     = 'post-install'
  $env:OSA_UPDATE_OLD_VER   = $OldVer
  $env:OSA_UPDATE_NEW_VER   = $Tag
  $env:OSA_UPDATE_UPTODATE  = $(if ($UpToDate) { '1' } else { '0' })
  $env:OSA_UPDATE_NOTES_FILE = $NotesFile

  $psExe = $null
  try { $psExe = (Get-Process -Id $PID).Path } catch { $psExe = $null }
  if (-not $psExe -or -not (Test-Path -LiteralPath $psExe)) {
    $psExe = Join-Path $PSHOME 'powershell.exe'
  }
  if (-not (Test-Path -LiteralPath $psExe)) {
    Write-Host "  [x] Could not locate the PowerShell host to relaunch ($psExe)." -ForegroundColor Red
    Write-Host "      The update is applied on disk; finish it with: osa update" -ForegroundColor DarkGray
    return 3
  }
  # Built as one flat array so the verb and the user's flags each arrive as
  # separate argv entries (an inline array literal would be joined into one).
  $reArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LauncherSelf, 'update') + $ReplayArgs
  & $psExe @reArgs
  exit $LASTEXITCODE
}

# The success report. Factored out so the same-process run and the handed-off
# run print literally the same thing.
function Write-UpdateReport([string]$from, [string]$to, [string]$notes) {
  Write-Host ""
  Write-Host "  [ok] Updated $from -> $to" -ForegroundColor Green
  Write-Host ""
  Write-Host "  What's new"
  if ($notes) {
    ($notes -split "`n" | Select-Object -First 30) | ForEach-Object { Write-Host ("    " + $_.TrimEnd()) }
  } else {
    Write-Host "    See https://github.com/$Repo/releases/tag/$to" -ForegroundColor Cyan
  }
  Write-Host ""
  if ([Environment]::UserInteractive) {
    Read-Host "  Press Enter to launch OSA" | Out-Null
  }
}

function Update-Osa {
  # Real in-place update: download the prebuilt release + TUI, verify sha256,
  # atomically swap under ~/.osa, print the delta + what's new, then return.
  #
  # Every mutating step below is checked explicitly: an unchecked failure here
  # is how a half-applied update (new backend, old TUI) got reported as success.
  param([string[]]$ReplayArgs = @())

  # Resumption point for a handed-off update (see Update-Launcher). The
  # download, the checksum verification and the swap all already happened in our
  # parent process; redoing any of them would re-download the whole release for
  # nothing. All that is left is to say what happened - which is precisely the
  # part the new launcher exists to get right.
  if ($env:OSA_UPDATE_PHASE -eq 'post-install') {
    Write-Host "  [ok] Continuing under the updated launcher (the rest of this update runs the NEW logic)" -ForegroundColor Green
    $rnotes = ''
    if ($env:OSA_UPDATE_NOTES_FILE -and (Test-Path -LiteralPath $env:OSA_UPDATE_NOTES_FILE)) {
      try { $rnotes = Get-Content -Raw -LiteralPath $env:OSA_UPDATE_NOTES_FILE } catch { $rnotes = '' }
      Remove-Item -Force -LiteralPath $env:OSA_UPDATE_NOTES_FILE -ErrorAction SilentlyContinue
    }
    if ($env:OSA_UPDATE_UPTODATE -eq '1') {
      Write-Host "  [ok] Already up to date ($($env:OSA_UPDATE_NEW_VER))" -ForegroundColor Green
    } else {
      Write-UpdateReport $env:OSA_UPDATE_OLD_VER $env:OSA_UPDATE_NEW_VER $rnotes
    }
    # Do not leak the hand-off state into the TUI we are about to launch.
    foreach ($v in 'OSA_UPDATE_PHASE','OSA_UPDATE_OLD_VER','OSA_UPDATE_NEW_VER',
                   'OSA_UPDATE_UPTODATE','OSA_UPDATE_NOTES_FILE') {
      Remove-Item -Path ("Env:" + $v) -ErrorAction SilentlyContinue
    }
    return 0
  }

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
      # The binaries are current - but the LAUNCHER may not be, and nothing else
      # in this install would ever notice. Checking it here is what makes
      # "`osa update` leaves you with the launcher for the release you have" an
      # unconditional invariant rather than a side effect of upgrading.
      $ulrc = Update-Launcher -Tag $latest -OldVer $cur -UpToDate $true -ReplayArgs $ReplayArgs
      if ($ulrc -ne 0) { return $ulrc }
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

  # Third half of the update: the launcher. Deliberately LAST of the three
  # swaps - a failure to fetch it must never abort an update whose binaries have
  # not landed yet, and by this line the only work remaining is the report,
  # which is cheap for the successor to redo.
  #
  # The notes came from the GitHub API and would be lost across the relaunch, so
  # they travel on disk. The child deletes the file after reading it.
  $notesFile = ''
  if ($notes) {
    $notesFile = Join-Path $env:TEMP ("osa-notes-" + [Guid]::NewGuid().ToString('N') + ".txt")
    try { Set-Content -LiteralPath $notesFile -Value $notes -Encoding UTF8 } catch { $notesFile = '' }
  }
  $ulrc = Update-Launcher -Tag $latest -OldVer $cur -UpToDate $false `
    -NotesFile $notesFile -ReplayArgs $ReplayArgs
  if ($notesFile) { Remove-Item -Force -LiteralPath $notesFile -ErrorAction SilentlyContinue }
  if ($ulrc -ne 0) { return $ulrc }

  Write-UpdateReport $cur $latest $notes
  return 0
}

# ── Subcommand pre-translation (verbs -> TUI flags, then fall through) ──
function Drop-First($arr) { if ($arr.Count -le 1) { @() } else { @($arr[1..($arr.Count - 1)]) } }

$argList = @($args)
$overdrive = $false

# `osa opencomputers ...` owns its own argument vector (a passthrough to the
# release binary), so it is matched positionally and never enters the verb scan.
if ($argList.Count -ge 1 -and [string]$argList[0] -eq 'opencomputers') {
  # Not a command in the stock release .bat either - build the same Elixir list
  # the POSIX wrapper builds and hand it to `eval`.
  $ocQuoted = @(Drop-First $argList) | ForEach-Object { '"' + ([string]$_ -replace '\\', '\\' -replace '"', '\"') + '"' }
  & $ReleaseBat eval ('OptimalSystemAgent.CLI.opencomputers([' + ($ocQuoted -join ',') + '])')
  exit $LASTEXITCODE
}

# Flags that consume the NEXT token as their value. Their argument is never a
# verb: `osa --model resume` selects a model named "resume".
$ValueFlags = @('--profile', '--permission-mode', '--model', '-m', '--provider')
$Verbs = @('overdrive', 'continue', 'resume', 'help', 'version', 'setup', 'serve', 'doctor', 'stop', 'update')

# ── Subcommand scan ───────────────────────────────────────────────
# The verb is found WHEREVER it sits in argv, not only at position 0, so mode
# flags may precede it:  osa --overdrive resume <id>   as well as
#                        osa resume <id> --overdrive
$verb = ''
$skip = $false
foreach ($a in $argList) {
  $s = [string]$a
  if ($skip) { $skip = $false; continue }
  if ($s -eq '--') { break }
  if ($ValueFlags -contains $s) { $skip = $true; continue }
  if ($s -in @('--help', '-h')) { $verb = 'help'; break }
  if ($s -in @('--version', '-V', '-v')) { $verb = 'version'; break }
  if ($s.StartsWith('-')) { continue }
  if ($Verbs -contains $s) { $verb = $s; break }
  # Any other bare token is not ours; let the TUI's parser reject it loudly.
  break
}

# ── Verb -> TUI flag translation ──────────────────────────────────
# Strip the verb (and, for `resume`, the id immediately after it) out of argv
# and append the equivalent flag, so the TUI keeps ONE parser and every other
# flag the user typed survives in place. `update` is stripped untranslated.
if ($verb -in @('overdrive', 'continue', 'resume', 'update')) {
  $kept = @()
  $skip = $false; $hit = $false; $next = $false; $rid = ''
  foreach ($a in $argList) {
    $s = [string]$a
    if ($skip) { $skip = $false; $kept += $s; continue }
    if ($ValueFlags -contains $s) { $skip = $true; $kept += $s; continue }
    if (-not $hit -and $s -eq $verb) { $hit = $true; $next = $true; continue }
    if ($next) {
      $next = $false
      # Only the token IMMEDIATELY after `resume`, and only if not a flag.
      if ($verb -eq 'resume' -and -not $s.StartsWith('-')) { $rid = $s; continue }
    }
    $kept += $s
  }
  switch ($verb) {
    'overdrive' { $overdrive = $true; $kept += '--overdrive' }
    'continue'  { $kept += '--continue' }
    'resume'    {
      # Bare `osa resume` -> the session picker, populated from recent sessions.
      if ($rid) { $kept += '--resume'; $kept += $rid } else { $kept += '--resume' }
    }
  }
  $argList = @($kept)
}

foreach ($a in $argList) {
  if ($a -in @('--overdrive', '--dangerously-skip-permissions', '--yolo')) { $overdrive = $true }
}

# ── Subcommand dispatch ───────────────────────────────────────────
$cmd = $verb

switch -Exact ($cmd) {
  'version' {
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
  # Dispatched through `eval` because the stock release .bat has no such
  # commands; these three printed "ERROR: Unknown command <verb>" before.
  'setup'  { & $ReleaseBat eval 'OptimalSystemAgent.CLI.setup()';  exit $LASTEXITCODE }
  'serve'  { & $ReleaseBat eval 'OptimalSystemAgent.CLI.serve()';  exit $LASTEXITCODE }
  'doctor' { & $ReleaseBat eval 'OptimalSystemAgent.CLI.doctor()'; exit $LASTEXITCODE }
  'stop'   { Stop-Daemon; exit 0 }
  'update' {
    # The `update` token was already stripped from $argList by the verb
    # translation above, so the remaining flags launch normally afterwards.
    # They are passed IN so that, if the update replaces this launcher and hands
    # off to the new one (see Update-Launcher), the user's exact invocation is
    # replayed across the process boundary instead of being silently dropped.
    $urc = Update-Osa -ReplayArgs $argList
    if ($urc -ne 0) { exit $urc }
    # fall through to launch on success
  }
  'help' { Show-Help; exit 0 }
}

# ── Default: warm the daemon (attach instantly if healthy), then TUI ──
#
# Skew repair runs FIRST: a backend serving an older build than the installed
# one is stopped here, which turns the fast attach below into the start-fresh
# path for exactly the launches that need it. The user is never told to run
# `osa stop`.
if ((Test-Health $HealthUrl) -and -not (Repair-StaleDaemon)) {
  exit 1
}

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
$env:OSA_URL = "http://127.0.0.1:$Port"   # IPv4 literal - see the $HealthUrl note above
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
