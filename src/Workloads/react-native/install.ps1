[CmdletBinding()]
param(
    [string] $AndroidSdk = $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }),
    [string] $JavaHome = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\_common\onboarding.ps1')
$null = Assert-OnboardingArchitecture -Supported @('AMD64')
& (Join-Path $PSScriptRoot '..\node\install.ps1')
$nodeBin = Split-Path -Parent (Get-Command node.exe -CommandType Application).Source
& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id react-native -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @() -DeferSentinel
$env:JAVA_HOME = Get-OnboardingJavaHome -Major 17 -VendorDirectory Microsoft -JavaHome $JavaHome
$env:Path = "$nodeBin;$env:JAVA_HOME\bin;$env:Path"
Assert-OnboardingNode
Assert-OnboardingAndroidSdk -Sdk $AndroidSdk
$env:ANDROID_HOME = (Resolve-Path -LiteralPath $AndroidSdk).Path
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $env:ANDROID_HOME, 'User')
$platformTools = Join-Path $env:ANDROID_HOME 'platform-tools'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($platformTools -notin @($userPath -split ';')) {
    [Environment]::SetEnvironmentVariable('Path', (@($userPath, $platformTools) | Where-Object { $_ }) -join ';', 'User')
}
$env:Path = "$platformTools;$env:Path"
Invoke-OnboardingCommand -FilePath (Join-Path $platformTools 'adb.exe') -Arguments @('version')
Write-Host 'Android prerequisites ready. JAVA_HOME selects JDK17 in this session only.'
Write-Host 'Use the project-local React Native CLI. Connect an Android device or create an API35 AVD in Android Studio.'
Write-Host 'No global React Native CLI, iOS tools, Windows target, or virtualization feature was installed.'
Write-Host 'INSTALL_OK: react-native'
