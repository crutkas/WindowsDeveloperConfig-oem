[CmdletBinding()]
param([switch] $IncludeEditor)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_common\onboarding.ps1')
& (Join-Path $PSScriptRoot '..\node\install.ps1')
$nodeBin = Split-Path -Parent (Get-Command node.exe -CommandType Application).Source
& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id electron -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('git') -DeferSentinel
if ($IncludeEditor) { & (Join-Path $PSScriptRoot '..\vscode\install.ps1') }
# Configuration refreshes PATH from the registry; retain a version manager's session-only selection.
$env:Path = "$nodeBin;$env:Path"
Assert-OnboardingNode
Invoke-OnboardingCommand -FilePath git -Arguments @('--version')
Write-Host 'Install Electron/Forge per project using the Electron tutorial. No global Electron or native-addon toolchain was installed.'
Write-Host 'INSTALL_OK: electron'
