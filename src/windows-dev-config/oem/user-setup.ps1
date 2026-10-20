<#
.SYNOPSIS
  Per-user part of the offline Windows Dev Config standard setup.

.DESCRIPTION
  machine-setup.ps1 registers this script with Active Setup, so Windows runs it once in each
  user's first sign-in. It never elevates and needs no network access.

  -Stage SignIn runs hidden while Windows prepares the desktop: it applies the File Explorer,
  Start, and theme settings before Explorer starts (so they show immediately), then opens a
  window that runs -Stage Main for everything else: Terminal, PowerShell profile, Copilot,
  and Ubuntu. Steps that cannot finish yet (for example WSL waiting for a restart) run again at
  the next sign-in.
#>

[CmdletBinding()]
param(
    [ValidateSet('SignIn', 'Main')] [string] $Stage = 'Main',
    # Development only: skips the Microsoft signature check on the installed payload.
    [switch] $AllowUnsigned
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"

. (Join-Path $PSScriptRoot '_oem.ps1')

# SYSTEM, OOBE's temporary account, and audit mode are not the PC's real users.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$setupState = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue
$inSetup = $false
foreach ($name in @('SystemSetupInProgress', 'AuditInProgress', 'OOBEInProgress')) {
    if ($setupState -and $setupState.PSObject.Properties[$name] -and $setupState.$name -eq 1) { $inSetup = $true }
}
if ($identity.IsSystem -or $env:USERNAME -like 'defaultuser*' -or $inSetup) {
    exit 0
}

$root = $PSScriptRoot
$manifest = Read-DevSetupManifest -Root $root
$userState = Join-Path $env:LOCALAPPDATA 'CalmOS'
New-Item -ItemType Directory -Path $userState -Force | Out-Null

if ($Stage -eq 'Main') {
    try { $Host.UI.RawUI.WindowTitle = 'Windows Dev Config -- finishing setup' } catch { Write-Verbose 'No console title.' }
    try {
        $utf8NoBom = [Text.UTF8Encoding]::new($false)
        [Console]::OutputEncoding = $utf8NoBom
        $OutputEncoding = $utf8NoBom
    } catch {
        Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
    }
}

$installRoot = $Script:DevSetupInstallRoot
$stepsDir = Join-Path $installRoot 'steps'
$securityCode = [IO.File]::ReadAllText((Join-Path $stepsDir '_security.ps1'))
if (-not $AllowUnsigned) {
    $signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($securityCode)) -SourcePathOrExtension '.ps1'
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
        throw 'The installed Windows Dev Config payload failed Microsoft signature verification.'
    }
}
. ([scriptblock]::Create($securityCode))
Assert-DevConfigProtectedTree -Directory $installRoot
if (-not $AllowUnsigned -and $Stage -eq 'Main') {
    Assert-DevConfigMicrosoftSigned -Directory $installRoot
}
foreach ($file in @('_console', '_step-runner', '_elevation', '_registry', '_environment', '_retry', '_terminal',
        '_pwsh-bootstrap', 'packages', 'registry-explorer', 'registry-taskbar-search', 'fonts', 'terminal', 'powershell-profile',
        'copilot', 'wsl')) {
    . (Join-Path $stepsDir "$file.ps1")
}
$Script:DevConfigAction        = 'Partial'
$Script:DevConfigWorkload      = 'devconfig'
$Script:DevConfigAllowUnsigned = [bool]$AllowUnsigned

if ($Stage -eq 'SignIn') {
    # Explorer reads these when it starts, which is right after Active Setup returns.
    Start-DevConfigLog -Path (Join-Path $userState 'offline-signin-log.txt') -Append
    foreach ($phase in @(
        { Invoke-RegistryExplorerPhase },
        { Invoke-RegistryTaskbarSearchPhase },
        { if (-not (Test-DevConfigDarkThemeSet)) { Set-DevConfigDarkTheme } }
    )) {
        try { & $phase } catch { Write-Host "Early setting failed: $($_.Exception.Message)" }
    }
    Stop-DevConfigLog
    # conhost keeps this window independent of Windows Terminal, which the setup updates and configures.
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $console = Join-Path $env:SystemRoot 'System32\conhost.exe'
    Start-Process -FilePath $console -ArgumentList "`"$shell`" -NoProfile -ExecutionPolicy RemoteSigned -File `"$PSCommandPath`" -Stage Main"
    exit 0
}

#region Main stage

function Get-DevSetupUserApps {
    $apps = @($manifest.WinGet) + @($manifest.Packages | Where-Object { $_.Kind -eq 'msix' })
    foreach ($app in $apps) {
        [pscustomobject]@{
            Name         = $app.Detection.IdentityName
            FamilyName   = $app.Detection.FamilyName
            Version      = $app.Detection.Version
            File         = $app.File
            Dependencies = @($app.Dependencies | Where-Object { $_ })
        }
    }
}

function Get-DevSetupAppAliases {
    param([Parameter(Mandatory)] $Package)
    $manifestPath = Join-Path $Package.InstallLocation 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return @() }
    $xml = [xml][IO.File]::ReadAllText($manifestPath)
    return @($xml.SelectNodes("//*[local-name()='ExecutionAlias']") | ForEach-Object { $_.GetAttribute('Alias') } | Where-Object { $_ })
}

# A new profile can list a provisioned app before its command aliases (pwsh.exe, oh-my-posh.exe) exist.
function Test-DevSetupUserAppReady {
    param([Parameter(Mandatory)] $App)
    $package = Get-AppxPackage -Name $App.Name -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $package -or [version]$package.Version -lt [version]$App.Version) { return $false }
    $aliasDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    foreach ($alias in Get-DevSetupAppAliases -Package $package) {
        if (-not (Test-Path -LiteralPath (Join-Path $aliasDir $alias))) { return $false }
    }
    return $true
}

function Test-DevSetupUserAppsReady {
    foreach ($app in Get-DevSetupUserApps) {
        if (-not (Test-DevSetupUserAppReady -App $app)) { return $false }
    }
    return (Test-Path -LiteralPath (Split-Path -Parent (Get-DevSetupTerminalSettingsFile)))
}

function Get-DevSetupTerminalSettingsFile {
    $terminal = @($manifest.Packages | Where-Object { $_.Name -eq 'Terminal' } | Select-Object -First 1)
    $familyName = if ($terminal.Count) { $terminal[0].Detection.FamilyName } else { 'Microsoft.WindowsTerminal_8wekyb3d8bbwe' }
    return (Join-Path $env:LOCALAPPDATA "Packages\$familyName\LocalState\settings.json")
}

# machine-setup.ps1 -PerUserApps stages MSIX files here; otherwise the apps are provisioned machine-wide.
function Install-DevSetupUserApp {
    param([Parameter(Mandatory)] $App)
    $file = Join-Path $root $App.File
    $installed = Get-AppxPackage -Name $App.Name -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if ((Test-Path -LiteralPath $file) -and (-not $installed -or [version]$installed.Version -lt [version]$App.Version)) {
        Write-Host "  Installing $($App.Name) for $env:USERNAME..." -ForegroundColor DarkGray
        $dependencies = @($App.Dependencies | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path -LiteralPath $_ })
        try {
            if ($dependencies.Count) {
                Add-AppxPackage -Path $file -DependencyPath $dependencies -ForceTargetApplicationShutdown -ErrorAction Stop
            } else {
                Add-AppxPackage -Path $file -ForceTargetApplicationShutdown -ErrorAction Stop
            }
        } catch {
            if (-not $dependencies.Count) { throw }
            # Newer copies of the frameworks can already be present; install against those.
            Add-AppxPackage -Path $file -ForceTargetApplicationShutdown -ErrorAction Stop
        }
        return
    }
    Write-Host "  Finishing $($App.Name) for $env:USERNAME..." -ForegroundColor DarkGray
    Add-AppxPackage -RegisterByFamilyName -MainPackage $App.FamilyName -ErrorAction Stop
}

# Registering again for this user creates missing aliases and app data folders.
function Register-DevSetupUserApps {
    $deadline = (Get-Date).AddMinutes(10)
    $requested = @{}
    $failed = @{}
    while ((Get-Date) -lt $deadline) {
        $pending = @(Get-DevSetupUserApps | Where-Object { -not $failed.ContainsKey($_.Name) -and -not (Test-DevSetupUserAppReady -App $_) })
        if ($pending.Count -eq 0) { break }
        foreach ($app in $pending) {
            if ($requested.ContainsKey($app.Name)) { continue }
            $requested[$app.Name] = $true
            try {
                Install-DevSetupUserApp -App $app
            } catch {
                # Nothing on this PC can change that within this run, so stop waiting for it.
                $failed[$app.Name] = $true
                Write-Host "  $($app.Name) could not be set up ($($_.Exception.Message))" -ForegroundColor Yellow
            }
        }
        Start-Sleep -Seconds 5
    }
    # Terminal creates its data folder on first launch; the Terminal and font steps need it now.
    $settingsDir = Split-Path -Parent (Get-DevSetupTerminalSettingsFile)
    if (-not (Test-Path -LiteralPath $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    }
}

# Offline, the official step writes the profile without its icon; add the kit's copy of that icon.
function Set-DevSetupCopilotTerminalProfile {
    Set-DevConfigCopilotTerminalProfile
    $fragmentsDir = Get-DevConfigCopilotFragmentDir
    $fragmentPath = Join-Path $fragmentsDir 'github-copilot.fragment.json'
    $fragment = (Read-DevConfigTextFile -Path $fragmentPath) | ConvertFrom-Json
    $entry = @($fragment.profiles)[0]
    if (-not $entry.PSObject.Properties['icon']) {
        $icon = Join-Path $fragmentsDir 'copilot.png'
        Copy-Item -LiteralPath (Join-Path $root $manifest.Copilot.Icon) -Destination $icon -Force
        $entry | Add-Member -NotePropertyName icon -NotePropertyValue $icon
        Write-DevConfigTextFile -Path $fragmentPath -Content ($fragment | ConvertTo-Json -Depth 8)
    }
}

function Test-DevSetupOnline {
    $client = New-Object Net.Sockets.TcpClient
    try {
        return $client.ConnectAsync('github.com', 443).Wait(3000) -and $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

# Online, register the same GitHub marketplace the online setup does; offline, use the kit's copy.
function Add-DevSetupWinSkillsMarketplace {
    if (Test-DevSetupOnline) {
        try {
            Add-DevConfigWinSkillsMarketplace
            return
        } catch {
            Write-Host "  GitHub was not reachable for the marketplace ($($_.Exception.Message)); using the offline copy." -ForegroundColor DarkGray
        }
    }
    if (-not (Get-Command 'copilot' -ErrorAction SilentlyContinue)) {
        throw 'The copilot command is not on PATH yet, so its marketplace cannot be configured.'
    }
    $local = Join-Path $root $manifest.Copilot.Marketplace
    $result = Invoke-DevConfigNativeCommand -FilePath 'copilot' -Arguments @('plugin', 'marketplace', 'add', $local) -TimeoutSeconds 300
    if ($result.ExitCode -ne 0) {
        Write-Host $result.Output
        throw "copilot plugin marketplace add failed with exit code $($result.ExitCode)"
    }
}

function Install-DevSetupUbuntu {
    if (-not (Test-DevConfigWslComponentsReady)) {
        $Script:DevSetupRetryNextSignIn = $true
        Set-DevConfigStepUnverified -Reason 'WSL starts after the next restart. Ubuntu will be added automatically at your next sign-in.'
        return
    }
    $setting = $Script:DevConfigWslFirstRunSetting
    Set-DevConfigRegistryValue -KeyPath $setting.KeyPath -ValueName $setting.ValueName -Value $setting.Value
    $image = Join-Path $root $manifest.Ubuntu.File
    if ((Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash -ne $manifest.Ubuntu.Sha256) {
        throw "The offline Ubuntu image failed its SHA-256 check: $image"
    }
    Invoke-DevConfigWslUbuntuInstall -MaxAttempts 2 -Arguments @(
        '--install', '--from-file', $image, '--name', $manifest.Ubuntu.Name, '--no-launch'
    )
    if (-not (Wait-DevConfigUbuntuVisible)) {
        Set-DevConfigStepUnverified -Reason 'Ubuntu was installed but WSL does not list it yet. It will be checked again at your next sign-in.'
        $Script:DevSetupRetryNextSignIn = $true
    }
}

function Set-DevSetupRetry {
    param([switch] $Enable)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not $Enable) {
        Remove-ItemProperty -LiteralPath $key -Name $Script:DevSetupUserRunOnceName -ErrorAction SilentlyContinue
        return $false
    }
    # New-Item -Force on an existing registry key deletes its values, so create keys only when missing.
    foreach ($path in @($Script:DevSetupUserStateKey, $key)) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    }
    $attempts = [int](Get-Item -LiteralPath $Script:DevSetupUserStateKey).GetValue('Attempts', 0)
    if ($attempts -ge 3) { return $false }
    New-ItemProperty -LiteralPath $Script:DevSetupUserStateKey -Name 'Attempts' -Value ($attempts + 1) -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $key -Name $Script:DevSetupUserRunOnceName -PropertyType String -Force `
        -Value (Get-DevSetupUserCommand -ScriptPath $PSCommandPath -Stage Main) | Out-Null
    return $true
}

$Script:DevSetupRetryNextSignIn = $false
Start-DevConfigLog -Path (Join-Path $userState 'offline-user-setup-log.txt') -Append
$total = 8
$failure = $null
Write-Host ''
Write-Host "Calm OS setup (offline, Partial) -- finishing setup for $env:USERNAME" -ForegroundColor Cyan
Write-Host '  Everything comes from this PC; no internet connection is needed.' -ForegroundColor DarkGray
try {
    Invoke-DevSetupPhase -Index 1 -Total $total -Title 'Packages' -ScriptBlock {
        # Per-user package settings (such as PowerToysAOT) come from the same catalog the online setup uses.
        $packageSettings = @(foreach ($package in @(Get-DevConfigPackage -Name @($manifest.Packages | ForEach-Object { $_.Name }))) {
            if ($package['Settings']) { $package['Settings'] }
        })
        Invoke-DevConfigSteps -Steps @(
            New-DevConfigStep -Name 'ProvisionedApps' -Description 'Set up Terminal, PowerShell 7, WinGet, and the other apps for this user' -BestEffort `
                -Check { Test-DevSetupUserAppsReady } `
                -Apply { Register-DevSetupUserApps; if (-not (Test-DevSetupUserAppsReady)) { $Script:DevSetupRetryNextSignIn = $true } }
            foreach ($setting in $packageSettings) {
                New-DevConfigRegistryStep -Setting $setting
            }
        )
    }
    Invoke-DevSetupPhase -Index 2 -Total $total -Title 'File Explorer tweaks' -ScriptBlock { Invoke-RegistryExplorerPhase }
    Invoke-DevSetupPhase -Index 3 -Total $total -Title 'Taskbar & Start tweaks' -ScriptBlock { Invoke-RegistryTaskbarSearchPhase }
    Invoke-DevSetupPhase -Index 4 -Total $total -Title 'Fonts' -ScriptBlock {
        # Terminal is not running yet, so the font is applied now instead of at the next sign-in.
        Invoke-DevConfigSteps -Steps @(
            New-DevConfigStep -Name 'CascadiaDefaultFont' -Description 'Use Cascadia Mono NF in Windows Terminal' -BestEffort `
                -Check { (Test-DevConfigCascadiaDefaultFont) -and -not (Get-DevConfigPendingTerminalFont) } `
                -Apply { Set-DevConfigCascadiaDefaultFont; Invoke-DevConfigPendingTerminalFont }
        )
    }
    Invoke-DevSetupPhase -Index 5 -Total $total -Title 'Windows Terminal' -ScriptBlock { Invoke-TerminalPhase }
    Invoke-DevSetupPhase -Index 6 -Total $total -Title 'PowerShell profile' -ScriptBlock { Invoke-PowerShellProfilePhase }
    Invoke-DevSetupPhase -Index 7 -Total $total -Title 'GitHub Copilot' -ScriptBlock {
        Invoke-DevConfigSteps -Steps @(
            New-DevConfigStep -Name 'GitHubCopilotProfile' -Description 'Add a GitHub Copilot profile to Windows Terminal' -BestEffort `
                -Check { Test-DevConfigCopilotTerminalProfile } `
                -Apply { Set-DevSetupCopilotTerminalProfile }
            New-DevConfigStep -Name 'WinSkillsMarketplace' -Description 'Add win-dev-skills to the Copilot plugin marketplace' -BestEffort `
                -Check { Test-DevConfigWinSkillsMarketplaceAdded } `
                -Apply { Add-DevSetupWinSkillsMarketplace }
            New-DevConfigStep -Name 'WinUIPlugin' -Description 'Install the WinUI Copilot plugin from win-dev-skills' -BestEffort `
                -Check { Test-DevConfigWinUIPluginInstalled } `
                -Apply { Install-DevConfigWinUIPlugin }
        )
    }
    Invoke-DevSetupPhase -Index 8 -Total $total -Title 'WSL + Ubuntu' -ScriptBlock {
        Invoke-DevConfigSteps -Steps @(
            New-DevConfigStep -Name 'WslUbuntu' -Description "Install $($manifest.Ubuntu.Name) from the kit" -BestEffort `
                -Check { Test-DevConfigUbuntuInstalled } `
                -Apply { Install-DevSetupUbuntu }
        )
    }
} catch {
    $failure = $_
}

$retry = Set-DevSetupRetry -Enable:($Script:DevSetupRetryNextSignIn -or [bool]$failure)
if ($retry) {
    Add-DevConfigNote -Message 'The flagged steps run again automatically at your next sign-in.'
}
if (-not $failure) {
    Add-DevConfigNote -Message 'Your PC is ready. Open Windows Terminal to start; Ubuntu finishes its own setup the first time you open it.'
}
Write-DevSetupSummary -Name 'Calm OS setup' -Failure $failure
Save-DevSetupResult -Path (Join-Path $userState 'offline-user-setup-result.json') -Failure $failure
Stop-DevConfigLog
Wait-DevConfigKeyPress
if ($failure) { exit 1 }
exit 0

#endregion
