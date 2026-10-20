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
    # SetupComplete.cmd passes this. Windows removes MSIX provisioning made during OOBE when it deletes
    # its temporary OOBE account, so MSIX apps are staged and installed for each user at first sign-in.
    [switch] $PerUserApps,
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
        '_pwsh-bootstrap', 'registry-system', 'fonts', 'wsl')) {
    . (Join-Path $stepsDir "$file.ps1")
}
$Script:DevConfigAction         = 'Partial'
$Script:DevConfigWorkload       = 'devconfig'
$Script:DevConfigAllowUnsigned  = [bool]$AllowUnsigned
$Script:DevConfigWslRestartSignalled = $false

Enable-DevConfigModernTls
Start-DevConfigLog -Path (Join-Path $offlineRoot 'machine-setup-log.txt') -Append

$userScript = Join-Path $offlineRoot 'user-setup.ps1'
$userCommand = Get-DevSetupUserCommand -ScriptPath $userScript -Stage SignIn

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

$total = 6
$failure = $null
Write-Host ''
Write-Host "Calm OS machine setup (offline, Partial) -- $total phases, from $KitRoot" -ForegroundColor Cyan
Write-Host "  Kit $($manifest.KitVersion), payload $($manifest.PayloadRef), created $($manifest.CreatedUtc)" -ForegroundColor DarkGray
if ($PerUserApps) {
    Write-Host '  MSIX apps (Terminal, PowerShell 7, WinGet, ...) install for each user at first sign-in.' -ForegroundColor DarkGray
}
try {
    $packages = @{}
    foreach ($entry in @($manifest.Packages)) { $packages[$entry.Name] = $entry }

    Invoke-DevSetupPhase -Index 1 -Total $total -Title 'Getting ready' -ScriptBlock {
        Invoke-DevConfigSteps -Steps @(
            New-DevConfigStep -Name 'WinGet' -BestEffort `
                -Description (Get-DevSetupEntryDescription -Entry $manifest.WinGet -Default "Provision WinGet $($manifest.WinGet.Version) (App Installer) for all users") `
                -Check { param($Entry) Test-DevSetupEntry -Entry $Entry } `
                -Apply { param($Entry) Install-DevSetupEntry -Entry $Entry } `
                -ArgumentList @($manifest.WinGet)
            New-DevConfigStep -Name 'PowerShell7' -BestEffort `
                -Description (Get-DevSetupEntryDescription -Entry $packages['PowerShell'] -Default 'Provision PowerShell 7 for all users') `
                -Check { param($Entry) Test-DevSetupEntry -Entry $Entry } `
                -Apply { param($Entry) Install-DevSetupEntry -Entry $Entry } `
                -ArgumentList @($packages['PowerShell'])
        )
    }

    Invoke-DevSetupPhase -Index 2 -Total $total -Title 'Packages' -ScriptBlock {
        Invoke-DevConfigSteps -Steps @(foreach ($entry in @($manifest.Packages)) {
            New-DevConfigStep -Name $entry.Name -BestEffort `
                -Description (Get-DevSetupEntryDescription -Entry $entry -Default "Install $($entry.Id) $($entry.Version) from the kit") `
                -Check { param($Entry) Test-DevSetupEntry -Entry $Entry } `
                -Apply { param($Entry) Install-DevSetupEntry -Entry $Entry } `
                -ArgumentList @($entry)
        })
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

    Invoke-DevSetupPhase -Index 6 -Total $total -Title 'First sign-in' -ScriptBlock {
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

Write-DevSetupSummary -Name 'Calm OS machine setup' -Failure $failure
Save-DevSetupResult -Path (Join-Path $offlineRoot 'machine-setup-result.json') -Failure $failure
Stop-DevConfigLog

if ($failure) {
    exit 1
}
exit 0
