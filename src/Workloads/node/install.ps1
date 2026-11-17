[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\_common\onboarding.ps1')
$null = Assert-OnboardingArchitecture

if (Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue) {
    Write-Host 'Keeping the existing Node installation; checking it instead of replacing it.'
} else {
    $manager = Get-Command nvm.exe, fnm.exe, volta.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($manager -or $env:NVM_HOME -or $env:VOLTA_HOME -or $env:FNM_DIR) {
        throw 'A Node version manager is configured. Activate a supported LTS runtime in it, then rerun; setup will not install a competing MSI.'
    }
    & (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
        -Id node -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
        -RequireCommands @('node', 'npm.cmd') -DeferSentinel
}
Assert-OnboardingNode
Write-Host 'INSTALL_OK: node'
