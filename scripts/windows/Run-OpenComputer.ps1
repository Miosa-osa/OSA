# Owner-scoped Task Scheduler entrypoint. It never stops another backend.
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WindowsHostPlatform.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'OpenComputerHost.psm1') -Force
$ownerSid = Get-OcOwner
Assert-OcPrivatePath $PSScriptRoot $ownerSid
$statePath = Join-Path $PSScriptRoot 'host.json'
Assert-OcPrivatePath $statePath $ownerSid
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$expectedHome = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.osa'))
if ($state.Version -ne 1 -or $state.OwnerSid -ne $ownerSid -or $state.OsaHome -cne $expectedHome -or
    $state.Port -lt 1024 -or $state.Port -gt 65535) { throw 'Host task identity does not match the current owner.' }
$launcher = Join-Path $expectedHome 'bin\osa.ps1'
Assert-OcLocalPath $launcher
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Installed OSA launcher is missing.' }
Assert-OcPrivatePath (Join-Path $expectedHome 'open_computers.toml') $ownerSid
$configText = [IO.File]::ReadAllText((Join-Path $expectedHome 'open_computers.toml'))
$keys = [regex]::Matches($configText, '(?m)^\s*host_key\s*=\s*"([^"\r\n]+)"\s*$')
if ($keys.Count -ne 1) { throw 'Host configuration has an invalid identity.' }
[void](Get-OcConfigPlan -Existing $configText -Key $keys[0].Groups[1].Value -ControlUrl $state.ControlUrl)

$env:OSA_HOME = $expectedHome
$env:OSA_PORT = [string]$state.Port
$env:OSA_OPEN_COMPUTERS_CONFIG = Join-Path $expectedHome 'open_computers.toml'
$env:OSA_OPEN_COMPUTERS_ENABLED = 'true'
# Nonempty process values prevent the launcher's .env defaults overriding enrollment identity.
$env:OSA_OPEN_COMPUTERS_HOST_KEY = $keys[0].Groups[1].Value
$env:OSA_OPEN_COMPUTERS_CONTROL_URL = $state.ControlUrl
$fingerprints = [regex]::Matches($configText, '(?m)^\s*fingerprint_path\s*=\s*"([^"\r\n]+)"\s*$')
if ($fingerprints.Count -gt 1) { throw 'Ambiguous fingerprint configuration.' }
$env:OSA_OPEN_COMPUTERS_FINGERPRINT_PATH = if ($fingerprints.Count -eq 1) { $fingerprints[0].Groups[1].Value } else { '~/.osa/open_computers.ed25519' }
Set-Location -LiteralPath $expectedHome
while ($true) {
    $listener = Get-OcListener -Port $state.Port -OsaHome $expectedHome -OwnerSid $ownerSid
    if ($listener -eq 'foreign') { throw 'Host port is occupied by a foreign or unverifiable process; refusing to start.' }
    if ($listener -eq 'owned') {
        # Preserve the existing runtime and user sessions. No implicit restart.
        Start-Sleep -Seconds 5
        continue
    }
    # The serve verb bypasses the launcher's TUI/skew-repair/stop paths.
    # Task Scheduler owns this process tree, not arbitrary beam/erl processes.
    & $launcher serve
    exit $LASTEXITCODE
}
