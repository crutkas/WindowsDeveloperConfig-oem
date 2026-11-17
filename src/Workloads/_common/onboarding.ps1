$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\..\windows-dev-config\steps\_environment.ps1')

function Invoke-OnboardingCommand {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @()
    )
    $result = Invoke-DevConfigNativeCommand -FilePath $FilePath -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "$FilePath $($Arguments -join ' ') failed ($($result.ExitCode)): $($result.Output)"
    }
    return ([string]$result.Output).Trim()
}

function Assert-OnboardingArchitecture {
    param([string[]] $Supported = @('AMD64', 'ARM64'))
    $architecture = Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE
    if ($architecture -notin $Supported) {
        throw "This workload supports Windows $($Supported -join ', '), not $architecture."
    }
    return $architecture
}

function Assert-OnboardingNode {
    $version = Invoke-OnboardingCommand -FilePath node -Arguments @('-p', 'process.versions.node')
    $lts = Invoke-OnboardingCommand -FilePath node -Arguments @('-p', 'process.release.lts || ""')
    if ([version]$version -lt [version]'22.11.0' -or -not $lts) {
        throw "Node $version is not a suitable LTS runtime (minimum 22.11.0). Select a supported LTS in your existing version manager, then rerun. No existing runtime was removed."
    }
    Invoke-OnboardingCommand -FilePath npm.cmd -Arguments @('--version')
}

function Initialize-OnboardingPython {
    # pymanager is unambiguous even when the legacy launcher owns py.exe.
    $runtimes = Invoke-OnboardingCommand -FilePath pymanager -Arguments @('list', '--format=exe')
    if (-not $runtimes) {
        Invoke-OnboardingCommand -FilePath pymanager -Arguments @('install', 'default')
    } else {
        Write-Host "Keeping existing Python runtimes:`n$runtimes"
    }
    Invoke-OnboardingCommand -FilePath pymanager -Arguments @('exec', '-c', 'import sys, venv; print(sys.executable); print(sys.version)')
    Invoke-OnboardingCommand -FilePath pymanager -Arguments @('exec', '-m', 'pip', '--version')
}

function Get-OnboardingJavaHome {
    param(
        [Parameter(Mandatory)] [int] $Major,
        [Parameter(Mandatory)] [string] $VendorDirectory,
        [string] $JavaHome = ''
    )
    $candidates = if ($JavaHome) {
        @($JavaHome)
    } else {
        @(
            if ($env:JAVA_HOME) { $env:JAVA_HOME }
            $vendorPath = Join-Path $env:ProgramFiles $VendorDirectory
            if (Test-Path -LiteralPath $vendorPath) {
                Get-ChildItem -LiteralPath $vendorPath -Directory |
                    Sort-Object Name -Descending | Select-Object -ExpandProperty FullName
            }
        )
    }
    foreach ($candidate in $candidates) {
        $java = Join-Path $candidate 'bin\java.exe'
        $javac = Join-Path $candidate 'bin\javac.exe'
        if ((Test-Path -LiteralPath $java) -and (Test-Path -LiteralPath $javac)) {
            $version = Invoke-OnboardingCommand -FilePath $java -Arguments @('-version')
            if ($version -match ('version "' + $Major + '(?:\.|")') -and
                ($VendorDirectory -ne 'Eclipse Adoptium' -or $version -match 'Temurin')) {
                return $candidate
            }
        }
    }
    throw "JDK $Major was not found. Rerun with -JavaHome pointing to a JDK $Major installation; existing JDKs were not removed."
}

function Assert-OnboardingAndroidSdk {
    param([Parameter(Mandatory)] [string] $Sdk)
    $required = @(
        'platform-tools\adb.exe'
        'platforms\android-35\android.jar'
        'build-tools\36.0.0\aapt2.exe'
        'cmdline-tools\latest\bin\sdkmanager.bat'
        'licenses\android-sdk-license'
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Sdk $_)) })
    if ($missing.Count) {
        throw @"
Android setup is incomplete at '$Sdk': $($missing -join ', ').
Open Android Studio and finish its setup wizard. In SDK Manager install Android SDK Platform 35,
Build-Tools 36.0.0, Platform-Tools and Command-line Tools (latest). Review and accept Google's
SDK licenses yourself (sdkmanager --licenses). Rerun this workload with -AndroidSdk '<SDK path>'.
No SDK licenses were automatically accepted, and no emulator or OS virtualization feature was installed.
"@
    }
}
