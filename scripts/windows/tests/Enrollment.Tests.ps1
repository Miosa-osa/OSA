$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../OpenComputerHost.psm1') -Force
$key = 'oc_host_fixture_12345678'
$url = 'wss://api.miosa.ai/api/v1/opencomputers/hosts/ws'
$existing = "control_url = `"$url`"`nhost_key = `"$key`"`nmodes = [`"direct`", `"custom`"]`n# preserve me`n"
$plan = Get-OcConfigPlan -Existing $existing -Key $key -ControlUrl $url
if ($plan.Write -or $plan.Content -cne $existing) { throw 'Matching enrollment must be byte-preserved' }
Write-Host 'PASS matching enrollment is not rewritten'

function Assert-Throws([scriptblock]$Action) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    if (-not $failed) { throw 'Expected a fail-closed rejection' }
}
Assert-Throws { Get-OcConfigPlan -Existing $existing -Key 'oc_host_different_123' -ControlUrl $url }
Assert-Throws { Get-OcConfigPlan -Existing ($existing + "host_key = `"$key`"`n") -Key $key -ControlUrl $url }
Assert-Throws { Get-OcConfigPlan -Existing $existing -Key $key -ControlUrl 'wss://other.example/ws' }
foreach ($bad in @('http://example.com','https://u:p@example.com','https://example.com/path','https://example.com?key=secret')) {
    Assert-Throws { Assert-OcEndpoint $bad }
}
foreach ($bad in @('ws://example.com/ws','wss://example.com/ws#secret',"wss://example.com/`"oops")) {
    Assert-Throws { Assert-OcEndpoint $bad -Control }
}
Write-Host 'PASS conflicting/malformed credentials and unsafe endpoints rejected'
$first = Get-OcTaskIdentity -OwnerSid 'S-1-5-21-123' -OsaHome '/fixture/.osa' -PowerShellExe '/system/powershell.exe'
$same = Get-OcTaskIdentity -OwnerSid 'S-1-5-21-123' -OsaHome '/fixture/.osa' -PowerShellExe '/system/powershell.exe'
$other = Get-OcTaskIdentity -OwnerSid 'S-1-5-21-456' -OsaHome '/fixture/.osa' -PowerShellExe '/system/powershell.exe'
if ($first.Name -cne $same.Name -or $first.Name -ceq $other.Name) { throw 'Task names are not owner scoped and deterministic' }
Assert-OcTaskMatch $first $same
Assert-Throws { Assert-OcTaskMatch $first $other }
$modified = $same | Select-Object *
$modified.RunLevel = 'Highest'
Assert-Throws { Assert-OcTaskMatch $first $modified }
if (($first | ConvertTo-Json -Compress).Contains($key)) { throw 'Task identity contains host credentials' }
Write-Host 'PASS owner-scoped task identity and privileged-task conflict guard'
if ((Get-OcRuntimeDisposition -RuntimeExists $true -HomeExists $true -InstallIfMissing $true -Listener owned) -ne 'reuse') { throw 'Existing OSA must be reused' }
if ((Get-OcRuntimeDisposition -RuntimeExists $false -HomeExists $false -InstallIfMissing $true -Listener none) -ne 'install') { throw 'Fresh install should be allowed explicitly' }
Assert-Throws { Get-OcRuntimeDisposition -RuntimeExists $true -HomeExists $true -InstallIfMissing $true -Listener foreign }
Assert-Throws { Get-OcRuntimeDisposition -RuntimeExists $false -HomeExists $true -InstallIfMissing $true -Listener none }
Assert-Throws { Get-OcRuntimeDisposition -RuntimeExists $false -HomeExists $false -InstallIfMissing $false -Listener none }
Write-Host 'PASS reuse, incomplete-install, missing-install and foreign-listener policy'

# Parse every shipping PowerShell file without executing Windows operations.
$scripts = @(Get-ChildItem (Join-Path $PSScriptRoot '..') -File | Where-Object Extension -in @('.ps1','.psm1'))
$scripts += Get-Item (Join-Path $PSScriptRoot '../../install.ps1')
foreach ($script in $scripts) {
    $errors = $null; $tokens = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "PowerShell syntax errors in $($script.Name): $($errors[0].Message)" }
}
Write-Host 'PASS shipping PowerShell syntax'
& (Join-Path $PSScriptRoot 'Enrollment.Fixtures.ps1')
