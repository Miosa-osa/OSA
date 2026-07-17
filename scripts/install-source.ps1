#Requires -Version 5.1
<#
.SYNOPSIS
    OSA Agent — Windows Installer
.DESCRIPTION
    Installs OSA Agent on Windows.
    Auto-installs: Visual Studio Build Tools, Rust, Erlang/OTP, Elixir, Git.
    Builds the Rust TUI, fetches Elixir deps, and installs `osa`/`osagent` commands.
.EXAMPLE
    irm https://raw.githubusercontent.com/Miosa-osa/OptimalSystemAgent/main/scripts/install.ps1 | iex
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\install.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #
$AppName        = 'OSA Agent'
$RepoUrl        = 'https://github.com/Miosa-osa/OptimalSystemAgent.git'
$OsaDir         = "$env:USERPROFILE\.osa"
$AgentDir       = "$OsaDir\agent"
$InstallDir     = "$env:USERPROFILE\.local\bin"
$RustupUrl      = 'https://win.rustup.rs/x86_64'
$RustupInstaller = "$env:TEMP\rustup-init.exe"
$Branch         = if ($env:OSA_BRANCH) { $env:OSA_BRANCH } else { 'main' }

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
function Write-Step  { Write-Host "`n  -> $args" -ForegroundColor Cyan }
function Write-OK    { Write-Host "  [OK] $args"  -ForegroundColor Green }
function Write-Warn  { Write-Host "  [!!] $args" -ForegroundColor Yellow }
function Write-Fail  { Write-Host "`n  [ERR] $args" -ForegroundColor Red; exit 1 }

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Refresh-Path {
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    # Also ensure cargo + elixir are reachable
    if (Test-Path "$env:USERPROFILE\.cargo\bin") {
        $env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"
    }
}

function Add-ToUserPath {
    param([string]$Dir)
    $current = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($current -notlike "*$Dir*") {
        [System.Environment]::SetEnvironmentVariable('PATH', "$Dir;$current", 'User')
        $env:PATH = "$Dir;$env:PATH"
        Write-OK "Added $Dir to user PATH"
    }
}

function Install-ViaWinget {
    param([string]$Id, [string]$Label)
    Write-Step "Installing $Label via winget..."
    winget install --id $Id --silent --accept-source-agreements --accept-package-agreements 2>$null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        # -1978335189 = "already installed"
        Write-Warn "winget returned $LASTEXITCODE for $Label — may already be installed."
    }
    Refresh-Path
    Write-OK "$Label ready"
}

# --------------------------------------------------------------------------- #
# Banner
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host "  ==============================" -ForegroundColor White
Write-Host "   OSA Agent — Windows Installer" -ForegroundColor White
Write-Host "   Your OS, Supercharged" -ForegroundColor DarkGray
Write-Host "  ==============================" -ForegroundColor White
Write-Host ""

# --------------------------------------------------------------------------- #
# winget check
# --------------------------------------------------------------------------- #
Write-Step "Checking winget"
if (-not (Test-Command 'winget')) {
    Write-Fail "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
}
Write-OK "winget available"

# --------------------------------------------------------------------------- #
# Git
# --------------------------------------------------------------------------- #
Write-Step "Checking git"
if (-not (Test-Command 'git')) {
    Install-ViaWinget 'Git.Git' 'Git'
    Refresh-Path
}
if (-not (Test-Command 'git')) {
    Write-Fail "git not found after install. Restart PowerShell and re-run."
}
Write-OK "git: $(git --version)"

# --------------------------------------------------------------------------- #
# Visual Studio Build Tools (C++ workload — required for Rust on Windows)
# --------------------------------------------------------------------------- #
Write-Step "Checking Visual Studio Build Tools"

$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$HasVs = $false

if (Test-Path $VsWhere) {
    $vsInstall = & $VsWhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    $HasVs = ($null -ne $vsInstall -and $vsInstall -ne '')
}

if (-not $HasVs) {
    Install-ViaWinget 'Microsoft.VisualStudio.2022.BuildTools' 'VS Build Tools 2022'
    Write-Warn "After install, open Visual Studio Installer and ensure"
    Write-Warn "'Desktop development with C++' workload is selected."
} else {
    Write-OK "Visual Studio Build Tools with C++ workload: present"
}

# --------------------------------------------------------------------------- #
# Rust
# --------------------------------------------------------------------------- #
Write-Step "Checking Rust"
Refresh-Path

if (Test-Command 'rustc') {
    Write-OK "Rust: $(rustc --version)"
} else {
    Write-Step "Downloading rustup-init.exe..."
    Invoke-WebRequest -Uri $RustupUrl -OutFile $RustupInstaller -UseBasicParsing

    Write-Step "Installing Rust (default MSVC toolchain)..."
    & $RustupInstaller -y --no-modify-path
    if ($LASTEXITCODE -ne 0) { Write-Fail "rustup-init failed with exit code $LASTEXITCODE" }

    Remove-Item $RustupInstaller -ErrorAction SilentlyContinue
    Add-ToUserPath "$env:USERPROFILE\.cargo\bin"
    Refresh-Path

    if (-not (Test-Command 'cargo')) {
        Write-Fail "cargo not found after install. Restart PowerShell and re-run."
    }
    Write-OK "Rust installed: $(rustc --version)"
}

# --------------------------------------------------------------------------- #
# Erlang/OTP
# --------------------------------------------------------------------------- #
Write-Step "Checking Erlang/OTP"
Refresh-Path

if (Test-Command 'erl') {
    Write-OK "Erlang: present"
} else {
    Install-ViaWinget 'ErlangSolutions.ErlangOTP' 'Erlang/OTP'

    # Winget ID may vary — try alternative
    if (-not (Test-Command 'erl')) {
        Install-ViaWinget 'OTP.Erlang' 'Erlang/OTP (alt)'
    }

    Refresh-Path
    if (-not (Test-Command 'erl')) {
        # Manual fallback: download from erlang.org
        Write-Warn "winget install failed — trying direct download..."
        $erlUrl = "https://github.com/erlang/otp/releases/download/OTP-27.2/otp_win64_27.2.exe"
        $erlInstaller = "$env:TEMP\otp_win64.exe"
        Invoke-WebRequest -Uri $erlUrl -OutFile $erlInstaller -UseBasicParsing
        Write-Step "Running Erlang installer (silent)..."
        Start-Process $erlInstaller -Wait -ArgumentList '/S'
        Remove-Item $erlInstaller -ErrorAction SilentlyContinue
        Refresh-Path
    }

    if (-not (Test-Command 'erl')) {
        Write-Fail "Erlang installation failed. Download manually from https://www.erlang.org/downloads"
    }
    Write-OK "Erlang installed"
}

# --------------------------------------------------------------------------- #
# Elixir
# --------------------------------------------------------------------------- #
Write-Step "Checking Elixir"
Refresh-Path

$elixirOK = $false
if (Test-Command 'elixir') {
    $elixirVer = elixir --version 2>$null | Select-String -Pattern '\d+\.\d+\.\d+' | ForEach-Object { $_.Matches[0].Value }
    if ($elixirVer) {
        $parts = $elixirVer.Split('.')
        if ([int]$parts[0] -ge 1 -and [int]$parts[1] -ge 17) {
            Write-OK "Elixir: $elixirVer"
            $elixirOK = $true
        } else {
            Write-Warn "Elixir $elixirVer is too old (need 1.17+). Upgrading..."
        }
    }
}

if (-not $elixirOK) {
    Install-ViaWinget 'ElixirLang.Elixir' 'Elixir'

    # Winget ID may vary
    if (-not (Test-Command 'elixir')) {
        Install-ViaWinget 'Elixir.Elixir' 'Elixir (alt)'
    }

    Refresh-Path

    if (-not (Test-Command 'elixir')) {
        # Manual fallback: download prebuilt zip
        Write-Warn "winget install failed — trying direct download..."
        $otpMajor = '27'
        try {
            $otpMajor = erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>$null
        } catch {}
        $elixirUrl = "https://github.com/elixir-lang/elixir/releases/download/v1.18.3/elixir-otp-${otpMajor}.zip"
        $elixirZip = "$env:TEMP\elixir.zip"
        $elixirDest = "$env:ProgramFiles\Elixir"

        Write-Step "Downloading Elixir 1.18.3..."
        Invoke-WebRequest -Uri $elixirUrl -OutFile $elixirZip -UseBasicParsing
        Write-Step "Extracting to $elixirDest..."
        if (Test-Path $elixirDest) { Remove-Item $elixirDest -Recurse -Force }
        Expand-Archive -Path $elixirZip -DestinationPath $elixirDest -Force
        Remove-Item $elixirZip -ErrorAction SilentlyContinue

        # Add to PATH
        Add-ToUserPath "$elixirDest\bin"
        Refresh-Path
    }

    if (-not (Test-Command 'elixir')) {
        Write-Fail "Elixir installation failed. Download manually from https://elixir-lang.org/install.html#windows"
    }

    # Version check after install
    $elixirVer = elixir --version 2>$null | Select-String -Pattern '\d+\.\d+\.\d+' | ForEach-Object { $_.Matches[0].Value }
    if ($elixirVer) {
        $parts = $elixirVer.Split('.')
        if ([int]$parts[0] -lt 1 -or ([int]$parts[0] -eq 1 -and [int]$parts[1] -lt 17)) {
            Write-Warn "Elixir $elixirVer still too old — attempting prebuilt download..."
            $otpMajor = '27'
            try {
                $otpMajor = erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>$null
            } catch {}
            $elixirUrl = "https://github.com/elixir-lang/elixir/releases/download/v1.18.3/elixir-otp-${otpMajor}.zip"
            $elixirZip = "$env:TEMP\elixir.zip"
            $elixirDest = "$env:ProgramFiles\Elixir"
            Invoke-WebRequest -Uri $elixirUrl -OutFile $elixirZip -UseBasicParsing
            if (Test-Path $elixirDest) { Remove-Item $elixirDest -Recurse -Force }
            Expand-Archive -Path $elixirZip -DestinationPath $elixirDest -Force
            Remove-Item $elixirZip -ErrorAction SilentlyContinue
            Add-ToUserPath "$elixirDest\bin"
            Refresh-Path
        }
    }

    Write-OK "Elixir ready: $(elixir --version 2>$null | Select-String 'Elixir')"
}

# --------------------------------------------------------------------------- #
# Clone / update repo
# --------------------------------------------------------------------------- #
Write-Step "Fetching OSA Agent source"

if (Test-Path "$AgentDir\.git") {
    Write-Step "Repository found — pulling latest..."
    git -C $AgentDir pull --ff-only origin $Branch 2>$null
    Write-OK "Updated"
} elseif (Test-Path $AgentDir) {
    Write-OK "Using existing directory: $AgentDir"
} else {
    Write-Step "Cloning repository..."
    git clone --depth 1 --branch $Branch $RepoUrl $AgentDir
    Write-OK "Cloned to $AgentDir"
}

# Store project root
New-Item -ItemType Directory -Path $OsaDir -Force | Out-Null
Set-Content -Path "$OsaDir\project_root" -Value $AgentDir

# --------------------------------------------------------------------------- #
# Build Rust TUI
# --------------------------------------------------------------------------- #
$TuiDir = "$AgentDir\priv\rust\tui"
if (-not (Test-Path "$TuiDir\Cargo.toml")) {
    Write-Fail "TUI source not found at $TuiDir"
}

Write-Step "Building Rust TUI (first run takes ~2 min)..."
Push-Location $TuiDir
cargo build --release 2>&1 | Select-String -Pattern 'Compiling|Finished|error' | Select-Object -Last 10
$tuiBin = "$TuiDir\target\release\osagent.exe"
if (-not (Test-Path $tuiBin)) {
    Pop-Location
    Write-Fail "TUI build failed. Check errors above."
}
Pop-Location
Write-OK "TUI built"

# --------------------------------------------------------------------------- #
# Fetch Elixir deps
# --------------------------------------------------------------------------- #
Write-Step "Fetching Elixir dependencies..."
Push-Location $AgentDir
mix local.hex --force --if-missing 2>$null | Out-Null
mix local.rebar --force --if-missing 2>$null | Out-Null
mix deps.get 2>&1 | Select-Object -Last 5
mix compile 2>&1 | Select-Object -Last 5
Pop-Location
Write-OK "Dependencies ready"

# --------------------------------------------------------------------------- #
# Install commands
# --------------------------------------------------------------------------- #
Write-Step "Installing osa and osagent commands"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# Create wrapper scripts (Windows .cmd batch files)
# These start the backend + TUI just like bin/osa on Unix
$wrapperContent = @"
@echo off
setlocal
set "OSA_ROOT=$AgentDir"
set "TUI_BIN=$TuiDir\target\release\osagent.exe"
set "LOG_DIR=%USERPROFILE%\.osa\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

if "%~1"=="version" (
    if exist "%OSA_ROOT%\VERSION" (
        echo osagent v
        type "%OSA_ROOT%\VERSION"
    )
    exit /b 0
)

if "%~1"=="update" (
    echo Updating OSA Agent...
    cd /d "%OSA_ROOT%"
    git pull --ff-only origin main
    mix deps.get
    mix compile --force
    cd /d "$TuiDir"
    cargo build --release
    echo Update complete.
    exit /b 0
)

if "%~1"=="serve" (
    cd /d "%OSA_ROOT%"
    mix osa.serve
    exit /b 0
)

if "%~1"=="setup" (
    cd /d "%OSA_ROOT%"
    mix osa.setup
    exit /b 0
)

if "%~1"=="help" (
    echo.
    echo   OSA Agent — Your OS, Supercharged
    echo.
    echo   Usage:
    echo     osa              Start backend + TUI
    echo     osa setup        Run the setup wizard
    echo     osa update       Pull latest + recompile
    echo     osa serve        Start backend only
    echo     osa version      Print version
    echo.
    exit /b 0
)

REM Default: start backend + TUI
echo Starting backend...
cd /d "%OSA_ROOT%"
set MIX_ENV=dev
start /b "" cmd /c "mix osa.serve > "%LOG_DIR%\backend.log" 2>&1"

REM Wait for health
set /a attempts=0
:healthloop
if %attempts% geq 90 (
    echo Backend did not become healthy after 90s.
    echo Check logs: %LOG_DIR%\backend.log
    exit /b 1
)
curl -sf http://localhost:8089/health >nul 2>&1
if %errorlevel%==0 goto healthy
set /a attempts+=1
timeout /t 1 /nobreak >nul
goto healthloop

:healthy
set "OSA_URL=http://localhost:8089"
"%TUI_BIN%" %*
"@

Set-Content -Path "$InstallDir\osa.cmd" -Value $wrapperContent -Encoding ASCII
Copy-Item "$InstallDir\osa.cmd" "$InstallDir\osagent.cmd" -Force
Write-OK "Created osa.cmd and osagent.cmd"

# Add to PATH
Add-ToUserPath $InstallDir

# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
$logsDir = "$OsaDir\logs"
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

$envFile = "$OsaDir\.env"
if (-not (Test-Path $envFile)) {
    $envContent = @"
# OSA Agent Configuration
# Uncomment and set your API key for cloud providers:
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...
# GROQ_API_KEY=gsk_...

# Default: Ollama (local, no API key needed)
# OSA_DEFAULT_PROVIDER=ollama
# OSA_PORT=8089
"@
    Set-Content -Path $envFile -Value $envContent
    Write-OK "Created config template: $envFile"
}

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host "  ======================================" -ForegroundColor Green
Write-Host "   OSA Agent installed successfully!" -ForegroundColor Green
Write-Host "  ======================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Locations:" -ForegroundColor DarkGray
Write-Host "    Agent:    $AgentDir"
Write-Host "    Commands: $InstallDir\osa.cmd"
Write-Host "    Config:   $OsaDir\.env"
Write-Host "    Logs:     $logsDir\"
Write-Host ""
Write-Host "  Quick start:" -ForegroundColor DarkGray
Write-Host "    osa             Start backend + TUI" -ForegroundColor White
Write-Host "    osa update      Pull latest + recompile" -ForegroundColor White
Write-Host "    osa setup       Interactive setup wizard" -ForegroundColor White
Write-Host ""
Write-Host "  If 'osa' is not found, restart PowerShell to pick up PATH changes." -ForegroundColor Yellow
Write-Host ""
