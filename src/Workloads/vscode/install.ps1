[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id vscode -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @() -DeferSentinel
. (Join-Path $PSScriptRoot '..\_common\onboarding.ps1')
Invoke-OnboardingCommand -FilePath code.cmd -Arguments @('--version')
Write-Host 'INSTALL_OK: vscode'
