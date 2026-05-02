#Requires -Version 5.1
<#
.SYNOPSIS
    OSA Agent binary installer for Windows.
.DESCRIPTION
    Downloads the pre-built Burrito binary from GitHub Releases.
    No build toolchain required — installs a single self-contained executable.
.EXAMPLE
    iwr https://osa.miosa.ai/install.ps1 | iex
.EXAMPLE
    $env:OSA_VERSION = "v0.3.1"; iwr https://osa.miosa.ai/install.ps1 | iex
.NOTES
    Supports PowerShell 5.1+ and pwsh 7+.
    Respects $env:OSA_VERSION and $env:OSA_INSTALL_DIR.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$GitHubRepo  = 'Miosa-osa/OSA'
$DefaultInstallDir = Join-Path $env:LOCALAPPDATA 'osa\bin'
$InstallDir  = if ($env:OSA_INSTALL_DIR) { $env:OSA_INSTALL_DIR } else { $DefaultInstallDir }
$BinaryName  = 'osa.exe'

# Windows only supports x86_64 for now (arm64 support planned)
$OsArch      = 'x86_64'
$AssetName   = "osa-windows-${OsArch}.zip"
$AssetSha256 = "${AssetName}.sha256"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step { Write-Host "`n  -> $args" -ForegroundColor Cyan }
function Write-OK   { Write-Host "  ok $args"  -ForegroundColor Green }
function Write-Warn { Write-Host "  !! WARNING: $args" -ForegroundColor Yellow }
function Write-Fail {
    Write-Host "`n  !! ERROR: $args" -ForegroundColor Red
    exit 1
}

function Get-FileWithRetry {
    param([string]$Uri, [string]$OutFile, [int]$Retries = 3)
    $attempt = 0
    while ($attempt -lt $Retries) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            return $true
        } catch {
            $attempt++
            if ($attempt -ge $Retries) { return $false }
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  OSA — Optimal System Agent" -ForegroundColor White -NoNewline
Write-Host " (Windows)" -ForegroundColor DarkGray
Write-Host "  Binary installer" -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------------
$ApiUrl = "https://api.github.com/repos/${GitHubRepo}/releases/latest"

if ($env:OSA_VERSION) {
    $Version = $env:OSA_VERSION
    Write-Step "Using pinned version: $Version"
} else {
    Write-Step "Fetching latest release..."
    $TmpMeta = Join-Path $env:TEMP 'osa-meta.json'
    if (-not (Get-FileWithRetry -Uri $ApiUrl -OutFile $TmpMeta)) {
        Write-Fail "Could not reach GitHub API. Check your internet connection."
    }
    $meta = Get-Content $TmpMeta -Raw | ConvertFrom-Json
    Remove-Item $TmpMeta -ErrorAction SilentlyContinue
    $Version = $meta.tag_name
    if (-not $Version) { Write-Fail "Could not determine latest release version." }
    Write-OK "Latest release: $Version"
}

$DownloadBase = "https://github.com/${GitHubRepo}/releases/download/${Version}"
$ZipUrl       = "${DownloadBase}/${AssetName}"
$Sha256Url    = "${DownloadBase}/${AssetSha256}"

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
$TmpDir = Join-Path $env:TEMP "osa-install-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

$TmpZip    = Join-Path $TmpDir $AssetName
$TmpSha256 = Join-Path $TmpDir $AssetSha256

Write-Step "Downloading ${AssetName}..."
if (-not (Get-FileWithRetry -Uri $ZipUrl -OutFile $TmpZip)) {
    Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Fail "Download failed. URL: $ZipUrl`n  Verify the release exists: https://github.com/${GitHubRepo}/releases"
}
Write-OK "Downloaded ${AssetName}"

# ---------------------------------------------------------------------------
# Verify checksum (optional)
# ---------------------------------------------------------------------------
Write-Step "Verifying checksum..."
try {
    if (Get-FileWithRetry -Uri $Sha256Url -OutFile $TmpSha256) {
        $expectedLine = (Get-Content $TmpSha256 -Raw).Trim()
        $expected = ($expectedLine -split '\s+')[0]

        if ($expected) {
            $actual = (Get-FileHash -Path $TmpZip -Algorithm SHA256).Hash.ToLower()
            $expectedLower = $expected.ToLower()

            if ($actual -ne $expectedLower) {
                Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Fail "Checksum mismatch!`n  Expected: $expectedLower`n  Got:      $actual`n  The download may be corrupted."
            }
            Write-OK "Checksum verified"
        } else {
            Write-Warn "Checksum file was empty — skipping verification."
        }
    } else {
        Write-Warn "No .sha256 file found for this release — skipping verification."
    }
} catch {
    Write-Warn "Checksum verification skipped: $_"
}

# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------
Write-Step "Extracting..."
$TmpExtract = Join-Path $TmpDir 'extract'
New-Item -ItemType Directory -Path $TmpExtract -Force | Out-Null

try {
    Expand-Archive -Path $TmpZip -DestinationPath $TmpExtract -Force
} catch {
    Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Fail "Extraction failed: $_"
}

# Find the binary
$ExtractedBin = Get-ChildItem -Path $TmpExtract -Recurse -Filter 'osa.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ExtractedBin) {
    # Fallback: any .exe
    $ExtractedBin = Get-ChildItem -Path $TmpExtract -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $ExtractedBin) {
    Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Fail "Could not find 'osa.exe' in the archive."
}
Write-OK "Extracted"

# ---------------------------------------------------------------------------
# Install binary
# ---------------------------------------------------------------------------
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$Dest = Join-Path $InstallDir $BinaryName
Copy-Item -Path $ExtractedBin.FullName -Destination $Dest -Force
Write-OK "Installed to $Dest"

# Cleanup temp
Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Add to User PATH
# ---------------------------------------------------------------------------
$CurrentPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
if (-not $CurrentPath) { $CurrentPath = '' }

if ($CurrentPath -notlike "*${InstallDir}*") {
    $NewPath = "${InstallDir};${CurrentPath}".TrimEnd(';')
    [System.Environment]::SetEnvironmentVariable('PATH', $NewPath, 'User')
    $env:PATH = "${InstallDir};$env:PATH"
    Write-OK "Added $InstallDir to User PATH"
    $pathChanged = $true
} else {
    $pathChanged = $false
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  OSA $Version installed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  Location: $Dest" -ForegroundColor DarkGray
Write-Host ""

if ($pathChanged) {
    Write-Host "  Restart your shell (PowerShell / cmd) to pick up PATH changes." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  Next step:"
Write-Host ""
Write-Host "    osa opencomputers login --key <your-key>" -ForegroundColor White
Write-Host ""
Write-Host "  Get your key at: https://miosa.ai/opencomputers" -ForegroundColor DarkGray
Write-Host ""
