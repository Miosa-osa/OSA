# Execute the actual installer, replacing only Windows OS calls with a fixture module.
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root = Join-Path ([IO.Path]::GetTempPath()) ('osa-windows-enrollment-test-' + [Guid]::NewGuid().ToString('N'))
$saved = @{}
foreach ($name in @('USERPROFILE','SystemRoot','OSA_HOME','OC_FIXTURE_ROOT','OC_FIXTURE_LISTENER')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
try {
    $env:USERPROFILE = Join-Path $root 'owner'
    $env:SystemRoot = Join-Path $root 'system'
    $env:OSA_HOME = $null
    $env:OC_FIXTURE_ROOT = $root
    $env:OC_FIXTURE_LISTENER = 'none'
    $runtime = Join-Path $env:USERPROFILE '.osa'
    $bin = Join-Path $runtime 'bin'
    $release = Join-Path $runtime 'release/bin'
    $stage = Join-Path $root 'bundle'
    foreach ($dir in @($bin,$release,$stage)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $bin 'osa.ps1'), '# fixture launcher; must never execute')
    [IO.File]::WriteAllText((Join-Path $release 'osagent.bat'), 'fixture runtime')
    foreach ($name in @('Install-OpenComputer.ps1','Run-OpenComputer.ps1','OpenComputerHost.psm1')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination $stage
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'FixturePlatform.psm1') -Destination (Join-Path $stage 'WindowsHostPlatform.psm1')
    $installer = Join-Path $stage 'Install-OpenComputer.ps1'
    $key = 'oc_host_fixture_12345678'
    $config = Join-Path $runtime 'open_computers.toml'
    $session = Join-Path $runtime 'user-session.txt'
    [IO.File]::WriteAllText($session, 'preserve this session')
    & $installer -Key $key -NoStart -WhatIf
    if (Test-Path -LiteralPath $config) { throw 'WhatIf wrote enrollment config' }
    if (Test-Path -LiteralPath (Join-Path $root 'task.json')) { throw 'WhatIf registered a task' }
    Write-Host 'PASS actual installer WhatIf is read-only'
    & $installer -Key $key -NoStart
    if (-not (Test-Path -LiteralPath $config)) { throw 'Enrollment config not created' }
    if ([IO.File]::ReadAllText($session) -cne 'preserve this session') { throw 'User session was changed' }
    $bytes = [IO.File]::ReadAllBytes($config)
    $stamp = [IO.File]::GetLastWriteTimeUtc($config)
    $calls = [IO.File]::ReadAllText((Join-Path $root 'calls'))
    $fingerprint = Join-Path $runtime 'open_computers.ed25519'
    [IO.File]::WriteAllBytes($fingerprint, [byte[]](1..32))
    & $installer -Key $key -NoStart
    if ([Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -or
        [IO.File]::GetLastWriteTimeUtc($config) -ne $stamp) { throw 'Idempotent enrollment rewrote configuration' }
    if ([IO.File]::ReadAllText((Join-Path $root 'calls')) -cne $calls) { throw 'Matching task was re-registered' }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fingerprint)) -cne [Convert]::ToBase64String([byte[]](1..32))) { throw 'Fingerprint changed' }
    Write-Host 'PASS actual repeated enrollment preserves config, fingerprint, task and sessions'
    $failed = $false
    try { & $installer -Key 'oc_host_other_12345678' -NoStart } catch { $failed = $true }
    if (-not $failed -or [IO.File]::GetLastWriteTimeUtc($config) -ne $stamp) { throw 'Conflicting key was not rejected without mutation' }
    Write-Host 'PASS actual conflicting-key enrollment leaves existing setup untouched'
    $env:OC_FIXTURE_LISTENER = 'foreign'
    $failed = $false
    try { & $installer -Key $key -NoStart } catch { $failed = $true }
    if (-not $failed) { throw 'Foreign process was not rejected' }
    if ([IO.File]::ReadAllText((Join-Path $root 'calls')) -cne $calls) { throw 'Foreign process changed setup' }
    Write-Host 'PASS actual foreign-listener rejection never starts or stops a process'
    $env:OC_FIXTURE_LISTENER = 'none'
    $taskFile = Join-Path $root 'task.json'
    $taskText = [IO.File]::ReadAllText($taskFile)
    $foreignTask = $taskText | ConvertFrom-Json
    $foreignTask.RunLevel = 'Highest'
    [IO.File]::WriteAllText($taskFile, ($foreignTask | ConvertTo-Json -Compress))
    $failed = $false
    try { & $installer -Key $key -NoStart } catch { $failed = $true }
    if (-not $failed -or [IO.File]::ReadAllText((Join-Path $root 'calls')) -cne $calls) { throw 'Conflicting task was touched' }
    [IO.File]::WriteAllText($taskFile, $taskText)
    Write-Host 'PASS actual conflicting task is never overwritten'

    $env:USERPROFILE = Join-Path $root 'fresh-owner'
    [IO.Directory]::CreateDirectory($env:USERPROFILE) | Out-Null
    # Keep the old task file under a different fixture namespace, never delete the old setup.
    $env:OC_FIXTURE_ROOT = Join-Path $root 'fresh-fixture'
    [IO.Directory]::CreateDirectory($env:OC_FIXTURE_ROOT) | Out-Null
    [IO.File]::WriteAllText((Join-Path $stage 'install-runtime.ps1'), '# fixture child process boundary')
    [IO.File]::WriteAllText((Join-Path $stage 'RELEASE_TAG'), 'v1.0.197')
    & $installer -Key $key -InstallIfMissing -NoStart
    $fresh = Join-Path $env:USERPROFILE '.osa'
    if (-not (Test-Path -LiteralPath (Join-Path $fresh 'release/bin/osagent.bat'))) { throw 'Fresh release not promoted' }
    if ([IO.File]::ReadAllText((Join-Path $fresh 'release_root')) -cne (Join-Path $fresh 'release')) { throw 'Promoted release root is stale' }
    if (@(Get-ChildItem -LiteralPath $env:USERPROFILE -Filter '.osa-enrollment-stage-*').Count -ne 0) { throw 'Successful staging was not promoted atomically' }
    if ([IO.File]::ReadAllText($session) -cne 'preserve this session') { throw 'Another owner''s installation was modified' }
    Write-Host 'PASS actual fresh-install orchestration stages and promotes without touching another installation'
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    Remove-Item -LiteralPath $root -Recurse -Force
}
