[CmdletBinding()]
param([string] $SdkRoot = (Join-Path $env:USERPROFILE 'develop\flutter'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\_common\onboarding.ps1')
$null = Assert-OnboardingArchitecture -Supported @('AMD64')
if ($SdkRoot -match '\s') {
    throw 'Choose -SdkRoot without spaces, outside Program Files, in a directory your account can write.'
}
$flutter = Get-Command flutter.bat -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $flutter -and (Test-Path -LiteralPath $SdkRoot) -and
    -not (Test-Path -LiteralPath (Join-Path $SdkRoot 'bin\flutter.bat'))) {
    throw "The SDK destination already exists but is not a Flutter SDK: $SdkRoot. Choose another -SdkRoot; nothing was removed."
}
. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
Assert-AiAdministrator
& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id flutter -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('git') -DeferSentinel

. (Join-Path $PSScriptRoot '..\..\windows-dev-config\steps\visual-studio.ps1')
$components = @(
    'Microsoft.VisualStudio.Workload.NativeDesktop'
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
    'Microsoft.VisualStudio.Component.VC.CMake.Project'
    'Microsoft.VisualStudio.Component.Windows11SDK.26100'
)
if (-not (Test-DevConfigVisualStudioComponents -Components $components)) {
    Add-DevConfigVisualStudioComponents -Components $components
}
if (-not (Test-DevConfigVisualStudioComponents -Components $components)) {
    throw 'Visual Studio C++ components are not ready. Finish any requested reboot or repair in Visual Studio Installer, then rerun.'
}

if ($flutter) {
    $flutterPath = $flutter.Source
    Write-Host "Keeping existing Flutter SDK: $flutterPath"
} else {
    if (-not (Test-Path -LiteralPath (Join-Path $SdkRoot 'bin\flutter.bat'))) {
        $parent = Split-Path -Parent $SdkRoot
        $null = New-Item -ItemType Directory -Path $parent -Force
        # Official stable source distribution; Flutter itself downloads its matching Dart/engine artifacts.
        Invoke-OnboardingCommand -FilePath git -Arguments @('clone', '--branch', 'stable', '--single-branch', 'https://github.com/flutter/flutter.git', $SdkRoot)
    }
    $flutterPath = Join-Path $SdkRoot 'bin\flutter.bat'
}
$bin = Split-Path -Parent $flutterPath
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($bin -notin @($userPath -split ';')) {
    [Environment]::SetEnvironmentVariable('Path', (@($userPath, $bin) | Where-Object { $_ }) -join ';', 'User')
}
$env:Path = "$bin;$env:Path"
Invoke-OnboardingCommand -FilePath $flutterPath -Arguments @('--version')
Invoke-OnboardingCommand -FilePath $flutterPath -Arguments @('doctor', '-v')
$devices = Invoke-OnboardingCommand -FilePath $flutterPath -Arguments @('devices', '--machine')
if (-not @($devices | ConvertFrom-Json | Where-Object { $_.targetPlatform -eq 'windows-x64' }).Count) {
    throw 'Flutter did not report a Windows desktop device. Resolve the Windows/Visual Studio sections in flutter doctor -v, then rerun.'
}
Write-Host 'Windows prerequisites ready. Android/web doctor warnings are outside this Windows-only workload.'
Write-Host 'INSTALL_OK: flutter'
