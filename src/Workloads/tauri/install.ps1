[CmdletBinding()]
param([switch] $IncludeNode)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\_common\onboarding.ps1')
$architecture = Assert-OnboardingArchitecture
. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
Assert-AiAdministrator

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id tauri -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @() -DeferSentinel
$target = if ($architecture -eq 'ARM64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
Ensure-AiVisualCppTools -Architecture $(if ($architecture -eq 'ARM64') { 'Arm64' } else { 'X64' })
$env:Path = "$(Join-Path $env:USERPROFILE '.cargo\bin');$env:Path"
Invoke-OnboardingCommand -FilePath rustup -Arguments @('toolchain', 'install', "stable-$target", '--profile', 'minimal')
# Session-only selection; never change an existing user's rustup default.
$env:RUSTUP_TOOLCHAIN = "stable-$target"
Invoke-OnboardingCommand -FilePath rustc -Arguments @('--version')
Invoke-OnboardingCommand -FilePath cargo -Arguments @('--version')
if ($IncludeNode) { & (Join-Path $PSScriptRoot '..\node\install.ps1') }
Write-Host 'Tauri prerequisites ready. Add Tauri to your project, not globally. Node is optional (-IncludeNode).'
Write-Host 'MSI bundling may additionally require the optional VBScript Windows feature; this workload does not enable it.'
Write-Host 'INSTALL_OK: tauri'
