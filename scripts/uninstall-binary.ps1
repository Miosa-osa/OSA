#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the OSA binary install on Windows.
.DESCRIPTION
    Uninstalls the binary placed by install-binary.ps1.
    Removes the binary and cleans the User PATH entry.
.EXAMPLE
    iwr https://osa.miosa.ai/uninstall.ps1 | iex
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$DefaultInstallDir = Join-Path $env:LOCALAPPDATA 'osa\bin'
$InstallDir = if ($env:OSA_INSTALL_DIR) { $env:OSA_INSTALL_DIR } else { $DefaultInstallDir }
$BinaryPath = Join-Path $InstallDir 'osa.exe'

Write-Host ""
Write-Host "  OSA — Uninstall (Windows binary)" -ForegroundColor White
Write-Host ""

# Remove binary
if (Test-Path $BinaryPath) {
    Remove-Item $BinaryPath -Force
    Write-Host "  Removed: $BinaryPath" -ForegroundColor Green
} else {
    Write-Host "  Binary not found at $BinaryPath — nothing to remove." -ForegroundColor Yellow
}

# Remove install dir if empty
if (Test-Path $InstallDir) {
    $remaining = Get-ChildItem $InstallDir -ErrorAction SilentlyContinue
    if (-not $remaining) {
        Remove-Item $InstallDir -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed empty directory: $InstallDir" -ForegroundColor Green
    }
}

# Remove from User PATH
$CurrentPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
if ($CurrentPath -and $CurrentPath -like "*${InstallDir}*") {
    $entries   = $CurrentPath -split ';' | Where-Object { $_ -and $_ -ne $InstallDir }
    $NewPath   = $entries -join ';'
    [System.Environment]::SetEnvironmentVariable('PATH', $NewPath, 'User')
    $env:PATH  = ($env:PATH -split ';' | Where-Object { $_ -and $_ -ne $InstallDir }) -join ';'
    Write-Host "  Removed $InstallDir from User PATH" -ForegroundColor Green
} else {
    Write-Host "  $InstallDir was not in User PATH — no PATH change needed." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  Done. OSA has been removed." -ForegroundColor Green
Write-Host ""
