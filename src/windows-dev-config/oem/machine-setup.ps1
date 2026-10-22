<#
.SYNOPSIS
  Machine-wide part of the offline Windows Dev Config standard setup.

.DESCRIPTION
  Runs with no network access, as SYSTEM from SetupComplete.cmd or as an administrator in audit
  mode. It installs everything the standard setup installs for the whole PC from the kit that
  download.ps1 created, then registers user-setup.ps1 to run once at each user's first sign-in.

  It reuses the Microsoft-signed Windows Dev Config steps from the kit's payload folder, so
  settings, checks, and output match the online setup. Only downloads are replaced: packages
  come from the kit instead of WinGet. It never restarts Windows.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File C:\setup\devsetup\machine-setup.ps1
#>

[CmdletBinding()]
param(
    # Defaults to this script's folder (set below: Windows PowerShell leaves $PSScriptRoot empty in param defaults).
    [string] $KitRoot,
    # Every option passes this (SetupComplete.cmd, audit mode, the specialize pass). Windows drops
    # provisioned Store app bundles when OOBE deletes its temporary account, so MSIX apps are staged
    # and installed for each user at first sign-in.
    [switch] $PerUserApps,
    # Package names or WinGet IDs to leave out of this run, for example -Skip Python. A later run
    # without -Skip installs them, such as the specialize pass after an audit-mode run (README).
    [string[]] $Skip,
    # Development only: skips the Microsoft signature check on the payload.
    [switch] $AllowUnsigned
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"
if (-not $KitRoot) { $KitRoot = $PSScriptRoot }
# SetupComplete.cmd starts with no per-profile folders in the environment; the official steps use them.
foreach ($folder in @(@('LOCALAPPDATA', 'LocalApplicationData'), @('APPDATA', 'ApplicationData'))) {
    if (-not [Environment]::GetEnvironmentVariable($folder[0])) {
        [Environment]::SetEnvironmentVariable($folder[0], [Environment]::GetFolderPath($folder[1]))
    }
}

. (Join-Path $PSScriptRoot '_oem.ps1')

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsSystem -and
    -not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run machine-setup.ps1 as SYSTEM (SetupComplete.cmd) or from an elevated PowerShell.' -ForegroundColor Red
    exit 1
}

$KitRoot = (Resolve-Path -LiteralPath $KitRoot).Path.TrimEnd('\')
$manifest = Read-DevSetupManifest -Root $KitRoot
$payload = Join-Path $KitRoot 'payload'

# powershell.exe -File passes "-Skip A,B" as one string.
$Skip = @($Skip | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$skipped = @($manifest.Packages | Where-Object { $_.Name -in $Skip -or $_.Id -in $Skip })
$skippedNames = @($skipped | ForEach-Object { $_.Name })
$unknown = @($Skip | Where-Object { $_ -notin @($manifest.Packages.Name) -and $_ -notin @($manifest.Packages.Id) })
if ($unknown.Count -gt 0) {
    Write-Host "-Skip: $($unknown -join ', ') is not a package in the kit. Use one of: $(@($manifest.Packages.Name) -join ', ')." -ForegroundColor Red
    exit 1
}

# The kit runs as SYSTEM and seeds every user's sign-in, so lock it down before trusting its contents.
# Its parent (C:\setup) is locked too: under C:\ any user could otherwise rename it and swap the kit.
$kitParent = Split-Path -Parent $KitRoot
if ($kitParent -and $kitParent -notmatch '^[A-Za-z]:\\?$') {
    Protect-DevSetupDirectory -Path $kitParent
} else {
    Protect-DevSetupDirectory -Path $KitRoot
}

$securityCode = [IO.File]::ReadAllText((Join-Path $payload 'steps\_security.ps1'))
if (-not $AllowUnsigned) {
    $signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($securityCode)) -SourcePathOrExtension '.ps1'
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
        Write-Host 'The kit payload failed Microsoft signature verification. Download the kit again.' -ForegroundColor Red
        exit 1
    }
}
. ([scriptblock]::Create($securityCode))
# Same check the online bootstrap applies to its install folder: the kit and every parent must be admin-only.
Assert-DevConfigProtectedTree -Directory $KitRoot

# Same install location and layout as the online bootstrap, so a later online run reuses it.
$installRoot = New-DevConfigProtectedDirectory -Path $Script:DevSetupInstallRoot
$offlineRoot = New-DevConfigProtectedDirectory -Path $Script:DevSetupOfflineRoot
$logs = Join-Path $offlineRoot 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
foreach ($item in @('bootstrap.ps1', 'dev-config.ps1')) {
    Copy-Item -LiteralPath (Join-Path $payload $item) -Destination $installRoot -Force
}
foreach ($folder in @('steps', 'workloads')) {
    Copy-Item -LiteralPath (Join-Path $payload $folder) -Destination $installRoot -Recurse -Force
}
Assert-DevConfigProtectedTree -Directory $installRoot
if (-not $AllowUnsigned) {
    Assert-DevConfigMicrosoftSigned -Directory $installRoot
}

$stepsDir = Join-Path $installRoot 'steps'
foreach ($file in @('_console', '_step-runner', '_elevation', '_registry', '_environment', '_retry', '_terminal',
        '_pwsh-bootstrap', 'packages', 'registry-system', 'registry-explorer', 'registry-taskbar-search', 'fonts',
        'terminal', 'powershell-profile', 'wsl')) {
    . (Join-Path $stepsDir "$file.ps1")
}
$Script:DevConfigAction         = 'Partial'
$Script:DevConfigWorkload       = 'devconfig'
$Script:DevConfigAllowUnsigned  = [bool]$AllowUnsigned
$Script:DevConfigWslRestartSignalled = $false

# While the Default user profile is loaded, the official HKCU settings are written to it instead,
# so every account Windows creates from it (including the one made in OOBE) starts with them.
$Script:DevSetupHkcuRoot = $null
function Convert-DevConfigRegistryPath {
    param(
        [Parameter(Mandatory)] [string] $KeyPath
    )
    if ($Script:DevSetupHkcuRoot -and $KeyPath -match '^HKCU\\') {
        return "Registry::$Script:DevSetupHkcuRoot\$($KeyPath.Substring(5))"
    }
    return $KeyPath -replace '^(HKCU|HKLM|HKCR|HKU|HKCC)\\', '$1:\'
}

Enable-DevConfigModernTls
Start-DevConfigLog -Path (Join-Path $offlineRoot 'machine-setup-log.txt') -Append

$userScript = Join-Path $offlineRoot 'user-setup.ps1'
$userCommand = Get-DevSetupUserCommand -ScriptPath $userScript
$defaultProfile = [Environment]::ExpandEnvironmentVariables(
    (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList').Default)
$defaultHive = 'HKEY_USERS\CalmOS-DefaultUser'
$defaultPwshProfile = Join-Path $defaultProfile 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'

function Invoke-DevSetupDefaultUser {
    param([Parameter(Mandatory)] [scriptblock] $ScriptBlock)
    $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
    $output = & $reg load $defaultHive (Join-Path $defaultProfile 'NTUSER.DAT') 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not load the Default user profile: $($output | Out-String)" }
    $Script:DevSetupHkcuRoot = $defaultHive
    try {
        & $ScriptBlock
    } finally {
        $Script:DevSetupHkcuRoot = $null
        # Open registry handles block the unload until they are collected.
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            $output = & $reg unload $defaultHive 2>&1
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 1
        }
        if ($LASTEXITCODE -ne 0) { Write-Host "  Could not unload the Default user profile: $($output | Out-String)" -ForegroundColor Yellow }
    }
}

function Test-DevSetupDefaultPwshProfile {
    $content = [string](Read-DevConfigTextFile -Path $defaultPwshProfile) -replace "`r`n", "`n"
    return $content.Contains((Get-DevConfigOhMyPoshProfileBlock))
}

function Set-DevSetupDefaultPwshProfile {
    $content = [string](Read-DevConfigTextFile -Path $defaultPwshProfile) -replace "`r`n", "`n"
    if ($content -and -not $content.EndsWith("`n")) { $content += "`n" }
    Write-DevConfigTextFile -Path $defaultPwshProfile -Content ($content + (Get-DevConfigOhMyPoshProfileBlock))
}

# Same install as the official CascadiaFonts step, from the kit's copy of the pinned release.
function Install-DevSetupCascadiaFonts {
    $zipPath = Join-Path $KitRoot $manifest.Fonts.File
    if ((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash -ne $Script:CascadiaZipSha256) {
        throw "The kit's Cascadia Code archive failed its SHA-256 check: $zipPath"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.Drawing
    $fontsDir = Join-Path $env:SystemRoot 'Fonts'
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($name in $Script:CascadiaWantedFonts) {
            $entry = $zip.Entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $entry) { throw "$name is not in $zipPath." }
            $destination = Join-Path $fontsDir $name
            Expand-DevConfigFontEntry -Entry $entry -Path $destination
            $collection = New-Object System.Drawing.Text.PrivateFontCollection
            try {
                $collection.AddFontFile($destination)
                $family = $collection.Families[0].Name
            } finally {
                $collection.Dispose()
            }
            $registryName = "$family (TrueType)"
            New-ItemProperty -Path $Script:CascadiaFontRegPath -Name $registryName -Value $name -PropertyType String -Force | Out-Null
            Remove-DevConfigStalePerUserFont -FileName $name -RegName $registryName
            Write-Host "  Installed $name as '$registryName'"
        }
    } finally {
        $zip.Dispose()
    }
}

function Test-DevSetupWslFeaturesOn {
    foreach ($feature in @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction Stop).State
        if ([string]$state -notin @('Enabled', 'EnablePending')) { return $false }
    }
    return $true
}

function Install-DevSetupWslComponents {
    if (-not (Test-DevSetupWslFeaturesOn)) {
        Enable-DevConfigWslFeatures
    }
    if (-not (Test-DevSetupPackageInstalled -Entry $manifest.Wsl)) {
        Install-DevSetupPackage -Entry $manifest.Wsl -Root $KitRoot -LogDirectory $logs
    }
    if ($Script:DevConfigWslRestartSignalled -or (Test-DevConfigServicingRebootPending)) {
        Add-DevConfigNote -Warning -Message 'WSL needs one restart before Ubuntu can start. Turn the WSL features on in the image (see README) to avoid it.'
    }
}

function Get-DevSetupUserFiles {
    @('user-setup.ps1', '_oem.ps1', $Script:DevSetupManifestName) + @($manifest.UserFiles)
}

function Test-DevSetupUserFilesCurrent {
    foreach ($relative in Get-DevSetupUserFiles) {
        $source = Join-Path $KitRoot $relative
        $target = Join-Path $offlineRoot $relative
        if (-not (Test-Path -LiteralPath $target)) { return $false }
        if ((Get-Item -LiteralPath $source).PSIsContainer) { continue }
        if ((Get-Item -LiteralPath $source).Length -ne (Get-Item -LiteralPath $target).Length) { return $false }
        if ($relative -like '*.ps1' -or $relative -like '*.json') {
            if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { return $false }
        }
    }
    return $true
}

function Copy-DevSetupUserFiles {
    foreach ($relative in Get-DevSetupUserFiles) {
        $source = Join-Path $KitRoot $relative
        $target = Join-Path $offlineRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
    }
    Assert-DevConfigProtectedTree -Directory $offlineRoot
}

function Get-DevSetupEntryFiles {
    param([Parameter(Mandatory)] $Entry)
    @($Entry.File) + @($Entry.Dependencies | Where-Object { $_ })
}

function Test-DevSetupEntryStaged {
    param([Parameter(Mandatory)] $Entry)
    foreach ($relative in Get-DevSetupEntryFiles -Entry $Entry) {
        $target = Join-Path $offlineRoot $relative
        if (-not (Test-Path -LiteralPath $target)) { return $false }
        if ((Get-Item -LiteralPath $target).Length -ne (Get-Item -LiteralPath (Join-Path $KitRoot $relative)).Length) { return $false }
    }
    return $true
}

function Copy-DevSetupEntryFiles {
    param([Parameter(Mandatory)] $Entry)
    $file = Join-Path $KitRoot $Entry.File
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $Entry.Sha256) {
        throw "The offline installer failed its SHA-256 check: $file. Download the kit again."
    }
    foreach ($relative in Get-DevSetupEntryFiles -Entry $Entry) {
        $target = Join-Path $offlineRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $KitRoot $relative) -Destination $target -Force
    }
}

# MSIX apps are provisioned for all users, or with -PerUserApps staged for user-setup.ps1 to install.
function Test-DevSetupEntry {
    param([Parameter(Mandatory)] $Entry)
    if ($PerUserApps -and $Entry.Kind -eq 'msix') { return (Test-DevSetupEntryStaged -Entry $Entry) }
    return (Test-DevSetupPackageInstalled -Entry $Entry)
}

function Install-DevSetupEntry {
    param([Parameter(Mandatory)] $Entry)
    if ($PerUserApps -and $Entry.Kind -eq 'msix') {
        Copy-DevSetupEntryFiles -Entry $Entry
        return
    }
    Install-DevSetupPackage -Entry $Entry -Root $KitRoot -LogDirectory $logs
}

function Get-DevSetupEntryDescription {
    param([Parameter(Mandatory)] $Entry, [Parameter(Mandatory)] [string] $Default)
    if ($PerUserApps -and $Entry.Kind -eq 'msix') { return "Stage $($Entry.Id) $($Entry.Version) to install at each user's first sign-in" }
    return $Default
}

# Sysprep /generalize fails (0x80073cf2) on any app registered for a user but not provisioned. The
# PowerToys installer registers Command Palette for the account that runs it; PowerToys registers
# it again for each user when it starts, so in audit mode those registrations are removed.
$inAuditMode = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction SilentlyContinue).ImageState -eq 'IMAGE_STATE_SPECIALIZE_RESEAL_TO_AUDIT'
function Get-DevSetupSysprepBlockers {
    $provisioned = @(Get-AppxProvisionedPackage -Online | ForEach-Object { $_.DisplayName })
    @(Get-AppxPackage -AllUsers | Where-Object {
        ($_.Name -eq 'Microsoft.CommandPalette' -or $_.Name -like 'Microsoft.PowerToys.*') -and
            $provisioned -notcontains $_.Name -and @($_.PackageUserInformation | Where-Object { $_.InstallState -eq 'Installed' }).Count -gt 0
    })
}

$total = 7
$failure = $null
Write-Host ''
Write-Host "Calm OS machine setup (offline, Partial) -- $total phases, from $KitRoot" -ForegroundColor Cyan
Write-Host "  Kit $($manifest.KitVersion), payload $($manifest.PayloadRef), created $($manifest.CreatedUtc)" -ForegroundColor DarkGray
if ($PerUserApps) {
    Write-Host '  MSIX apps (Terminal, PowerShell 7, WinGet, ...) install for each user at first sign-in.' -ForegroundColor DarkGray
}
if ($skippedNames.Count -gt 0) {
    Write-Host "  Skipping $($skippedNames -join ', ') in this run (-Skip). Run machine-setup.ps1 again without -Skip to install them." -ForegroundColor DarkGray
}
try {
    $packages = @{}
    foreach ($entry in @($manifest.Packages)) { $packages[$entry.Name] = $entry }
    $included = @($manifest.Packages | Where-Object { $_.Name -notin $skippedNames })

    Invoke-DevSetupPhase -Index 1 -Total $total -Title 'Getting ready' -ScriptBlock {
        Invoke-DevConfigSteps -Steps @(
            New-DevConfigStep -Name 'WinGet' -BestEffort `
                -Description (Get-DevSetupEntryDescription -Entry $manifest.WinGet -Default "Provision WinGet $($manifest.WinGet.Version) (App Installer) for all users") `
                -Check { param($Entry) Test-DevSetupEntry -Entry $Entry } `
                -Apply { param($Entry) Install-DevSetupEntry -Entry $Entry } `
                -ArgumentList @($manifest.WinGet)
            if ('PowerShell' -notin $skippedNames) {
                New-DevConfigStep -Name 'PowerShell7' -BestEffort `
                    -Description (Get-DevSetupEntryDescription -Entry $packages['PowerShell'] -Default 'Provision PowerShell 7 for all users') `
                    -Check { param($Entry) Test-DevSetupEntry -Entry $Entry } `
                    -Apply { param($Entry) Install-DevSetupEntry -Entry $Entry } `
                    -ArgumentList @($packages['PowerShell'])
            }
        )
    }

    Invoke-DevSetupPhase -Index 2 -Total $total -Title 'Packages' -ScriptBlock {
        Invoke-DevConfigSteps -Steps @(
            foreach ($entry in $included) {
                New-DevConfigStep -Name $entry.Name -BestEffort `
                    -Description (Get-DevSetupEntryDescription -Entry $entry -Default "Install $($entry.Id) $($entry.Version) from the kit") `
                    -Check { param($Entry) Test-DevSetupEntry -Entry $Entry } `
                    -Apply { param($Entry) Install-DevSetupEntry -Entry $Entry } `
                    -ArgumentList @($entry)
            }
            if ($inAuditMode) {
                New-DevConfigStep -Name 'SysprepReady' -BestEffort `
                    -Description 'Remove PowerToys app registrations that would stop sysprep (PowerToys adds them again for each user)' `
                    -Check { @(Get-DevSetupSysprepBlockers).Count -eq 0 } `
                    -Apply { Get-DevSetupSysprepBlockers | ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -AllUsers } }
            }
        )
    }

    Invoke-DevSetupPhase -Index 3 -Total $total -Title 'System settings' -ScriptBlock { Invoke-RegistrySystemPhase }

    Invoke-DevSetupPhase -Index 4 -Total $total -Title 'Fonts' -ScriptBlock {
        Invoke-DevConfigSteps -Steps @(
            New-DevConfigStep -Name 'CascadiaFonts' -Description 'Install Cascadia Code Nerd Fonts from the kit' -BestEffort `
                -Check { Test-DevConfigCascadiaFontsInstalled } `
                -Apply { Install-DevSetupCascadiaFonts }
        )
    }

    Invoke-DevSetupPhase -Index 5 -Total $total -Title 'WSL' -ScriptBlock {
        Invoke-DevConfigSteps -Steps @(
            New-DevConfigStep -Name 'WslComponents' -Description "Turn on WSL and install WSL $($manifest.Wsl.Version) from the kit" -BestEffort `
                -Check { (Test-DevSetupWslFeaturesOn) -and (Test-DevSetupPackageInstalled -Entry $manifest.Wsl) } `
                -Apply { Install-DevSetupWslComponents }
        )
    }

    # The user's own File Explorer, Start, theme, and prompt settings, applied before OOBE creates the account.
    Invoke-DevSetupPhase -Index 6 -Total $total -Title 'Settings for new users' -ScriptBlock {
        Invoke-DevSetupDefaultUser -ScriptBlock {
            $packageSettings = @(foreach ($package in @(Get-DevConfigPackage -Name @($manifest.Packages | ForEach-Object { $_.Name }))) {
                if ($package['Settings']) { $package['Settings'] }
            })
            Invoke-RegistryExplorerPhase
            Invoke-RegistryTaskbarSearchPhase
            Invoke-DevConfigSteps -Steps @(
                New-DevConfigStep -Name 'DarkTheme' -Description 'Force dark app/system theme' -BestEffort `
                    -Check { Test-DevConfigDarkThemeSet } `
                    -Apply { Set-DevConfigDarkTheme }
                New-DevConfigStep -Name 'OhMyPoshProfile' -Description 'Add Oh My Posh init to the PowerShell 7 profile' -BestEffort `
                    -Check { Test-DevSetupDefaultPwshProfile } `
                    -Apply { Set-DevSetupDefaultPwshProfile }
                $wslFirstRun = $Script:DevConfigWslFirstRunSetting.Clone()
                $wslFirstRun.Description = 'Skip the WSL welcome window'
                New-DevConfigRegistryStep -Setting $wslFirstRun
                foreach ($setting in $packageSettings) {
                    New-DevConfigRegistryStep -Setting $setting
                }
            )
        }
    }

    Invoke-DevSetupPhase -Index 7 -Total $total -Title 'First sign-in' -ScriptBlock {
        Invoke-DevConfigSteps -Steps @(
            New-DevConfigStep -Name 'UserSetupFiles' -Description "Stage per-user setup files in $offlineRoot" `
                -Check { Test-DevSetupUserFilesCurrent } `
                -Apply { Copy-DevSetupUserFiles }
            New-DevConfigStep -Name 'UserSetupAtSignIn' -Description 'Run the per-user setup once at each first sign-in (Active Setup)' `
                -Check { Test-DevSetupActiveSetup -Command $userCommand } `
                -Apply { Register-DevSetupActiveSetup -Command $userCommand }
        )
    }
} catch {
    $failure = $_
}

# Flagged or failed steps run again, as SYSTEM at each startup, until they pass (up to three times).
$retryArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden',
    '-File', "`"$PSCommandPath`"", '-KitRoot', "`"$KitRoot`"")
if ($PerUserApps) { $retryArguments += '-PerUserApps' }
if ($skippedNames.Count -gt 0) { $retryArguments += @('-Skip', ($skippedNames -join ',')) }
if ($AllowUnsigned) { $retryArguments += '-AllowUnsigned' }
try {
    $retry = Update-DevSetupMachineRetry -Needed:([bool]$failure -or $Script:DevConfigTally.Warned -gt 0) -Arguments ($retryArguments -join ' ')
    if ($retry) {
        Add-DevConfigNote -Message 'The flagged steps run again automatically, hidden, at the next startup.'
    }
} catch {
    Write-Host "  Could not schedule the retry: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-DevSetupSummary -Name 'Calm OS machine setup' -Failure $failure
Save-DevSetupResult -Path (Join-Path $offlineRoot 'machine-setup-result.json') -Failure $failure
Stop-DevConfigLog

if ($failure) {
    exit 1
}
exit 0
