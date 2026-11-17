[CmdletBinding()]
param([string] $JavaHome = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\_common\onboarding.ps1')
$null = Assert-OnboardingArchitecture -Supported @('AMD64')
& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id temurin -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @() -DeferSentinel
$homePath = Get-OnboardingJavaHome -Major 25 -VendorDirectory 'Eclipse Adoptium' -JavaHome $JavaHome
$version = Invoke-OnboardingCommand -FilePath (Join-Path $homePath 'bin\java.exe') -Arguments @('-version')
if ($version -notmatch 'Temurin') { throw "Selected JDK is not Eclipse Temurin: $homePath" }
$env:JAVA_HOME = $homePath
$env:Path = "$homePath\bin;$env:Path"
$version
Invoke-OnboardingCommand -FilePath (Join-Path $homePath 'bin\javac.exe') -Arguments @('-version')
Write-Host 'JAVA_HOME selects Temurin in this session only. Existing JDKs were not removed.'
Write-Host 'INSTALL_OK: temurin'
