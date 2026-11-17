[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id uv -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @() -DeferSentinel
. (Join-Path $PSScriptRoot '..\_common\onboarding.ps1')
Invoke-OnboardingCommand -FilePath uv -Arguments @('--version')
Write-Host 'INSTALL_OK: uv'
