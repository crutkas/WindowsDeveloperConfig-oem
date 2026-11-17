<#
.SYNOPSIS
  Apply the Python winget DSC configuration on Windows.

.DESCRIPTION
  Installs the Python install manager, inventories existing runtimes, and installs
  the manager's default stable runtime only when none exists. Existing Python,
  launchers, PATH selections, and virtual environments are not removed. uv is an
  optional separate workload. Uses pymanager to avoid legacy py.exe conflicts.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id              'python' `
    -ConfigFile      (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @() `
    -DeferSentinel

. (Join-Path $PSScriptRoot '..\_common\onboarding.ps1')
Initialize-OnboardingPython
Write-Host 'Use pymanager exec -m venv .venv for a project environment; activate .\.venv\Scripts\Activate.ps1.'
Write-Host 'If python or py selects an older installation, review PATH and App execution aliases; setup does not remove them.'
Write-Host 'INSTALL_OK: python'
