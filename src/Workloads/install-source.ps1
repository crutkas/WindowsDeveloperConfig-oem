<#
.SYNOPSIS
  Run reviewed local source without downloading the signed upstream bootstrap.
.DESCRIPTION
  Development preview only. Review this checkout first. This deliberately uses
  the engine's existing -AllowUnsigned development mode, not a release signature.
  It does not change execution policy or fall back to upstream script payloads.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('node', 'python', 'rust', 'vscode', 'dotnet', 'go', 'php', 'uv',
        'pytorch', 'tauri', 'flutter', 'electron', 'temurin', 'react-native')]
    [string] $Workload
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Workload -in @('rust', 'dotnet', 'go', 'php')) {
    & (Join-Path $PSScriptRoot '..\windows-dev-config\dev-config.ps1') -Workload $Workload -AllowUnsigned
} else {
    & (Join-Path $PSScriptRoot "$Workload\install.ps1")
}
