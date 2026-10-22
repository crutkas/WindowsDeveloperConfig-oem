<#
.SYNOPSIS
  Downloads everything the standard Windows Dev Config setup installs, so a PC can be set up offline.

.DESCRIPTION
  Run this once on an internet-connected Windows PC that has WinGet 1.8 or later. It reads the
  current standard setup (https://aka.ms/devconfig/standard/setup.ps1), takes the exact
  Microsoft-signed payload that setup pins, and saves into -Destination:

    payload\    the signed Windows Dev Config scripts (same files the online setup runs)
    packages\   every standard WinGet package, downloaded with `winget download`
    winget\     the pinned App Installer (WinGet) release
    fonts\      Cascadia Code Nerd Fonts
    wsl\        the WSL MSI and the default Ubuntu image (.wsl)
    copilot\    the Copilot Terminal icon and an offline copy of the win-dev-skills marketplace
    devsetup.json, machine-setup.ps1, user-setup.ps1, SetupComplete.cmd, README.md

  Copy the whole folder to C:\setup\devsetup in the Windows image. No network access is needed
  after this point. See README.md for the full OEM flow.

.EXAMPLE
  .\download.ps1

.EXAMPLE
  .\download.ps1 -Destination D:\kits\devsetup -Architecture arm64

.EXAMPLE
  .\download.ps1 -List
  Shows every item in an existing kit with its version, source, and size (also printed at the end of a download).
#>

[CmdletBinding()]
param(
    [string] $Destination = 'C:\setup\devsetup',
    [ValidateSet('x64', 'arm64')] [string] $Architecture = 'x64',
    # Normally read from the standard launcher so the kit matches what the online setup runs today.
    [ValidatePattern('^[0-9a-f]{40}$')] [string] $PayloadRef,
    [string] $StandardLauncherUri = 'https://aka.ms/devconfig/standard/setup.ps1',
    # Lists what an existing kit in -Destination contains, without downloading anything.
    [switch] $List
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

. (Join-Path $PSScriptRoot '_oem.ps1')
. (Join-Path $PSScriptRoot '_oem-download.ps1')

$Script:MicrosoftSigner = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
$Script:Repository      = 'microsoft/WindowsDeveloperConfig'
$Script:KitFiles        = @('_oem.ps1', 'machine-setup.ps1', 'user-setup.ps1', 'uninstall-package.ps1', 'SetupComplete.cmd', 'README.md')

# Installer switches the WinGet manifest does not carry but an unattended machine-wide install needs.
$Script:PackageOverrides = @{
    # Its default location is the installing account's AppData, which is SYSTEM's during Windows setup.
    # Program Files keeps the folder NVM adds to the machine PATH writable by administrators only.
    'CoreyButler.NVMforWindows' = @{ ExtraArguments = '/DIR="%ProgramFiles%\nvm"'; DisplayNames = @('NVM for Windows') }
}

function Write-DevSetupHeading {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Host ''
    Write-Host $Message -ForegroundColor Cyan
}

function Get-DevSetupRelativePath {
    param([Parameter(Mandatory)] [string] $Path)
    return $Path.Substring($Destination.Length).TrimStart('\')
}

function Assert-DevSetupMicrosoftSignature {
    param([Parameter(Mandatory)] [string] $Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -ne $Script:MicrosoftSigner) {
        throw "$Path is not Microsoft-signed ($($signature.Status))."
    }
}

# curl.exe ships with Windows and is much faster than Invoke-WebRequest for large files.
function Save-DevSetupFile {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Sha256
    )
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    Write-Host "  $Uri" -ForegroundColor DarkGray
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if (Test-Path -LiteralPath $curl) {
                & $curl --location --fail --silent --show-error --retry 3 --output $Path $Uri
                if ($LASTEXITCODE -ne 0) { throw "curl exited with code $LASTEXITCODE" }
            } else {
                Invoke-WebRequest -Uri $Uri -OutFile $Path -UseBasicParsing -TimeoutSec 1800
            }
            if ($Sha256 -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Sha256.ToUpperInvariant()) {
                Remove-Item -LiteralPath $Path -Force
                throw "SHA-256 mismatch (expected $Sha256)"
            }
            break
        } catch {
            if ($attempt -eq 3) { throw "Could not download ${Uri}: $($_.Exception.Message)" }
            Write-Host "    retrying ($($_.Exception.Message))" -ForegroundColor DarkYellow
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
    return $Path
}

function Get-DevSetupGitHubRelease {
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $Tag
    )
    $uri = if ($Tag) { "https://api.github.com/repos/$Repository/releases/tags/$Tag" } else { "https://api.github.com/repos/$Repository/releases/latest" }
    $headers = @{ 'User-Agent' = 'WindowsDevConfig-OfflineKit'; Accept = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $env:GITHUB_TOKEN" }
    return Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 60
}

function Expand-DevSetupGitHubArchive {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $WorkDirectory
    )
    $zip = Save-DevSetupFile -Uri $Uri -Path (Join-Path $WorkDirectory 'archive.zip')
    $expanded = Join-Path $WorkDirectory 'expanded'
    Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force
    $top = @(Get-ChildItem -LiteralPath $expanded -Directory)
    if ($top.Count -ne 1) { throw "Unexpected archive layout from $Uri." }
    return $top[0].FullName
}

function Assert-DevSetupWinget {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'winget.exe was not found. Install App Installer from the Microsoft Store, then run this again.'
    }
    $text = (& $winget.Source --version) -replace '^v', ''
    $version = [version](($text -split '-')[0])
    if ($version -lt [version]'1.8.0') {
        throw "winget $text is too old for 'winget download'. Update App Installer to 1.8 or later."
    }
    Write-Host "  winget $text" -ForegroundColor DarkGray
}

function Save-DevSetupWingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Directory
    )
    $architectures = if ($Architecture -eq 'arm64') { @('arm64', 'x64', 'x86', 'neutral') } else { @('x64', 'x86', 'neutral') }
    $attempts = @()
    # Prefer machine-scope installers: the kit installs once for every user on the PC.
    foreach ($scope in @('machine', '')) {
        foreach ($arch in $architectures) {
            if (Test-Path -LiteralPath $Directory) { Remove-Item -LiteralPath $Directory -Recurse -Force }
            $arguments = @(
                'download', '--id', $Id, '--exact', '--source', 'winget', '--download-directory', $Directory,
                '--architecture', $arch, '--accept-package-agreements', '--accept-source-agreements',
                '--disable-interactivity', '--skip-license'
            )
            if ($scope) { $arguments += '--scope', $scope }
            $output = & winget.exe @arguments 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                return
            }
            $attempts += "scope=$(if ($scope) { $scope } else { 'any' }) arch=$arch exit=$LASTEXITCODE"
        }
    }
    throw "winget could not download $Id ($($attempts -join '; ')). Last output: $output"
}

function Get-DevSetupDownloadSize {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [string[]] $Relative
    )
    $bytes = 0
    foreach ($item in @($Relative | Where-Object { $_ })) {
        $path = Join-Path $Root $item
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $bytes += if ((Get-Item -LiteralPath $path).PSIsContainer) {
            [int64](Get-ChildItem -LiteralPath $path -Recurse -File | Measure-Object -Property Length -Sum).Sum
        } else {
            (Get-Item -LiteralPath $path).Length
        }
    }
    return $bytes
}

# One row per downloaded item, read back from the kit's devsetup.json.
function Write-DevSetupDownloadList {
    param([Parameter(Mandatory)] [string] $Root)
    $kit = Read-DevSetupManifest -Root $Root
    $rows = @(
        [pscustomobject]@{ Item = 'Windows Dev Config scripts (signed)'; Version = $kit.PayloadRef.Substring(0, 12)
            From = 'github.com/microsoft/WindowsDeveloperConfig'; Files = @('payload') }
        [pscustomobject]@{ Item = 'App Installer (WinGet)'; Version = $kit.WinGet.Version
            From = 'github.com/microsoft/winget-cli releases'; Files = @('winget') }
        foreach ($package in @($kit.Packages)) {
            [pscustomobject]@{
                Item = $(if ($package.PackageName) { $package.PackageName } else { $package.Name })
                Version = $package.Version; From = "WinGet: $($package.Id)"
                Files = @($package.File) + @($package.Dependencies | Where-Object { $_ })
            }
        }
        [pscustomobject]@{ Item = 'Cascadia Code fonts'; Version = ($kit.Fonts.File -replace '^.*CascadiaCode-|\.zip$', '')
            From = 'github.com/microsoft/cascadia-code releases'; Files = @($kit.Fonts.File) }
        [pscustomobject]@{ Item = 'Windows Subsystem for Linux'; Version = $kit.Wsl.Version
            From = 'github.com/microsoft/WSL releases'; Files = @($kit.Wsl.File) }
        [pscustomobject]@{ Item = $kit.Ubuntu.Name; Version = ([regex]::Match($kit.Ubuntu.File, '\d+\.\d+(\.\d+)?')).Value
            From = ([Uri]$kit.Ubuntu.Url).Host; Files = @($kit.Ubuntu.File) }
        [pscustomobject]@{ Item = "$($kit.Copilot.MarketplaceName) marketplace + WinUI plugin"; Version = ''
            From = 'github.com/microsoft/win-dev-skills, microsoft/winappCli'; Files = @($kit.Copilot.Marketplace) }
        [pscustomobject]@{ Item = 'GitHub Copilot icon'; Version = ''
            From = 'github.githubassets.com'; Files = @($kit.Copilot.Icon) }
    )
    $table = $rows | Select-Object Item, Version, From,
        @{ Name = 'Size'; Expression = { '{0:N0} MB' -f [Math]::Max(1, (Get-DevSetupDownloadSize -Root $Root -Relative $_.Files) / 1MB) } } |
        Format-Table -AutoSize | Out-String -Width 200
    Write-Host ''
    Write-Host "What this kit contains ($($kit.Architecture), created $($kit.CreatedUtc)):" -ForegroundColor Cyan
    Write-Host $table.TrimEnd()
    Write-Host '  Sizes include MSIX dependencies; the WinGet folder also keeps its dependency archive unpacked.' -ForegroundColor DarkGray
}

$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination).TrimEnd('\')
if ($Destination -notmatch '^[A-Za-z]:\\.+') {
    throw '-Destination must be a folder on a local drive, for example C:\setup\devsetup.'
}

if ($List) {
    Write-DevSetupDownloadList -Root $Destination
    return
}

Write-Host 'Windows Dev Config offline kit -- download' -ForegroundColor Cyan
Write-Host "  Destination:  $Destination" -ForegroundColor DarkGray
Write-Host "  Architecture: $Architecture" -ForegroundColor DarkGray
Assert-DevSetupWinget

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
foreach ($folder in @('payload', 'packages', 'winget', 'fonts', 'wsl', 'copilot')) {
    $path = Join-Path $Destination $folder
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}
$work = Join-Path ([IO.Path]::GetTempPath()) ("devsetup-download-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

try {
    #region Signed payload pinned by the standard setup
    Write-DevSetupHeading 'Standard setup payload'
    if (-not $PayloadRef) {
        Write-Host "  Reading $StandardLauncherUri" -ForegroundColor DarkGray
        $launcher = [string](Invoke-WebRequest -Uri $StandardLauncherUri -UseBasicParsing -TimeoutSec 60).Content
        $launcher = $launcher.TrimStart([char]0xFEFF)
        $signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($launcher)) -SourcePathOrExtension '.ps1'
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -ne $Script:MicrosoftSigner) {
            throw "The standard setup launcher failed Microsoft signature verification ($($signature.Status))."
        }
        if ($launcher -notmatch "\`$payloadRef\s*=\s*'([0-9a-f]{40})'") {
            throw 'Could not find the pinned payload commit in the standard setup launcher.'
        }
        $PayloadRef = $Matches[1]
    }
    Write-Host "  Payload commit: $PayloadRef" -ForegroundColor DarkGray
    $source = Expand-DevSetupGitHubArchive -Uri "https://github.com/$Script:Repository/archive/$PayloadRef.zip" -WorkDirectory (Join-Path $work 'payload')
    $signedFlow = Join-Path $source 'windows-dev-config'
    $payload = Join-Path $Destination 'payload'
    New-Item -ItemType Directory -Path $payload | Out-Null
    foreach ($item in @('bootstrap.ps1', 'dev-config.ps1', 'setup-standard.ps1', 'steps', 'workloads')) {
        Copy-Item -LiteralPath (Join-Path $signedFlow $item) -Destination $payload -Recurse -Force
    }
    $scripts = @(Get-ChildItem -LiteralPath $payload -Recurse -File -Filter '*.ps1')
    foreach ($script in $scripts) { Assert-DevSetupMicrosoftSignature -Path $script.FullName }
    Write-Host "  Verified $($scripts.Count) Microsoft-signed scripts." -ForegroundColor DarkGray

    # Read the package list and pinned versions from the payload itself, so the kit never drifts from it.
    $steps = Join-Path $payload 'steps'
    foreach ($file in @('packages.ps1', '_winget.ps1', 'fonts.ps1', 'wsl.ps1', 'copilot.ps1')) {
        . (Join-Path $steps $file)
    }
    $definition = & (Join-Path $payload 'workloads\devconfig.ps1') -Action Partial
    $packagePhase = @($definition.Phases | Where-Object { $_.File -eq 'packages.ps1' })
    $packageNames = @($packagePhase[0].Parameters.Packages)
    $catalog = @(Get-DevConfigPackageCatalog)
    #endregion

    #region WinGet packages
    Write-DevSetupHeading "WinGet packages ($($packageNames.Count))"
    $entries = @()
    foreach ($name in $packageNames) {
        $package = @($catalog | Where-Object { $_.Name -eq $name })[0]
        $id = $package.Id
        if ($name -eq 'VCRedist') { $id = "Microsoft.VCRedist.2015+.$Architecture" }
        $directory = Join-Path $Destination "packages\$name"
        Write-Host "  $name ($id)" -ForegroundColor DarkCyan
        Save-DevSetupWingetPackage -Id $id -Directory $directory
        $override = if ($Script:PackageOverrides.ContainsKey($id)) { $Script:PackageOverrides[$id] } else { @{} }
        $entry = New-DevSetupPackageEntry -Name $name -Directory $directory -Root $Destination -Architecture $Architecture -Override $override
        Write-Host "    $($entry.Version) $($entry.InstallerType) $(if ($entry.Scope) { "($($entry.Scope))" })" -ForegroundColor DarkGray
        $entries += $entry
    }
    #endregion

    #region App Installer (WinGet) pinned by the standard setup
    Write-DevSetupHeading "WinGet $Script:DevConfigWinGetTargetVersion (App Installer)"
    $wingetDir = Join-Path $Destination 'winget'
    $releaseBase = "https://github.com/microsoft/winget-cli/releases/download/v$Script:DevConfigWinGetTargetVersion"
    foreach ($asset in $Script:DevConfigWinGetAssets.GetEnumerator()) {
        Save-DevSetupFile -Uri "$releaseBase/$($asset.Key)" -Path (Join-Path $wingetDir $asset.Key) -Sha256 $asset.Value | Out-Null
    }
    $release = Get-DevSetupGitHubRelease -Repository 'microsoft/winget-cli' -Tag "v$Script:DevConfigWinGetTargetVersion"
    $licenseAsset = @($release.assets | Where-Object { $_.name -like '*License1.xml' })
    $license = $null
    if ($licenseAsset.Count) {
        $license = Save-DevSetupFile -Uri $licenseAsset[0].browser_download_url -Path (Join-Path $wingetDir $licenseAsset[0].name)
    }
    $wingetDependencies = Join-Path $wingetDir 'Dependencies'
    Expand-Archive -LiteralPath (Join-Path $wingetDir 'DesktopAppInstaller_Dependencies.zip') -DestinationPath $wingetDependencies -Force
    $dependencyArchitectures = if ($Architecture -eq 'arm64') { @('arm64', 'x64', 'x86') } else { @('x64', 'x86') }
    $bundle = Join-Path $wingetDir 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    $bundleIdentity = Get-DevSetupMsixIdentity -Path $bundle -Architecture $Architecture
    $wingetEntry = [ordered]@{
        Name         = 'WinGet'
        Id           = 'Microsoft.AppInstaller'
        Version      = [string]$Script:DevConfigWinGetTargetVersion
        Kind         = 'msix'
        File         = Get-DevSetupRelativePath -Path $bundle
        Sha256       = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
        License      = $(if ($license) { Get-DevSetupRelativePath -Path $license } else { $null })
        Dependencies = @(foreach ($arch in $dependencyArchitectures) {
            Get-ChildItem -LiteralPath (Join-Path $wingetDependencies $arch) -Filter '*.appx' -File |
                ForEach-Object { Get-DevSetupRelativePath -Path $_.FullName }
        })
        Detection    = [ordered]@{ IdentityName = $bundleIdentity.Name; Version = $bundleIdentity.Version; FamilyName = $bundleIdentity.FamilyName }
    }
    #endregion

    #region Fonts
    Write-DevSetupHeading "Cascadia Code $Script:CascadiaFontVersion"
    $fontUri = "https://github.com/microsoft/cascadia-code/releases/download/v$Script:CascadiaFontVersion/CascadiaCode-$Script:CascadiaFontVersion.zip"
    Save-DevSetupFile -Uri $fontUri -Path (Join-Path $Destination "fonts\CascadiaCode-$Script:CascadiaFontVersion.zip") -Sha256 $Script:CascadiaZipSha256 | Out-Null
    #endregion

    #region WSL and Ubuntu
    $wslRelease = Get-DevSetupGitHubRelease -Repository 'microsoft/WSL'
    Write-DevSetupHeading "WSL $($wslRelease.tag_name) and $Script:DevConfigWslDistributionName"
    $wslAsset = @($wslRelease.assets | Where-Object { $_.name -match "^wsl\.[\d.]+\.$Architecture\.msi$" })
    if ($wslAsset.Count -ne 1) { throw "The latest WSL release has no $Architecture MSI." }
    $wslMsi = Save-DevSetupFile -Uri $wslAsset[0].browser_download_url -Path (Join-Path $Destination "wsl\$($wslAsset[0].name)")
    Assert-DevSetupMicrosoftSignature -Path $wslMsi
    $wslEntry = [ordered]@{
        Name         = 'WSL'
        Id           = 'Microsoft.WSL'
        Version      = $wslRelease.tag_name
        Kind         = 'msi'
        File         = Get-DevSetupRelativePath -Path $wslMsi
        Sha256       = (Get-FileHash -LiteralPath $wslMsi -Algorithm SHA256).Hash
        Arguments    = '/quiet /norestart'
        SuccessCodes = @(0, 1641, 3010)
        Detection    = [ordered]@{ ProductCodes = @(Get-DevSetupMsiProperty -Path $wslMsi -Property 'ProductCode') }
    }

    $distributions = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json' -UseBasicParsing -TimeoutSec 60
    $distribution = @($distributions.ModernDistributions.$Script:DevConfigWslDistributionName |
        Where-Object { $_.Name -eq $Script:DevConfigWslDistributionName })
    if ($distribution.Count -ne 1) { throw "WSL's distribution list has no '$Script:DevConfigWslDistributionName' entry." }
    $image = if ($Architecture -eq 'arm64') { $distribution[0].Arm64Url } else { $distribution[0].Amd64Url }
    $imagePath = Join-Path $Destination ("wsl\" + ($image.Url -replace '^.*/', ''))
    Save-DevSetupFile -Uri $image.Url -Path $imagePath -Sha256 $image.Sha256 | Out-Null
    $ubuntuEntry = [ordered]@{
        Name   = $Script:DevConfigWslDistributionName
        File   = Get-DevSetupRelativePath -Path $imagePath
        Sha256 = $image.Sha256.ToUpperInvariant()
        Url    = $image.Url
    }
    #endregion

    #region Copilot
    Write-DevSetupHeading 'GitHub Copilot extras'
    $copilotDir = Join-Path $Destination 'copilot'
    $icon = Save-DevSetupFile -Uri 'https://github.githubassets.com/favicons/favicon-dark.png' -Path (Join-Path $copilotDir 'favicon-dark.png')
    $marketplaceName = $Script:DevConfigWinSkillsMarketplace
    $pluginName = ($Script:DevConfigWinUIPlugin -split '@')[0]
    $marketplaceSource = Expand-DevSetupGitHubArchive -Uri "https://github.com/microsoft/$marketplaceName/archive/refs/heads/main.zip" -WorkDirectory (Join-Path $work 'marketplace')
    $marketplace = Join-Path $copilotDir $marketplaceName
    Copy-Item -LiteralPath $marketplaceSource -Destination $marketplace -Recurse -Force

    # Point the plugin at a local copy so `copilot plugin install` needs no network.
    $marketplaceJson = Join-Path $marketplace '.github\plugin\marketplace.json'
    $catalogJson = [IO.File]::ReadAllText($marketplaceJson) | ConvertFrom-Json
    $plugin = @($catalogJson.plugins | Where-Object { $_.name -eq $pluginName })
    if ($plugin.Count -ne 1) { throw "The $marketplaceName marketplace has no '$pluginName' plugin." }
    $pluginSource = $plugin[0].source
    if ($pluginSource -isnot [string]) {
        if ($pluginSource.source -ne 'github') { throw "Unsupported source type '$($pluginSource.source)' for the $pluginName plugin." }
        $repoRoot = Expand-DevSetupGitHubArchive -Uri "https://github.com/$($pluginSource.repo)/archive/$($pluginSource.sha).zip" -WorkDirectory (Join-Path $work 'plugin')
        $localPlugin = Join-Path $marketplace "plugins\$pluginName"
        if (Test-Path -LiteralPath $localPlugin) { Remove-Item -LiteralPath $localPlugin -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $repoRoot ($pluginSource.path -replace '/', '\')) -Destination $localPlugin -Recurse -Force
        $plugin[0].source = "./plugins/$pluginName"
        [IO.File]::WriteAllText($marketplaceJson, ($catalogJson | ConvertTo-Json -Depth 32), [Text.UTF8Encoding]::new($false))
        foreach ($other in @('.claude-plugin\marketplace.json', '.agents\plugins\marketplace.json')) {
            $otherPath = Join-Path $marketplace $other
            if (Test-Path -LiteralPath $otherPath) { Remove-Item -LiteralPath $otherPath -Force }
        }
    }
    #endregion

    #region Manifest and kit scripts
    Write-DevSetupHeading 'Kit manifest'
    $manifest = [ordered]@{
        KitVersion       = $Script:DevSetupKitVersion
        CreatedUtc       = (Get-Date).ToUniversalTime().ToString('o')
        Architecture     = $Architecture
        PayloadRef       = $PayloadRef
        StandardLauncher = $StandardLauncherUri
        Packages         = $entries
        WinGet           = $wingetEntry
        Wsl              = $wslEntry
        Ubuntu           = $ubuntuEntry
        Fonts            = [ordered]@{ File = "fonts\CascadiaCode-$Script:CascadiaFontVersion.zip" }
        Copilot          = [ordered]@{
            Icon            = Get-DevSetupRelativePath -Path $icon
            Marketplace     = Get-DevSetupRelativePath -Path $marketplace
            MarketplaceName = $marketplaceName
            Plugin          = $Script:DevConfigWinUIPlugin
        }
        # Files each user's first sign-in needs; machine-setup.ps1 keeps a protected copy of them.
        UserFiles        = @($ubuntuEntry.File, (Get-DevSetupRelativePath -Path $icon), (Get-DevSetupRelativePath -Path $marketplace))
    }
    [IO.File]::WriteAllText((Join-Path $Destination $Script:DevSetupManifestName), ($manifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))

    if ((Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\') -ne $Destination) {
        foreach ($file in $Script:KitFiles) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $Destination -Force
        }
    }
    #endregion
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$size = (Get-ChildItem -LiteralPath $Destination -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-DevSetupDownloadList -Root $Destination
Write-Host ''
Write-Host "Offline kit ready: $Destination ($([Math]::Round($size / 1GB, 2)) GB, $($entries.Count) packages)." -ForegroundColor Green
Write-Host '  Next: copy this folder to C:\setup\devsetup in the Windows image and follow README.md.' -ForegroundColor DarkGray
Write-Host '  Run download.ps1 -List at any time to show this list again.' -ForegroundColor DarkGray
