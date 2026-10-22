<#
.SYNOPSIS
  Offline checks for the OEM kit: WinGet manifest parsing, installer switches, family names,
  the offline URL shim, and coverage of every standard (Partial) setup step.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Script:checks = 0
$kit = Join-Path $PSScriptRoot '..\..\windows-dev-config\oem'
$flow = Join-Path $PSScriptRoot '..\..\windows-dev-config'

function Assert-Kit {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $Script:checks++
}

. (Join-Path $kit '_oem.ps1')
. (Join-Path $kit '_oem-download.ps1')

#region WinGet manifest parsing
$yaml = @'
PackageIdentifier: Example.Tool
PackageVersion: 1.2.3
PackageName: Example Tool
Publisher: Example
Description: First line of a plain scalar
  that continues here.
ReleaseNotes: "Fixes:\n- a quoted line with: a colon
  - and a continuation starting with a dash \U0001F41B"
Tags:
- cli
- tool
InstallerType: inno
InstallerSwitches:
  Custom: /mergetasks=!runcode
Installers:
- Architecture: x64
  Scope: machine
  InstallerUrl: https://example.com/setup.exe
  InstallerSha256: ABC
  ProductCode: '{1D8E6291-B0D5-35EC-8441-6616F567A0F7}'
  AppsAndFeaturesEntries:
  - DisplayName: Example Tool (x64)
    UpgradeCode: '{00000000-0000-0000-0000-000000000000}'
  InstallerSuccessCodes:
  - 1638
  ExpectedReturnCodes:
  - InstallerReturnCode: 1641
    ReturnResponse: rebootInitiated
  - InstallerReturnCode: 5
    ReturnResponse: cancelledByUser
  NestedInstallerFiles: []
ManifestType: merged
ManifestVersion: 1.10.0
'@
$manifest = ConvertFrom-DevSetupYaml -Text $yaml
$installer = Get-DevSetupWingetInstaller -Manifest $manifest
Assert-Kit ($manifest.PackageIdentifier -eq 'Example.Tool') 'Top-level scalars must parse.'
Assert-Kit ($manifest.Description -eq 'First line of a plain scalar that continues here.') 'Plain multi-line scalars must fold.'
Assert-Kit ($manifest.ReleaseNotes.StartsWith("Fixes:`n- a quoted line")) 'Double-quoted scalars must unescape.'
Assert-Kit ($manifest.ReleaseNotes.EndsWith([char]::ConvertFromUtf32(0x1F41B))) 'Unicode escapes must decode.'
Assert-Kit ((@($manifest.Tags) -join ',') -eq 'cli,tool') 'Scalar sequences at the key indentation must parse.'
Assert-Kit ($installer.InstallerType -eq 'inno' -and $installer.Scope -eq 'machine') 'Installer fields must merge over root fields.'
Assert-Kit ($installer.InstallerSwitches.Custom -eq '/mergetasks=!runcode') 'Root InstallerSwitches must apply to the installer.'
Assert-Kit ($installer.ProductCode -eq '{1D8E6291-B0D5-35EC-8441-6616F567A0F7}') 'Single-quoted scalars must unquote.'
Assert-Kit (@($installer.AppsAndFeaturesEntries)[0].DisplayName -eq 'Example Tool (x64)') 'Sequences of maps must parse.'
Assert-Kit (@($installer.NestedInstallerFiles).Count -eq 0) 'Empty flow sequences must parse.'
Assert-Kit ($manifest.ManifestType -eq 'merged') 'Parsing must continue after nested installer blocks.'
$codes = @(Get-DevSetupSuccessCodes -Installer $installer)
Assert-Kit (($codes -contains 1638) -and ($codes -contains 1641) -and ($codes -contains 3010) -and ($codes -notcontains 5)) 'Success codes must include reboot and declared codes only.'
#endregion

#region Installer switches mirror WinGet defaults
Assert-Kit ((Get-DevSetupInstallerArguments -InstallerType wix) -eq '/quiet /norestart ALLUSERS=1') 'MSI installs must be quiet and machine-wide.'
Assert-Kit ((Get-DevSetupInstallerArguments -InstallerType inno -Custom '/mergetasks=!runcode') -eq '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS /mergetasks=!runcode') 'Inno installs must use WinGet silent switches plus Custom.'
Assert-Kit ((Get-DevSetupInstallerArguments -InstallerType burn -Silent '/install /quiet') -eq '/install /quiet') 'Manifest Silent switches must replace the defaults.'
Assert-Kit ((Get-DevSetupInstallerArguments -InstallerType nullsoft) -eq '/S') 'Nullsoft installs must use /S.'
$threw = $false
try { Get-DevSetupInstallerArguments -InstallerType exe | Out-Null } catch { $threw = $true }
Assert-Kit $threw 'An exe installer without silent switches must be rejected at download time.'
#endregion

#region Package family names
Assert-Kit ((Get-DevSetupPublisherId -Publisher 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') -eq '8wekyb3d8bbwe') 'Publisher IDs must match Windows.'
#endregion

#region Device-side scripts stay clear of download and decoding code
# Offline devices scan these with the image's Defender definitions, which flagged
# Trojan:PowerShell/DownloadObfus on an earlier version that redirected Invoke-WebRequest.
foreach ($file in @('_oem.ps1', 'machine-setup.ps1', 'user-setup.ps1', 'uninstall-package.ps1')) {
    $text = [IO.File]::ReadAllText((Join-Path $kit $file))
    foreach ($pattern in @('Invoke-WebRequest', 'Invoke-RestMethod', 'DownloadString', 'DownloadFile', 'Net\.WebClient',
            'FromBase64String', 'ConvertFromUtf32', 'EncodedCommand', '\$\{function:', 'Invoke-Expression', '\biex\b')) {
        Assert-Kit ($text -notmatch $pattern) "$file must not contain '$pattern'; keep device-side scripts free of download and decoding code."
    }
}
#endregion

#region The per-user part never shows a window
$userText = [IO.File]::ReadAllText((Join-Path $kit 'user-setup.ps1'))
foreach ($pattern in @('Start-Process', 'Wait-DevConfigKeyPress', 'Invoke-DevConfigWslUbuntuInstall', 'Invoke-DevConfigProcess', 'Read-Host', 'Out-GridView')) {
    Assert-Kit ($userText -notmatch $pattern) "user-setup.ps1 must not use '$pattern': it runs hidden at first sign-in and must never show a window or wait for input."
}
$command = Get-DevSetupUserCommand -ScriptPath 'C:\ProgramData\CalmOS-Offline\user-setup.ps1'
Assert-Kit ($command -match '-WindowStyle Hidden' -and $command -match '-NonInteractive') 'The Active Setup command must start PowerShell hidden and non-interactive.'
#endregion

#region Machine-wide uninstall entries point at a helper that ships with the kit
$downloadText = [IO.File]::ReadAllText((Join-Path $kit 'download.ps1'))
$machineSetupText = [IO.File]::ReadAllText((Join-Path $kit 'machine-setup.ps1'))
Assert-Kit ($downloadText -match "KitFiles\s*=\s*@\([^)]*'uninstall-package\.ps1'") 'download.ps1 must copy uninstall-package.ps1 into the kit.'
Assert-Kit ($machineSetupText -match "function Get-DevSetupUserFiles \{\s*@\([^)]*'uninstall-package\.ps1'") 'machine-setup.ps1 must stage uninstall-package.ps1 with the per-user files.'
Assert-Kit ($machineSetupText -match "Join-Path \`$offlineRoot 'uninstall-package\.ps1'") 'The moved Installed apps entry must run the staged uninstall-package.ps1.'
#endregion

#region The sysprep specialize command in the README runs the whole machine part, hidden
$readmeText = [IO.File]::ReadAllText((Join-Path $kit 'README.md'))
$specializePath = [regex]::Match($readmeText, '<Path>([^<]*machine-setup\.ps1[^<]*)</Path>').Groups[1].Value
# Provisioned Store bundles do not survive OOBE, so the audit-mode MSIX apps must be staged (-PerUserApps);
# -Skip would leave packages uninstalled.
Assert-Kit ($specializePath -match '-PerUserApps' -and $specializePath -notmatch '-Skip') 'The README specialize command must run the whole machine part with -PerUserApps and without -Skip.'
Assert-Kit ($readmeText -match 'machine-setup\.ps1 -PerUserApps\r?\n') 'The README audit-mode command must pass -PerUserApps.'
Assert-Kit ($specializePath -match '^powershell\.exe ' -and $specializePath -match '-WindowStyle Hidden' -and $specializePath -match '-NonInteractive') 'The README specialize command must start PowerShell directly, hidden and non-interactive, so no console window shows.'
#endregion

#region Every standard step is covered by the kit
# Capture the official Partial step names by running each phase with recording stand-ins.
$Script:capturedSteps = @()
function New-DevConfigStep { param([string] $Name) [pscustomobject]@{ Name = $Name } }
function New-DevConfigRegistryStep { param([hashtable] $Setting, [switch] $Reset) [pscustomobject]@{ Name = $Setting.Name } }
function Invoke-DevConfigSteps { param([object[]] $Steps) $Script:capturedSteps += @($Steps | ForEach-Object { $_.Name }) }
function Show-DevConfigPhaseHeader { }
function Initialize-DevConfigWinGet { }
function Get-DevConfigTerminalFontRunOnceCommand { }
function Add-DevConfigNote { }
$definition = & (Join-Path $flow 'workloads\devconfig.ps1') -Action Partial
foreach ($phase in $definition.Phases) {
    . (Join-Path $flow "steps\$($phase.File)")
}
$Script:DevConfigAction = 'Partial'
$Script:DevConfigResumed = $false

function Get-PhaseSteps {
    param([Parameter(Mandatory)] $Phase)
    if ($Phase.File -eq 'packages.ps1') {
        $settings = @(foreach ($package in @(Get-DevConfigPackage -Name $Phase.Parameters.Packages)) {
            if ($package['Settings']) { $package['Settings'] | ForEach-Object { $_.Name } }
        })
        return @($Phase.Parameters.Packages) + $settings
    }
    $Script:capturedSteps = @()
    $parameters = @{}
    if ($Phase.Function -eq 'Invoke-WslPhase') { $parameters.OrchestratorPath = 'unused' }
    & $Phase.Function @parameters
    return @($Script:capturedSteps)
}

$official = @(foreach ($phase in $definition.Phases) { Get-PhaseSteps -Phase $phase })
$machineText = [IO.File]::ReadAllText((Join-Path $kit 'machine-setup.ps1'))
$kitLines = @([IO.File]::ReadAllLines((Join-Path $kit 'machine-setup.ps1'))) + @([IO.File]::ReadAllLines((Join-Path $kit 'user-setup.ps1')))
$kitText = $kitLines -join "`n"
$covered = @([regex]::Matches($kitText, "New-DevConfigStep -Name '(\w+)'") | ForEach-Object { $_.Groups[1].Value })
$covered += @([regex]::Matches($kitText, "-Steps @\('(\w+)'\)") | ForEach-Object { $_.Groups[1].Value })
foreach ($phase in $definition.Phases) {
    # A phase the kit runs whole, without a -Steps filter, covers every step it defines.
    $whole = @($kitLines | Where-Object { $_ -match "\{\s*$([regex]::Escape($phase.Function))\s*\}" -and $_ -notmatch '-Steps' })
    if ($whole.Count) { $covered += Get-PhaseSteps -Phase $phase }
}
Assert-Kit ($machineText -match '\$included = @\(\$manifest\.Packages \| Where-Object \{ \$_\.Name -notin \$skippedNames \}\)' -and
    $machineText -match 'foreach \(\$entry in \$included\)') 'The machine part must install every downloaded package that -Skip does not leave out.'
$covered += @($definition.Phases | Where-Object { $_.File -eq 'packages.ps1' } | ForEach-Object { $_.Parameters.Packages })
if ($kitText -match 'Get-DevConfigPackage -Name' -and $kitText -match "if \(\`$package\['Settings'\]\)") {
    $covered += @(Get-PhaseSteps -Phase @($definition.Phases | Where-Object { $_.File -eq 'packages.ps1' })[0])
}
$missing = @($official | Where-Object { $covered -notcontains $_ } | Select-Object -Unique)
Assert-Kit ($official.Count -gt 30) "Expected the standard setup to define more than 30 steps; found $($official.Count)."
Assert-Kit ($missing.Count -eq 0) "The offline kit does not cover these standard steps: $($missing -join ', ')."
#endregion

#region Kit scripts parse in this shell
foreach ($file in Get-ChildItem -LiteralPath $kit -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-Kit ($errors.Count -eq 0) "$($file.Name) has parse errors: $($errors | ForEach-Object Message)"
}
#endregion

Write-Output "$Script:checks OEM kit checks passed ($($official.Count) standard steps covered)."
