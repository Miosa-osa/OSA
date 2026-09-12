# Build-only: no screen capture, input, enrollment or task registration.
[CmdletBinding()]
param(
    [ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64',
    [string]$BundleDirectory,
    [string]$Dotnet = 'dotnet'
)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'ScreenShare.csproj'
$output = Join-Path $PSScriptRoot "publish/$Runtime"
& $Dotnet run --project (Join-Path $PSScriptRoot 'tests/ProtocolTests.csproj') -c Release
if ($LASTEXITCODE -ne 0) { throw 'Windows desktop protocol tests failed.' }
& $Dotnet publish $project -c Release -r $Runtime --self-contained true -o $output
if ($LASTEXITCODE -ne 0) { throw 'Windows desktop helper publish failed.' }
$helper = Join-Path $output 'osa-screen-capture-windows.exe'
if (-not (Test-Path -LiteralPath $helper) -or (Get-Item -LiteralPath $helper).Length -eq 0) { throw 'Published helper is missing.' }
$bytes = [IO.File]::ReadAllBytes($helper)
$peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
$expected = if ($Runtime -eq 'win-x64') { 0x8664 } else { 0xaa64 }
if ($bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a -or $machine -ne $expected) { throw 'Helper PE architecture does not match the requested runtime.' }
if ($BundleDirectory) {
    New-Item -ItemType Directory -Path $BundleDirectory -Force | Out-Null
    $destination = Join-Path $BundleDirectory 'osa-screen-capture-windows.exe'
    Copy-Item -LiteralPath $helper -Destination $destination -Force
    if ((Get-FileHash -LiteralPath $destination).Hash -ne (Get-FileHash -LiteralPath $helper).Hash) { throw 'Bundled helper differs from this build.' }
}
Write-Host "Built $Runtime helper; no native desktop was accessed."
