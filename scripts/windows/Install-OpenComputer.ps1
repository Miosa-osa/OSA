#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Key,
    [string]$Region = 'default',
    [string]$PlatformApiUrl = 'https://api.miosa.ai',
    [string]$ControlUrl,
    [ValidateRange(1024,65535)][int]$Port = 9089,
    [switch]$InstallIfMissing,
    [switch]$NoStart
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OpenComputerHost.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WindowsHostPlatform.psm1') -Force

Assert-OcEndpoint $PlatformApiUrl
$PlatformApiUrl = $PlatformApiUrl.TrimEnd('/')
if (-not $ControlUrl) { $ControlUrl = ($PlatformApiUrl -replace '^https:', 'wss:') + '/api/v1/opencomputers/hosts/ws' }
if ($Region -notmatch '\A[A-Za-z0-9_-]{1,64}\z') { throw 'Invalid region identifier.' }
$ownerSid = Get-OcOwner
$osaHome = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.osa'))
if ($env:OSA_HOME -and [IO.Path]::GetFullPath($env:OSA_HOME).TrimEnd('\','/') -cne $osaHome.TrimEnd('\','/')) {
    throw 'Windows host enrollment currently requires the canonical USERPROFILE\.osa installation.'
}
Assert-OcLocalPath $osaHome
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$identity = Get-OcTaskIdentity -OwnerSid $ownerSid -OsaHome $osaHome -PowerShellExe $shell
$root = Join-Path $osaHome 'opencomputers-host'
$config = Join-Path $osaHome 'open_computers.toml'
$launcher = Join-Path $osaHome 'bin\osa.ps1'
$release = Join-Path $osaHome 'release\bin\osagent.bat'
$existing = $null
if (Test-Path -LiteralPath $config) {
    Assert-OcPrivatePath $config $ownerSid
    $existing = [IO.File]::ReadAllText($config)
    if ($existing.Length -eq 0) { throw 'Existing enrollment file is empty; repair it explicitly.' }
}
$configPlan = Get-OcConfigPlan -Existing $existing -Key $Key -ControlUrl $ControlUrl
$listener = Get-OcListener -Port $Port -OsaHome $osaHome -OwnerSid $ownerSid
$runtime = (Test-Path -LiteralPath $launcher -PathType Leaf) -and (Test-Path -LiteralPath $release -PathType Leaf)
$disposition = Get-OcRuntimeDisposition -RuntimeExists $runtime -HomeExists (Test-Path -LiteralPath $osaHome) `
    -InstallIfMissing $InstallIfMissing.IsPresent -Listener $listener
$task = Get-OcScheduledTask $identity.Name
Assert-OcTaskMatch $identity $task
# Old wrappers used one machine-wide name and -Force. Never silently adopt it.
if (Get-OcScheduledTask 'MIOSA OSA OpenComputers') {
    throw 'A legacy MIOSA task exists. Migrate that owner task explicitly before installing a new one; nothing was stopped.'
}
$state = [ordered]@{ Version = 1; OwnerSid = $ownerSid; OsaHome = $osaHome; Port = $Port; Region = $Region; PlatformApiUrl = $PlatformApiUrl; ControlUrl = $ControlUrl }
$stateText = $state | ConvertTo-Json -Compress
$files = [ordered]@{}
foreach ($name in @('Run-OpenComputer.ps1','WindowsHostPlatform.psm1','OpenComputerHost.psm1')) {
    $files[$name] = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $name))
}
$files['host.json'] = [Text.Encoding]::UTF8.GetBytes($stateText)
if (Test-Path -LiteralPath $root) {
    Assert-OcPrivatePath $root $ownerSid
    foreach ($name in $files.Keys) {
        $path = Join-Path $root $name
        if (Test-Path -LiteralPath $path) {
            Assert-OcPrivatePath $path $ownerSid
            if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -cne [Convert]::ToBase64String($files[$name])) {
                throw 'Existing task files differ from this installer. Use an explicit managed update; active sessions were preserved.'
            }
        } elseif ($task) { throw 'Existing task has missing runtime files; refusing an implicit repair.' }
    }
} elseif ($task) { throw 'Existing task has no owner state directory.' }

# No secret appears in ShouldProcess, task arguments or the state file.
if (-not $PSCmdlet.ShouldProcess($identity.Name, "Enroll Windows owner host (runtime=$disposition, existing_backend=$listener)")) { return }
if ($disposition -eq 'install') {
    $installer = Join-Path $PSScriptRoot 'install-runtime.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { throw 'Fresh-install payload is missing. Use the complete versioned Windows enrollment bundle.' }
    $stage = Join-Path $env:USERPROFILE ('.osa-enrollment-stage-' + [Guid]::NewGuid().ToString('N'))
    $oldHome = $env:OSA_HOME; $oldSkip = $env:OSA_INSTALL_SKIP_PATH
    $oldChecksum = $env:OSA_INSTALL_REQUIRE_CHECKSUM; $oldVersion = $env:OSA_VERSION
    try {
        $env:OSA_HOME = $stage; $env:OSA_INSTALL_SKIP_PATH = '1'
        $env:OSA_INSTALL_REQUIRE_CHECKSUM = '1'
        $versionPath = Join-Path $PSScriptRoot 'RELEASE_TAG'
        if (-not (Test-Path -LiteralPath $versionPath)) { throw 'Versioned enrollment bundle is missing its release tag.' }
        $tag = [IO.File]::ReadAllText($versionPath).Trim()
        if ($tag -notmatch '\Av[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?\z') { throw 'Invalid enrollment bundle release tag.' }
        $env:OSA_VERSION = $tag
        $installResult = Invoke-OcRuntimeInstaller $shell $installer
        if ($installResult -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $stage 'release\bin\osagent.bat'))) {
            throw 'Fresh OSA installation failed. The original installation was not changed.'
        }
        # Atomic promotion fails if another installer created .osa meanwhile.
        [IO.Directory]::Move($stage, $osaHome)
        [IO.File]::WriteAllText((Join-Path $osaHome 'release_root'), (Join-Path $osaHome 'release'), [Text.Encoding]::ASCII)
    } finally {
        $env:OSA_HOME = $oldHome; $env:OSA_INSTALL_SKIP_PATH = $oldSkip
        $env:OSA_INSTALL_REQUIRE_CHECKSUM = $oldChecksum; $env:OSA_VERSION = $oldVersion
        # Preserve an unsuccessful staging directory for explicit recovery, never recursively delete user data.
        if (Test-Path -LiteralPath $stage) { Write-Warning "Unsuccessful enrollment staging retained for recovery: $stage" }
    }
}
New-OcPrivateDirectory $root $ownerSid
foreach ($name in $files.Keys) {
    $path = Join-Path $root $name
    if (-not (Test-Path -LiteralPath $path)) { Write-OcNewPrivateFile $path $files[$name] $root $ownerSid }
}
if ($configPlan.Write) {
    Write-OcNewPrivateFile $config ([Text.Encoding]::UTF8.GetBytes($configPlan.Content)) $root $ownerSid
}
# Do not touch the user's fingerprint, marker, profiles, .env, databases or sessions.
[void](Get-OcConfigPlan -Existing ([IO.File]::ReadAllText($config)) -Key $Key -ControlUrl $ControlUrl)
if (-not $task) { Register-OcScheduledTask $identity }
Assert-OcTaskMatch $identity (Get-OcScheduledTask $identity.Name)
if ($NoStart) { Write-Host "Configured $($identity.Name); start was not requested."; return }
if (-not $task -or $task.State -ne 'Running') { Start-ScheduledTask -TaskName $identity.Name -TaskPath '\' -ErrorAction Stop }

$clock = [Diagnostics.Stopwatch]::StartNew()
while ($clock.Elapsed.TotalSeconds -lt 30) {
    $remaining = [Math]::Max(1, [Math]::Floor(30 - $clock.Elapsed.TotalSeconds))
    $current = Get-OcScheduledTask $identity.Name
    if (-not $current) { throw 'The owner task disappeared during registration.' }
    Assert-OcTaskMatch $identity $current
    try {
        $response = Invoke-RestMethod -Uri "$PlatformApiUrl/api/v1/opencomputers/hosts/registration-status" `
            -Method Post -ContentType 'application/json' -Body (@{host_key=$Key} | ConvertTo-Json -Compress) `
            -UseBasicParsing -TimeoutSec ([Math]::Min(5, $remaining)) -ErrorAction Stop
        if ($response.connected -is [bool] -and $response.connected -and $response.host.id -is [string] -and
            $response.host.id -and $current.State -eq 'Running' -and (Get-OcListener $Port $osaHome $ownerSid) -eq 'owned') {
            Write-Host "Connected. Owner task: $($identity.Name)"; return
        }
    } catch {
        # Do not echo HTTP bodies or errors containing the enrollment key.
        $httpStatus = 0
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $httpStatus = [int]$_.Exception.Response.StatusCode
        }
        if ($httpStatus -in @(401,403,410)) { throw "Registration rejected (HTTP $httpStatus); task/config retained for explicit recovery." }
    }
    if ($clock.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds ([Math]::Min(2000, [Math]::Max(1, (30 - $clock.Elapsed.TotalSeconds) * 1000))) }
}
if ($listener -eq 'owned') {
    throw 'Existing OSA was preserved, but enrollment is not connected. Activate host mode during an owner-controlled restart; no process was stopped.'
}
throw 'Owner task configured, but a live host connection was not confirmed. Inspect the task and retry; setup is not reported as connected.'
