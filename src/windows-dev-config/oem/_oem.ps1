<#
.SYNOPSIS
  Runtime helpers for the offline (OEM) Windows Dev Config kit.

.DESCRIPTION
  Dot-sourced by download.ps1, machine-setup.ps1, and user-setup.ps1. Runs on Windows
  PowerShell 5.1 (SYSTEM during Windows Setup) and PowerShell 7.

  Keep web access and encoding helpers out of this file and the setup scripts: devices run them
  offline with the Defender definitions in the Windows image, which flagged an earlier version
  that redirected the web download cmdlet to the kit. Download-time helpers live in
  _oem-download.ps1, and src/tests/oem/unit.ps1 enforces this.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevSetupKitVersion       = '1.0.0'
$Script:DevSetupManifestName     = 'devsetup.json'
$Script:DevSetupInstallRoot      = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'CalmOS'
$Script:DevSetupOfflineRoot      = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'CalmOS-Offline'
$Script:DevSetupActiveSetupKey   = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{5B0E7C3A-6D61-4C2B-9F3E-0D3C8A1E7F42}'
$Script:DevSetupUserStateKey     = 'HKCU:\Software\CalmOS\Offline'
$Script:DevSetupUserRunOnceName  = 'CalmOS-OfflineUserSetup'
$Script:DevSetupMachineStateKey  = 'HKLM:\SOFTWARE\CalmOS\Offline'
$Script:DevSetupMachineRetryTask = 'WindowsDevConfig-OfflineMachineRetry'
$Script:DevSetupPortableSource   = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
$Script:DevSetupProvisionedCache = $null

#region Offline runtime

function Read-DevSetupManifest {
    param(
        [Parameter(Mandatory)] [string] $Root
    )
    $path = Join-Path $Root $Script:DevSetupManifestName
    if (-not (Test-Path -LiteralPath $path)) {
        throw "The offline kit manifest is missing: $path. Run download.ps1 on an internet-connected PC first."
    }
    return ([IO.File]::ReadAllText($path) | ConvertFrom-Json)
}

function Get-DevSetupProvisionedPackages {
    param([switch] $Refresh)
    if ($Refresh -or $null -eq $Script:DevSetupProvisionedCache) {
        $Script:DevSetupProvisionedCache = @{
            Provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
            Packages    = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
        }
    }
    return $Script:DevSetupProvisionedCache
}

# Provisioned entries report bundle versions (an inbox Terminal shows 3001.x), so compare the
# staged or installed package version instead.
function Test-DevSetupMsixProvisioned {
    param(
        [Parameter(Mandatory)] [string] $IdentityName,
        [Parameter(Mandatory)] [string] $Version
    )
    $state = Get-DevSetupProvisionedPackages
    if (@($state.Provisioned | Where-Object { $_.DisplayName -eq $IdentityName }).Count -eq 0) {
        return $false
    }
    $wanted = [version]$Version
    return @($state.Packages | Where-Object { $_.Name -eq $IdentityName -and [version]$_.Version -ge $wanted }).Count -gt 0
}

function Get-DevSetupUninstallEntries {
    foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $displayName = $key.GetValue('DisplayName')
            [pscustomobject]@{ KeyName = $key.PSChildName; DisplayName = if ($displayName) { [string]$displayName } else { '' } }
        }
    }
}

function Get-DevSetupPortableLinkName {
    param([Parameter(Mandatory)] $Nested)
    if ($Nested.PortableCommandAlias) {
        $alias = [string]$Nested.PortableCommandAlias
        if (-not $alias.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $alias += '.exe' }
        return $alias
    }
    return (Split-Path -Leaf ([string]$Nested.RelativeFilePath))
}

function Test-DevSetupPackageInstalled {
    param(
        [Parameter(Mandatory)] $Entry
    )
    switch ($Entry.Kind) {
        'msix' {
            return (Test-DevSetupMsixProvisioned -IdentityName $Entry.Detection.IdentityName -Version $Entry.Detection.Version)
        }
        'portable' {
            $packageDir = Join-Path $env:ProgramFiles $Entry.Detection.PackageDirectory
            $links = Join-Path $env:ProgramFiles 'WinGet\Links'
            foreach ($nested in @($Entry.Portable)) {
                if (-not (Test-Path -LiteralPath (Join-Path $packageDir $nested.RelativeFilePath))) { return $false }
                if (-not (Test-Path -LiteralPath (Join-Path $links (Get-DevSetupPortableLinkName -Nested $nested)))) { return $false }
            }
            return $true
        }
        default {
            $codes = @($Entry.Detection.ProductCodes | Where-Object { $_ })
            $names = @()
            if ($Entry.Detection.PSObject.Properties['DisplayNames']) {
                $names = @($Entry.Detection.DisplayNames | Where-Object { $_ })
            }
            foreach ($arp in Get-DevSetupUninstallEntries) {
                if ($codes -contains $arp.KeyName) { return $true }
                foreach ($name in $names) {
                    # A following letter means a different product, such as Git versus GitHub CLI.
                    if ($arp.DisplayName -match ('^' + [regex]::Escape($name) + '(?![A-Za-z])')) { return $true }
                }
            }
            return $false
        }
    }
}

function Add-DevSetupMachinePath {
    param([Parameter(Mandatory)] [string] $Directory)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $current = (Get-Item -LiteralPath $key).GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if (@($current -split ';' | Where-Object { $_.TrimEnd('\') -ieq $Directory.TrimEnd('\') }).Count -gt 0) {
        return
    }
    $updated = (@($current.TrimEnd(';'), $Directory) | Where-Object { $_ }) -join ';'
    Set-ItemProperty -LiteralPath $key -Name 'Path' -Value $updated -Type ExpandString
}

# Same layout WinGet uses for machine-scope portable packages, so `winget list` recognizes them later.
function Install-DevSetupPortable {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] [string] $File
    )
    $packageDir = Join-Path $env:ProgramFiles $Entry.Detection.PackageDirectory
    $links = Join-Path $env:ProgramFiles 'WinGet\Links'
    New-Item -ItemType Directory -Path $packageDir, $links -Force | Out-Null
    Expand-Archive -LiteralPath $File -DestinationPath $packageDir -Force
    foreach ($nested in @($Entry.Portable)) {
        $target = Join-Path $packageDir $nested.RelativeFilePath
        if (-not (Test-Path -LiteralPath $target)) { throw "$($Entry.Id) is missing $($nested.RelativeFilePath) after extraction." }
        $link = Join-Path $links (Get-DevSetupPortableLinkName -Nested $nested)
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
        New-Item -ItemType SymbolicLink -Path $link -Target $target -Force | Out-Null
    }
    Add-DevSetupMachinePath -Directory $links
    $productCode = "$($Entry.Id)_$Script:DevSetupPortableSource"
    $arp = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
    New-Item -Path $arp -Force | Out-Null
    $values = [ordered]@{
        DisplayName             = $(if ($Entry.PackageName) { $Entry.PackageName } else { $Entry.Id })
        DisplayVersion          = $Entry.Version
        Publisher               = $Entry.Publisher
        InstallLocation         = $packageDir
        InstallDate             = (Get-Date).ToString('yyyyMMdd')
        UninstallString         = "winget uninstall --product-code $productCode"
        WinGetInstallerType     = 'portable'
        WinGetPackageIdentifier = $Entry.Id
        # WinGet matches its portable installs by this exact source identifier.
        WinGetSourceIdentifier  = $Script:DevSetupPortableSource
    }
    foreach ($name in $values.Keys) {
        New-ItemProperty -LiteralPath $arp -Name $name -Value ([string]$values[$name]) -PropertyType String -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $arp -Name 'InstallDirectoryCreated' -Value 1 -PropertyType DWord -Force | Out-Null
}

function Install-DevSetupPackage {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $LogDirectory
    )
    $file = Join-Path $Root $Entry.File
    if (-not (Test-Path -LiteralPath $file)) {
        throw "The offline installer is missing: $file. Copy the complete kit folder and try again."
    }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $Entry.Sha256) {
        throw "The offline installer failed its SHA-256 check: $file. Download the kit again."
    }

    switch ($Entry.Kind) {
        'msix' {
            $parameters = @{ Online = $true; PackagePath = $file; ErrorAction = 'Stop' }
            if ($Entry.PSObject.Properties['License'] -and $Entry.License) {
                $parameters.LicensePath = Join-Path $Root $Entry.License
            } else {
                $parameters.SkipLicense = $true
            }
            $dependencies = @($Entry.Dependencies | Where-Object { $_ } | ForEach-Object { Join-Path $Root $_ })
            if ($dependencies.Count) { $parameters.DependencyPackagePath = $dependencies }
            Add-AppxProvisionedPackage @parameters | Out-Null
            Get-DevSetupProvisionedPackages -Refresh | Out-Null
            return
        }
        'portable' {
            Install-DevSetupPortable -Entry $Entry -File $file
            return
        }
        'msi' {
            $log = Join-Path $LogDirectory "$($Entry.Name).msi.log"
            $arguments = "/i `"$file`" $($Entry.Arguments) /l*v `"$log`""
            $exitCode = Invoke-DevConfigProcess -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
                -Arguments @($arguments) -TimeoutSeconds 1800 -NoNewWindow
        }
        'exe' {
            $start = @{ FilePath = $file; TimeoutSeconds = 1800; NoNewWindow = $true }
            $arguments = [Environment]::ExpandEnvironmentVariables([string]$Entry.Arguments)
            if ($arguments) { $start.Arguments = @($arguments) }
            $exitCode = Invoke-DevConfigProcess @start
        }
        default {
            throw "Unsupported offline package kind '$($Entry.Kind)' for $($Entry.Id)."
        }
    }

    if (@($Entry.SuccessCodes | ForEach-Object { [int64]$_ }) -notcontains [int64]$exitCode) {
        throw "$($Entry.Id) $($Entry.Version) installer exited with code $exitCode."
    }
    if ($exitCode -in @(1641, 3010)) {
        Add-DevConfigNote -Message 'Some installers asked for a restart; it happens on its own during Windows setup.'
    }
}

# Kit files run as SYSTEM and at every sign-in, so only administrators may change them.
function Protect-DevSetupDirectory {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    $commands = @(
        @($Path, '/reset', '/T', '/C', '/Q'),
        @($Path, '/setowner', '*S-1-5-32-544', '/T', '/C', '/Q'),
        @($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/C', '/Q')
    )
    foreach ($arguments in $commands) {
        $output = & $icacls @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not restrict access to ${Path}: $($output | Out-String)"
        }
    }
}

function Get-DevSetupUserCommand {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath
    )
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return "`"$shell`" -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$ScriptPath`""
}

function Test-DevSetupActiveSetup {
    param([Parameter(Mandatory)] [string] $Command)
    if (-not (Test-Path -LiteralPath $Script:DevSetupActiveSetupKey)) { return $false }
    $key = Get-Item -LiteralPath $Script:DevSetupActiveSetupKey
    return $key.GetValue('StubPath') -eq $Command -and $key.GetValue('IsInstalled') -eq 1 -and
        $key.GetValue('Version') -eq ($Script:DevSetupKitVersion.Replace('.', ',') + ',0')
}

# Active Setup runs StubPath once per user profile, early in that user's first sign-in.
function Register-DevSetupActiveSetup {
    param([Parameter(Mandatory)] [string] $Command)
    $key = $Script:DevSetupActiveSetupKey
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -LiteralPath $key -Name '(default)' -Value 'Windows Dev Config (offline)'
    New-ItemProperty -LiteralPath $key -Name 'StubPath' -Value $Command -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'Version' -Value ($Script:DevSetupKitVersion.Replace('.', ',') + ',0') -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'IsInstalled' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'ComponentID' -Value 'CalmOS-Offline' -PropertyType String -Force | Out-Null
}

# Schedules (or clears) a hidden SYSTEM rerun of the machine part at startup, at most three times.
function Update-DevSetupMachineRetry {
    param(
        [Parameter(Mandatory)] [bool] $Needed,
        [Parameter(Mandatory)] [string] $Arguments
    )
    $key = $Script:DevSetupMachineStateKey
    $task = Get-ScheduledTask -TaskName $Script:DevSetupMachineRetryTask -ErrorAction SilentlyContinue
    if (-not $Needed) {
        if ($task) { Unregister-ScheduledTask -TaskName $Script:DevSetupMachineRetryTask -Confirm:$false }
        if (Test-Path -LiteralPath $key) { Remove-ItemProperty -LiteralPath $key -Name 'MachineRetries' -ErrorAction SilentlyContinue }
        return $false
    }
    # New-Item -Force on an existing key deletes its values, so create it only when missing.
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    $retries = [int](Get-Item -LiteralPath $key).GetValue('MachineRetries', 0)
    if ($retries -ge 3) {
        if ($task) { Unregister-ScheduledTask -TaskName $Script:DevSetupMachineRetryTask -Confirm:$false }
        return $false
    }
    New-ItemProperty -LiteralPath $key -Name 'MachineRetries' -Value ($retries + 1) -PropertyType DWord -Force | Out-Null
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $shell -Argument $Arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $Script:DevSetupMachineRetryTask -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Windows Dev Config (offline): reruns flagged machine setup steps' -Force | Out-Null
    return $true
}

#endregion

#region Hosting the official step engine

# Official phase files print their header from these script-scope values.
function Invoke-DevSetupPhase {
    param(
        [Parameter(Mandatory)] [int] $Index,
        [Parameter(Mandatory)] [int] $Total,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [string[]] $Steps
    )
    $Script:DevConfigPhaseIndex       = $Index
    $Script:DevConfigPhaseTotal       = $Total
    $Script:DevConfigPhaseTitle       = $Title
    $Script:DevConfigPhaseHeaderShown = $false
    $Script:DevConfigPhaseSteps       = $Steps
    try {
        & $ScriptBlock
    } finally {
        $Script:DevConfigPhaseSteps = $null
        Update-DevConfigSessionPath
    }
}

function Write-DevSetupSummary {
    param(
        [Parameter(Mandatory)] [string] $Name,
        $Failure
    )
    Show-DevConfigSilentSkipSummary
    Write-Host ''
    if ($Failure) {
        Write-Host "$Name stopped early." -ForegroundColor Red
        Write-Host "  $($Failure.Exception.Message)" -ForegroundColor Red
        Write-Host '  Nothing already applied was undone -- running this again picks up where it left off.' -ForegroundColor DarkGray
    } else {
        Write-Host "$Name complete." -ForegroundColor Green
    }
    $tally = $Script:DevConfigTally
    $parts = @("$($tally.Done) changed", "$($tally.AlreadyOk) already up to date")
    if ($tally.Warned -gt 0) { $parts += "$($tally.Warned) flagged" }
    Write-Host "  $($parts -join ', ')" -ForegroundColor DarkGray
    if ($tally.Warned -gt 0) {
        Write-Host "  Flagged: $($Script:DevConfigWarnedSteps -join ', ')" -ForegroundColor Yellow
    }
    foreach ($note in $Script:DevConfigNotes) {
        $color = if ($note.Warning) { 'Yellow' } else { 'DarkGray' }
        Write-Host "  $($note.Message)" -ForegroundColor $color
    }
    $logPath = Get-DevConfigLogPath
    if ($logPath) { Write-Host "  Full log: $logPath" -ForegroundColor DarkGray }
}

function Save-DevSetupResult {
    param(
        [Parameter(Mandatory)] [string] $Path,
        $Failure
    )
    $result = [ordered]@{
        KitVersion = $Script:DevSetupKitVersion
        Completed  = -not $Failure
        Error      = $(if ($Failure) { $Failure.Exception.Message } else { $null })
        Changed    = $Script:DevConfigTally.Done
        AlreadyOk  = $Script:DevConfigTally.AlreadyOk
        Flagged    = @($Script:DevConfigWarnedSteps)
        Notes      = @($Script:DevConfigNotes | ForEach-Object { $_.Message })
        FinishedAt = (Get-Date).ToString('o')
    }
    [IO.File]::WriteAllText($Path, ($result | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
}

#endregion
