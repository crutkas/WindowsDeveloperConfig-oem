<#
.SYNOPSIS
  Uninstalls a setup bundle, such as Python, that the offline setup lists in Installed apps for all users.

.DESCRIPTION
  Some installers (Python's) record their Installed apps entry only for the account that ran them,
  which is SYSTEM when machine-setup.ps1 installs them. machine-setup.ps1 moves that entry to the
  machine-wide list, with a copy of the bundle under C:\ProgramData\CalmOS-Offline\uninstall, and
  points it here. This script asks for administrator rights, runs the bundle's own uninstaller, and
  when that succeeds removes the machine-wide entry and the copy.

.EXAMPLE
  powershell.exe -NoProfile -File C:\ProgramData\CalmOS-Offline\uninstall-package.ps1 -ProductCode '{97b6de30-6082-48d1-9bb4-9f43296531a4}'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$')] [string] $ProductCode,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden',
        '-File', "`"$PSCommandPath`"", '-ProductCode', $ProductCode)
    if ($Quiet) { $arguments += '-Quiet' }
    try {
        $elevated = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    } catch {
        # The administrator prompt was declined.
        exit 1602
    }
    exit $elevated.ExitCode
}

$key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
$folder = Join-Path $PSScriptRoot "uninstall\$ProductCode"
$bundle = Get-ChildItem -LiteralPath $folder -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $bundle) {
    Write-Host "The uninstaller for $ProductCode is missing from $folder." -ForegroundColor Red
    exit 1
}
$process = Start-Process -FilePath $bundle.FullName -ArgumentList $(if ($Quiet) { '/uninstall /quiet' } else { '/uninstall' }) -Wait -PassThru
if ($process.ExitCode -in @(0, 1641, 3010)) {
    Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}
exit $process.ExitCode
