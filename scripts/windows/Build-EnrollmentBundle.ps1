[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReleaseTag, [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
if ($ReleaseTag -notmatch '\Av[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?\z') { throw 'A release tag is required.' }
$stage = Join-Path ([IO.Path]::GetTempPath()) ('osa-enrollment-bundle-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    foreach ($name in @('Install-OpenComputer.ps1','Run-OpenComputer.ps1','OpenComputerHost.psm1','WindowsHostPlatform.psm1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $stage
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../install.ps1') -Destination (Join-Path $stage 'install-runtime.ps1')
    [IO.File]::WriteAllText((Join-Path $stage 'RELEASE_TAG'), $ReleaseTag, [Text.Encoding]::ASCII)
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath (Join-Path $OutputDirectory 'osa-opencomputers-windows.zip') -Force
} finally {
    # Only this build's freshly created, explicit staging directory is removed.
    Remove-Item -LiteralPath $stage -Recurse -Force
}
