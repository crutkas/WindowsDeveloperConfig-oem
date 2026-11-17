[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('vscode', 'uv', 'electron', 'flutter', 'react-native')]
    [string] $Workload
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\onboarding.ps1')
switch ($Workload) {
    vscode { $null = Invoke-OnboardingCommand -FilePath code.cmd -Arguments @('--version') }
    uv {
        $null = Invoke-OnboardingCommand -FilePath uv -Arguments @('--version')
        $null = Invoke-OnboardingCommand -FilePath uv -Arguments @('venv', '--help')
    }
    electron {
        $null = Assert-OnboardingNode
        $null = Invoke-OnboardingCommand -FilePath git -Arguments @('--version')
    }
    flutter {
        $null = Invoke-OnboardingCommand -FilePath flutter.bat -Arguments @('doctor', '-v')
        $devices = Invoke-OnboardingCommand -FilePath flutter.bat -Arguments @('devices', '--machine')
        if (-not @($devices | ConvertFrom-Json | Where-Object { $_.targetPlatform -eq 'windows-x64' }).Count) {
            throw 'No Windows desktop target reported by Flutter.'
        }
    }
    react-native {
        $null = Assert-OnboardingNode
        if (-not $env:ANDROID_HOME) { throw 'ANDROID_HOME is not set.' }
        Assert-OnboardingAndroidSdk -Sdk $env:ANDROID_HOME
        $null = Get-OnboardingJavaHome -Major 17 -VendorDirectory Microsoft
    }
}
Write-Output "ONBOARDING_OK: $Workload"
