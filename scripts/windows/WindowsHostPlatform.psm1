# Windows-only operating system calls. The enrollment policy lives separately.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OcOwner {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows is required.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run enrollment in the owner''s ordinary unelevated session, not as Administrator or SYSTEM.'
    }
    return $identity.User.Value
}

function Assert-OcLocalPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) { throw 'Network paths are not supported for host execution.' }
    $item = $full
    while ($item) {
        if (Test-Path -LiteralPath $item) {
            if (((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Reparse points are not supported in the host execution path.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($item)
        if ($parent -eq $item) { break }
        $item = $parent
    }
}

function Assert-OcPrivatePath {
    param([string]$Path, [string]$OwnerSid)
    Assert-OcLocalPath $Path
    $acl = Get-Acl -LiteralPath $Path
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $OwnerSid) {
        throw 'An enrollment file is not owned by the current user.'
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @($OwnerSid,'S-1-5-18','S-1-5-32-544')) {
            throw 'An enrollment file has access for another principal. Correct its ACL explicitly before retrying.'
        }
    }
}

function New-OcPrivateDirectory {
    param([string]$Path, [string]$OwnerSid)
    Assert-OcLocalPath $Path
    if (Test-Path -LiteralPath $Path) { Assert-OcPrivatePath $Path $OwnerSid; return }
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $sid = New-Object Security.Principal.SecurityIdentifier($OwnerSid)
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($allowed in @($OwnerSid,'S-1-5-18')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($allowed)), 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-OcNewPrivateFile {
    param([string]$Path, [byte[]]$Bytes, [string]$PrivateDirectory, [string]$OwnerSid)
    Assert-OcPrivatePath $PrivateDirectory $OwnerSid
    Assert-OcLocalPath $Path
    $temporary = Join-Path $PrivateDirectory ([Guid]::NewGuid().ToString('N') + '.pending')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        Assert-OcPrivatePath $temporary $OwnerSid
        # File.Move without overwrite fails atomically if another writer won.
        [IO.File]::Move($temporary, $Path)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-OcListener {
    param([int]$Port, [string]$OsaHome, [string]$OwnerSid)
    $connections = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -eq $Port)
    if ($connections.Count -eq 0) { return 'none' }
    $owners = @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
    if ($owners.Count -ne 1) { return 'foreign' }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$owners[0])" -ErrorAction Stop
    if (-not $process -or -not $process.ExecutablePath) { return 'foreign' }
    $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
    if ($owner.ReturnValue -ne 0 -or $owner.Sid -ne $OwnerSid) { return 'foreign' }
    $release = [IO.Path]::GetFullPath((Join-Path $OsaHome 'release')).TrimEnd('\') + '\'
    $executable = [IO.Path]::GetFullPath($process.ExecutablePath)
    if (-not $executable.StartsWith($release, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($executable) -notin @('erl.exe','werl.exe','beam.smp.exe')) { return 'foreign' }
    return 'owned'
}

function Get-OcScheduledTask {
    param([string]$Name)
    # Enumerate instead of swallowing permission/transport errors as "not found".
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -ceq $Name -and $_.TaskPath -eq '\' })
    if ($tasks.Count -eq 0) { return $null }
    if ($tasks.Count -ne 1) { throw 'Ambiguous scheduled task identity.' }
    $task = $tasks[0]
    if (@($task.Actions).Count -ne 1 -or @($task.Triggers).Count -ne 1 -or
        $task.Triggers[0].CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger' -or
        (Resolve-OcSid $task.Triggers[0].UserId) -ne (Resolve-OcSid $task.Principal.UserId) -or -not $task.Triggers[0].Enabled -or -not $task.Settings.Enabled) {
        throw 'Existing scheduled task has a conflicting action or trigger.'
    }
    return [pscustomobject]@{
        OwnerSid = Resolve-OcSid $task.Principal.UserId; Execute = $task.Actions[0].Execute
        Arguments = $task.Actions[0].Arguments; WorkingDirectory = $task.Actions[0].WorkingDirectory
        LogonType = [string]$task.Principal.LogonType; RunLevel = [string]$task.Principal.RunLevel
        MultipleInstances = [string]$task.Settings.MultipleInstances; ExecutionTimeLimit = $task.Settings.ExecutionTimeLimit
        Description = $task.Description; State = [string]$task.State
    }
}

function Resolve-OcSid {
    param([string]$Identity)
    if ($Identity -match '^S-1-[0-9-]+$') { return $Identity }
    $account = New-Object Security.Principal.NTAccount($Identity)
    return $account.Translate([Security.Principal.SecurityIdentifier]).Value
}

function Register-OcScheduledTask {
    param($Identity)
    $action = New-ScheduledTaskAction -Execute $Identity.Execute -Argument $Identity.Arguments -WorkingDirectory $Identity.WorkingDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Identity.OwnerSid
    $principal = New-ScheduledTaskPrincipal -UserId $Identity.OwnerSid -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    # No -Force: a racing or foreign task must never be replaced.
    Register-ScheduledTask -TaskName $Identity.Name -TaskPath '\' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $Identity.Description -ErrorAction Stop | Out-Null
}

function Invoke-OcRuntimeInstaller {
    param([string]$Shell, [string]$Installer)
    & $Shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Installer *> $null
    return $LASTEXITCODE
}

Export-ModuleMember -Function Get-OcOwner, Assert-OcLocalPath, Assert-OcPrivatePath, New-OcPrivateDirectory, Write-OcNewPrivateFile, Get-OcListener, Get-OcScheduledTask, Register-OcScheduledTask, Invoke-OcRuntimeInstaller
