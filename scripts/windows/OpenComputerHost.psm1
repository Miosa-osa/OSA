# Pure enrollment contracts shared by the installer, task runner and tests.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OcConfigPlan {
    param([AllowNull()][string]$Existing, [Parameter(Mandatory)][string]$Key,
          [Parameter(Mandatory)][string]$ControlUrl)
    if ($Key -cnotmatch '\Aoc_host_[A-Za-z0-9_-]{8,256}\z') { throw 'Invalid host key format.' }
    Assert-OcEndpoint $ControlUrl -Control
    if ($null -ne $Existing -and $Existing.Length -gt 0) {
        $values = @{}
        foreach ($line in ($Existing -split "`n")) {
            if ($line -match '^\s*(host_key|control_url)\s*=\s*"([^"\r\n]*)"\s*$') {
                if ($values.ContainsKey($Matches[1])) { throw 'Duplicate enrollment field; refusing to rewrite.' }
                $values[$Matches[1]] = $Matches[2]
            } elseif ($line -match '^\s*(host_key|control_url)\s*=') {
                throw 'Unrecognized enrollment syntax; existing configuration was preserved.'
            }
        }
        if ($values['host_key'] -cne $Key -or $values['control_url'] -cne $ControlUrl) {
            throw 'Existing enrollment conflicts with the requested identity or endpoint. Nothing was replaced.'
        }
        return [pscustomobject]@{ Write = $false; Content = $Existing }
    }
    $content = "control_url = `"$ControlUrl`"`nhost_key = `"$Key`"`nfingerprint_path = `"~/.osa/open_computers.ed25519`"`nmodes = [`"direct`"]`nheartbeat_ms = 30000`n"
    return [pscustomobject]@{ Write = $true; Content = $content }
}

function Assert-OcEndpoint {
    param([string]$Value, [switch]$Control)
    $uri = $null
    $shape = if ($Control) { '\Awss://[^/?#\\\s@]+/[^#\\\s"'']*\z' } else { '\Ahttps://[^/?#\\\s@]+/*\z' }
    if ($Value -notmatch $shape -or -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.UserInfo -or -not $uri.IsWellFormedOriginalString()) {
        throw 'Enrollment requires an HTTPS API origin and WSS control endpoint without credentials or fragments.'
    }
}

function Get-OcTaskIdentity {
    param([string]$OwnerSid, [string]$OsaHome, [string]$PowerShellExe)
    if ($OwnerSid -notmatch '^S-1-[0-9-]+$') { throw 'Invalid owner SID.' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$OwnerSid|$($OsaHome.ToLowerInvariant())"))).Replace('-', '').Substring(0, 20) }
    finally { $hash.Dispose() }
    $root = Join-Path $OsaHome 'opencomputers-host'
    $runner = (Join-Path $root 'Run-OpenComputer.ps1').Replace("'", "''")
    $command = "& '$runner'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return [pscustomobject][ordered]@{
        Name = "OSA-OpenComputers-$digest"; OwnerSid = $OwnerSid
        Execute = $PowerShellExe; Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        WorkingDirectory = $OsaHome; LogonType = 'Interactive'; RunLevel = 'Limited'
        MultipleInstances = 'IgnoreNew'; ExecutionTimeLimit = 'PT0S'
        Description = "OSA OpenComputers owner-scoped host v1 $digest"
    }
}

function Assert-OcTaskMatch {
    param($Expected, $Existing)
    if ($null -eq $Existing) { return }
    foreach ($name in @('OwnerSid','Execute','Arguments','WorkingDirectory','LogonType','RunLevel','MultipleInstances','ExecutionTimeLimit','Description')) {
        if (-not $Existing.PSObject.Properties[$name] -or $Existing.$name -cne $Expected.$name) {
            throw 'A conflicting scheduled task exists. It was not stopped or overwritten.'
        }
    }
}

function Get-OcRuntimeDisposition {
    param([bool]$RuntimeExists, [bool]$HomeExists, [bool]$InstallIfMissing,
          [ValidateSet('none','owned','foreign')][string]$Listener)
    if ($Listener -eq 'foreign') { throw 'The selected port is owned by another or unverifiable process. Nothing was stopped.' }
    if ($RuntimeExists) { return 'reuse' }
    if ($HomeExists) { throw 'An incomplete or different OSA installation exists. Repair it explicitly; enrollment will not overwrite it.' }
    if (-not $InstallIfMissing) { throw 'OSA is missing. Install OSA first or explicitly select InstallIfMissing.' }
    if ($Listener -ne 'none') { throw 'Cannot install while a backend is already running.' }
    return 'install'
}

Export-ModuleMember -Function Get-OcConfigPlan, Assert-OcEndpoint, Get-OcTaskIdentity, Assert-OcTaskMatch, Get-OcRuntimeDisposition
