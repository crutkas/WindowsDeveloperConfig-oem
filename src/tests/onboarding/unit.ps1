$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\onboarding.ps1')

& {
    function Invoke-DevConfigNativeCommand {
        param($FilePath, $Arguments)
        [pscustomobject]@{ ExitCode = 42; Output = 'download failed' }
    }
    Assert-ThrowsLike { Invoke-OnboardingCommand -FilePath example } '*failed (42)*download failed*' 'Native failures must stop the workload'
}

& {
    $script:calls = [Collections.Generic.List[string]]::new()
    $script:installed = ''
    $script:failInstall = $false
    function Invoke-OnboardingCommand {
        param($FilePath, $Arguments)
        $call = "$FilePath $($Arguments -join ' ')"
        $script:calls.Add($call)
        if ($Arguments[0] -eq 'list') { return $script:installed }
        if ($Arguments[0] -eq 'install' -and $script:failInstall) { throw 'runtime install failed' }
        return 'OK'
    }
    $null = Initialize-OnboardingPython
    Assert-Equal @($script:calls | Where-Object { $_ -eq 'pymanager install default' }).Count 1 'Fresh machines should explicitly install the default stable runtime'
    Assert-True ($script:calls -contains 'pymanager exec -m pip --version') 'Verify pip through the selected runtime, not a global pip alias'
    $script:calls.Clear()
    $script:installed = 'C:\ExistingPython\python.exe'
    $null = Initialize-OnboardingPython
    Assert-Equal @($script:calls | Where-Object { $_ -like '*install*' }).Count 0 'Existing runtimes must not be reinstalled or removed'
    Assert-Equal @($script:calls | Where-Object { $_ -notlike 'pymanager *' }).Count 0 'Never invoke a conflicting legacy py launcher'
    $script:calls.Clear()
    $script:installed = ''
    $script:failInstall = $true
    Assert-ThrowsLike { Initialize-OnboardingPython } '*runtime install failed*' 'Runtime acquisition failures must propagate'
    Assert-Equal @($script:calls | Where-Object { $_ -like '*exec*' }).Count 0 'Do not report readiness after failed runtime acquisition'
}

& {
    $script:nodeVersion = '22.11.0'
    $script:lts = 'Jod'
    function Invoke-OnboardingCommand {
        param($FilePath, $Arguments)
        if ($Arguments -contains 'process.versions.node') { return $script:nodeVersion }
        if ($Arguments -contains 'process.release.lts || ""') { return $script:lts }
        return '10.9.0'
    }
    $null = Assert-OnboardingNode
    $script:nodeVersion = '22.10.0'
    Assert-ThrowsLike { Assert-OnboardingNode } '*not a suitable LTS*' 'Reject Node below the documented React Native minimum'
    $script:nodeVersion = '27.0.0'
    $script:lts = ''
    Assert-ThrowsLike { Assert-OnboardingNode } '*not a suitable LTS*' 'Do not silently replace an existing non-LTS runtime'
}

& {
    function Get-ItemPropertyValue { return 'ARM64' }
    Assert-ThrowsLike { Assert-OnboardingArchitecture -Supported @('AMD64') } '*not ARM64*' 'Unsupported MSI/Android host architectures must fail before installation'
    Assert-Equal (Assert-OnboardingArchitecture) 'ARM64' 'Architecture-native flows should accept ARM64'
}

& {
    . (Join-Path $PSScriptRoot '..\..\windows-dev-config\steps\packages.ps1')
    $script:DevConfigAction = 'Uninstall'
    function Get-ItemPropertyValue { return 'AMD64' }
    function New-DevConfigStep { throw 'Python cleanup must not schedule an uninstall' }
    function Invoke-DevConfigSteps {
        param($Steps)
        Assert-Equal @($Steps).Count 0 'Workstation cleanup must preserve the Python manager and all existing launchers/runtimes'
    }
    Invoke-PackagesPhase -Packages @('Python')
}

$fixture = Join-Path $env:TEMP "devconfig-onboarding-$([guid]::NewGuid().ToString('N'))"
try {
    $null = New-Item -ItemType Directory -Path $fixture
    Assert-ThrowsLike { Assert-OnboardingAndroidSdk -Sdk $fixture } '*Android setup is incomplete*licenses*' 'A bare Android Studio install is not a ready SDK'
    foreach ($path in @('platform-tools\adb.exe', 'platforms\android-35\android.jar', 'build-tools\36.0.0\aapt2.exe',
        'cmdline-tools\latest\bin\sdkmanager.bat', 'licenses\android-sdk-license')) {
        $target = Join-Path $fixture $path
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
        $null = New-Item -ItemType File -Path $target
    }
    Assert-OnboardingAndroidSdk -Sdk $fixture
    Remove-Item -LiteralPath (Join-Path $fixture 'platforms\android-35\android.jar')
    Assert-ThrowsLike { Assert-OnboardingAndroidSdk -Sdk $fixture } '*platforms\android-35\android.jar*' 'Require the recommended Android platform, not just adb'

    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'bin')
    $null = New-Item -ItemType File -Path (Join-Path $fixture 'bin\java.exe'), (Join-Path $fixture 'bin\javac.exe')
    & {
        $script:jdkVersion = 'openjdk version "25" Temurin-25+36'
        function Invoke-OnboardingCommand { return $script:jdkVersion }
        Assert-ThrowsLike {
            Get-OnboardingJavaHome -Major 17 -VendorDirectory Microsoft -JavaHome $fixture
        } '*JDK 17 was not found*' 'Reject a newer JDK for React Native instead of accepting any java.exe'
        Assert-Equal (Get-OnboardingJavaHome -Major 25 -VendorDirectory 'Eclipse Adoptium' -JavaHome $fixture) $fixture 'Accept the initial Temurin 25 release without a minor version'
        $script:jdkVersion = 'openjdk version "25.0.5" Microsoft'
        Assert-ThrowsLike {
            Get-OnboardingJavaHome -Major 25 -VendorDirectory 'Eclipse Adoptium' -JavaHome $fixture
        } '*JDK 25 was not found*' 'Temurin must not be satisfied by an unrelated JDK with the same major'
    }

    & {
        $env:DEVCONFIG_TEST_ENGINE = Microsoft.PowerShell.Management\Join-Path $fixture 'engine.ps1'
        function Join-Path {
            param($Path, $ChildPath)
            if ($ChildPath -eq '..\windows-dev-config\dev-config.ps1') {
                return $env:DEVCONFIG_TEST_ENGINE
            }
            return Microsoft.PowerShell.Management\Join-Path $Path $ChildPath
        }
        $engine = Microsoft.PowerShell.Management\Join-Path $fixture 'engine.ps1'
        Set-Content -LiteralPath $engine -Value 'param($Workload, [switch]$AllowUnsigned); "$Workload/$AllowUnsigned"'
        $dispatcher = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '..\..\Workloads\install-source.ps1'
        try {
            foreach ($id in @('rust', 'dotnet', 'go', 'php')) {
                $result = & $dispatcher -Workload $id
                Assert-Equal $result "$id/True" 'The source dispatcher must call the local development engine, not the signed upstream downloader'
            }
        } finally {
            Remove-Item Env:\DEVCONFIG_TEST_ENGINE
        }
    }
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
Write-Host "PASS: onboarding ($script:AssertionCount assertions)"
