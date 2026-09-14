# Test-only OS adapter. Never import from a production enrollment bundle.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-OcOwner { 'S-1-5-21-123' }
function Assert-OcLocalPath { param($Path) }
function Assert-OcPrivatePath { param($Path,$OwnerSid) }
function New-OcPrivateDirectory { param($Path,$OwnerSid) [IO.Directory]::CreateDirectory($Path) | Out-Null }
function Write-OcNewPrivateFile {
    param($Path,$Bytes,$PrivateDirectory,$OwnerSid)
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew)
    try { $stream.Write($Bytes,0,$Bytes.Length) } finally { $stream.Dispose() }
}
function Get-OcListener {
    param($Port,$OsaHome,$OwnerSid)
    if ($env:OC_FIXTURE_LISTENER) { return $env:OC_FIXTURE_LISTENER }
    return 'none'
}
function Get-OcScheduledTask {
    param($Name)
    $file = Join-Path $env:OC_FIXTURE_ROOT 'task.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $task = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if ($Name -eq $task.Name) { return $task }
    return $null
}
function Register-OcScheduledTask {
    param($Identity)
    $file = Join-Path $env:OC_FIXTURE_ROOT 'task.json'
    if (Test-Path -LiteralPath $file) { throw 'Task already exists; a real call would fail without Force' }
    $task = $Identity | Select-Object *
    $task | Add-Member -NotePropertyName State -NotePropertyValue Ready
    [IO.File]::WriteAllText($file, ($task | ConvertTo-Json -Compress))
    [IO.File]::AppendAllText((Join-Path $env:OC_FIXTURE_ROOT 'calls'), "register`n")
}
function Start-ScheduledTask { throw 'Fixture forbids starting actual tasks' }
function Invoke-OcRuntimeInstaller {
    param($Shell,$Installer)
    if ($env:OSA_INSTALL_SKIP_PATH -ne '1' -or $env:OSA_INSTALL_REQUIRE_CHECKSUM -ne '1' -or $env:OSA_VERSION -ne 'v1.0.197') {
        throw 'Fresh enrollment did not pin the bundle version, require checksums and disable PATH mutation'
    }
    $bin = Join-Path $env:OSA_HOME 'bin'
    $release = Join-Path $env:OSA_HOME 'release/bin'
    [IO.Directory]::CreateDirectory($bin) | Out-Null
    [IO.Directory]::CreateDirectory($release) | Out-Null
    [IO.File]::WriteAllText((Join-Path $bin 'osa.ps1'), '# fresh fixture')
    [IO.File]::WriteAllText((Join-Path $release 'osagent.bat'), 'fresh fixture')
    [IO.File]::AppendAllText((Join-Path $env:OC_FIXTURE_ROOT 'calls'), "install-staged`n")
    return 0
}
Export-ModuleMember -Function *
