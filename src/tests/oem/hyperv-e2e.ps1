<#
.SYNOPSIS
  End-to-end test of the offline OEM kit in a Hyper-V VM built from a Windows ISO.

.DESCRIPTION
  Needs membership in Hyper-V Administrators (elevation is not required). The script:
    1. Copies the current kit scripts from src\windows-dev-config\oem into -KitPath.
    2. Builds an answer ISO (autounattend.xml plus the kit) with IMAPI2.
    3. Creates a Gen 2 VM with vTPM and nested virtualization and NO network adapter.
    4. Installs Windows unattended. During specialize, the answer ISO copies the kit to
       C:\setup\devsetup, installs SetupComplete.cmd, and turns on the WSL features -- the
       same state an OEM image has after the README's offline-servicing steps.
    5. Lets SetupComplete.cmd run machine-setup.ps1, finishes OOBE with a local account,
       and signs in once so Active Setup runs user-setup.ps1.
    6. Waits for the per-user result, then collects logs, screenshots, and checks over
       PowerShell Direct into -ResultsPath.

  With -UseMedia it tests the README's installation-media option instead: build-media.ps1 builds
  one bootable ISO from -IsoPath and the kit, and the VM boots only that ISO. The test answer
  file (disk layout, OOBE, sign-in) goes in as -AnswerFile, so build-media adds its WSL step to
  it. A test-only probe account reports progress over PowerShell Direct.

  With -AuditMode it tests the README's audit-mode option mixed with the specialize pass: Windows
  installs into audit mode, the audit-mode Administrator runs machine-setup.ps1 -Skip <AuditSkip>
  twice (with a restart between), and sysprep generalizes with an answer file whose specialize
  pass runs machine-setup.ps1 hidden, which installs the skipped packages as SYSTEM before OOBE.

.EXAMPLE
  .\hyperv-e2e.ps1 -IsoPath C:\iso\win11.iso

.EXAMPLE
  .\hyperv-e2e.ps1 -IsoPath C:\iso\win11.iso -UseMedia

.EXAMPLE
  .\hyperv-e2e.ps1 -IsoPath C:\iso\win11.iso -AuditMode -AuditSkip Python
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $IsoPath,
    [string] $KitPath = 'C:\setup\devsetup',
    [string] $KitSource,
    [string] $VMName = 'devsetup-oem-e2e',
    [string] $VMRoot = (Join-Path $env:USERPROFILE 'Hyper-V'),
    [string] $ImageName = 'Windows 11 Pro',
    # Public KMS client setup key; it only selects the edition and never activates.
    [string] $ProductKey = 'W269N-WFGWX-YVC9B-4J6C9-T83GX',
    [string] $UserName = 'dev',
    [int] $MemoryGB = 8,
    [int] $ProcessorCount = 4,
    [int] $DiskGB = 128,
    [int] $TimeoutMinutes = 150,
    [string] $ResultsPath,
    [switch] $UseMedia,
    [switch] $AuditMode,
    [string[]] $AuditSkip = @('Python')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
if ($UseMedia -and $AuditMode) { throw 'Use either -UseMedia or -AuditMode, not both.' }

if (-not $KitSource) { $KitSource = Join-Path $PSScriptRoot '..\..\windows-dev-config\oem' }
$KitSource = (Resolve-Path -LiteralPath $KitSource).Path
$vmDirectory = Join-Path $VMRoot $VMName
if (-not $ResultsPath) {
    $ResultsPath = Join-Path $vmDirectory ("results-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $vmDirectory, $ResultsPath -Force | Out-Null

function Write-E2E {
    param([string] $Message, [string] $Color = 'Cyan')
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function New-E2EPassword {
    $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $bytes = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return 'Dv!' + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
}

function Get-E2EAnswerFile {
    # Media: build-media.ps1 brings the kit. Audit: install into audit mode. Sysprep: the answer file
    # passed to sysprep /generalize, whose specialize pass runs machine-setup.ps1 as the README shows.
    param([string] $Password, [switch] $Media, [switch] $Audit, [switch] $Sysprep)
    $user = [Security.SecurityElement]::Escape($UserName)
    $secret = [Security.SecurityElement]::Escape($Password)
    $component = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"'
    # The sysprep test runs exactly the specialize command the README documents.
    $specializeCommand = if ($Sysprep) {
        [regex]::Match([IO.File]::ReadAllText((Join-Path $KitSource 'README.md')), '<Path>([^<]*machine-setup\.ps1[^<]*)</Path>').Groups[1].Value
    }
        elseif (-not $Media) { 'cmd.exe /c for %d in (D E F G H I J K L M) do @if exist %d:\devsetup-specialize.cmd call %d:\devsetup-specialize.cmd %d:' }
    $specialize = if ($specializeCommand) { @"
    <component name="Microsoft-Windows-Deployment" $component>
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>$specializeCommand</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
"@ } else { '' }
    # Test-only administrator for PowerShell Direct, so polling never signs in as the user under test.
    $probe = if ($Media) { @"
          <LocalAccount wcm:action="add">
            <Name>$Script:ProbeUser</Name><Group>Administrators</Group>
            <Password><Value>$secret</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
"@ } else { '' }
    $oobe = if ($Audit) { @"
    <component name="Microsoft-Windows-Deployment" $component>
      <Reseal><Mode>Audit</Mode></Reseal>
    </component>
"@ } else { @"
    <component name="Microsoft-Windows-Shell-Setup" $component>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$user</Name><Group>Administrators</Group>
            <Password><Value>$secret</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
$probe        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled><Username>$user</Username><LogonCount>1</LogonCount>
        <Password><Value>$secret</Value><PlainText>true</PlainText></Password>
      </AutoLogon>
    </component>
"@ }
    $windowsPE = if ($Sysprep) { '' } else { @"
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" $component>
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" $component>
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>$ImageName</Value></MetaData></InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <ProductKey><Key>$ProductKey</Key><WillShowUI>OnError</WillShowUI></ProductKey>
      </UserData>
    </component>
  </settings>
"@ }
    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
$windowsPE  <settings pass="specialize">
$specialize    <component name="Microsoft-Windows-Shell-Setup" $component>
      <ComputerName>DEVSETUP-E2E</ComputerName>
      <TimeZone>Pacific Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $component>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
$oobe  </settings>
</unattend>
"@
}

# Simulates the OEM's offline image prep: kit at C:\setup\devsetup, SetupComplete.cmd, WSL features on.
$Script:SpecializeScript = @'
@echo off
set LOG=C:\Windows\Temp\devsetup-specialize.txt
robocopy "%~1\devsetup" "C:\setup\devsetup" /E /A-:R /R:1 /W:1 /NP /NFL /NDL > "%LOG%"
mkdir C:\Windows\Setup\Scripts 2>nul
copy /y "C:\setup\devsetup\SetupComplete.cmd" "C:\Windows\Setup\Scripts\SetupComplete.cmd" >> "%LOG%"
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart >> "%LOG%"
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart >> "%LOG%"
exit /b 0
'@

# Audit mode: only the kit is copied; the README's audit-mode steps do the rest. The probe account
# (an administrator) lets the harness drive audit mode over PowerShell Direct.
$Script:AuditSpecializeScript = @'
@echo off
set LOG=C:\Windows\Temp\devsetup-specialize.txt
robocopy "%~1\devsetup" "C:\setup\devsetup" /E /A-:R /R:1 /W:1 /NP /NFL /NDL > "%LOG%"
rem net user stops at a confirmation prompt for passwords longer than 14 characters and ignores piped input.
powershell.exe -NoProfile -Command "New-LocalUser -Name '{0}' -Password (ConvertTo-SecureString '{1}' -AsPlainText -Force) -PasswordNeverExpires | Out-Null; Add-LocalGroupMember -Group Administrators -Member '{0}'" >> "%LOG%" 2>&1
exit /b 0
'@

function New-E2EIsoImage {
    param(
        [Parameter(Mandatory)] [string] $StagingPath,
        [Parameter(Mandatory)] [string] $KitPath,
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not ('DevSetupIsoWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class DevSetupIsoWriter {
    public static void Write(object source, string path) {
        IStream stream = (IStream)source;
        byte[] buffer = new byte[1 << 20];
        IntPtr read = Marshal.AllocHGlobal(4);
        try {
            using (FileStream file = File.Create(path)) {
                while (true) {
                    stream.Read(buffer, buffer.Length, read);
                    int count = Marshal.ReadInt32(read);
                    if (count <= 0) { break; }
                    file.Write(buffer, 0, count);
                }
            }
        } finally {
            Marshal.FreeHGlobal(read);
        }
    }
}
'@
    }
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.ChooseImageDefaultsForMediaType(13)
    $image.FileSystemsToCreate = 4
    $image.VolumeName = 'DEVSETUP'
    $image.Root.AddTree($StagingPath, $false)
    $image.Root.AddTree($KitPath, $true)
    $result = $image.CreateResultImage()
    [DevSetupIsoWriter]::Write($result.ImageStream, $Path)
}

function Send-E2EKeys {
    param([int] $Seconds = 12)
    $system = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
    $keyboard = Get-CimAssociatedInstance -InputObject $system -ResultClassName Msvm_Keyboard
    for ($i = 0; $i -lt ($Seconds * 2); $i++) {
        Start-Sleep -Milliseconds 500
        $null = Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{ keyCode = [uint32]0x0D }
    }
}

function Save-E2EScreenshot {
    param([Parameter(Mandatory)] [string] $Name)
    try {
        $width = 1024; $height = 768
        $system = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
        $settings = Get-CimAssociatedInstance -InputObject $system -ResultClassName Msvm_VirtualSystemSettingData |
            Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }
        $service = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
        $shot = Invoke-CimMethod -InputObject $service -MethodName GetVirtualSystemThumbnailImage -Arguments @{
            TargetSystem = $settings; WidthPixels = [uint16]$width; HeightPixels = [uint16]$height
        }
        if ($shot.ReturnValue -ne 0 -or -not $shot.ImageData) { return }
        Add-Type -AssemblyName System.Drawing
        $bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
        $data = $bitmap.LockBits([System.Drawing.Rectangle]::new(0, 0, $width, $height), 'WriteOnly', $bitmap.PixelFormat)
        [Runtime.InteropServices.Marshal]::Copy([byte[]]$shot.ImageData, 0, $data.Scan0, [Math]::Min($shot.ImageData.Length, $data.Stride * $height))
        $bitmap.UnlockBits($data)
        $bitmap.Save((Join-Path $ResultsPath "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
    } catch {
        Write-Verbose "Screenshot failed: $($_.Exception.Message)"
    }
}

# Test-only progress reporter: SYSTEM writes guest KVP values the host can read without credentials,
# so the harness never signs in (which would create the user's profile) before the real first sign-in.
$Script:StatusScript = @'
$key = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest'
while ($true) {
    # New-Item -Force on an existing key deletes its values, which also breaks the KVP service's watch.
    if (-not (Test-Path -Path $key)) { New-Item -Path $key -Force | Out-Null }
    $profiles = @(Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue)
    $values = @{
        DevSetupMachine  = [string](Test-Path 'C:\ProgramData\CalmOS-Offline\machine-setup-result.json')
        DevSetupUser     = [string](@($profiles | Where-Object { Test-Path (Join-Path $_.FullName 'AppData\Local\CalmOS\offline-user-setup-result.json') }).Count -gt 0)
        DevSetupUserName = [string](Get-CimInstance Win32_ComputerSystem).UserName
    }
    foreach ($name in $values.Keys) { Set-ItemProperty -Path $key -Name $name -Value $values[$name] }
    Start-Sleep -Seconds 30
}
'@

function Get-E2EGuestStatus {
    $system = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
    $kvp = Get-CimAssociatedInstance -InputObject $system -ResultClassName Msvm_KvpExchangeComponent
    $items = @{}
    foreach ($item in @($kvp.GuestExchangeItems)) {
        if (-not $item) { continue }
        $xml = [xml]$item
        $name = ($xml.INSTANCE.PROPERTY | Where-Object { $_.NAME -eq 'Name' }).VALUE
        $data = ($xml.INSTANCE.PROPERTY | Where-Object { $_.NAME -eq 'Data' }).VALUE
        $items[$name] = $data
    }
    return $items
}

$Script:VerifyScript = {
    $ErrorActionPreference = 'Continue'
    # Keep the PATH Windows built for this PowerShell Direct logon; it is what a new terminal gets.
    # Rebuilding it with .NET would expand entries such as %NVM_HOME% that Windows leaves literal.
    $report = [ordered]@{}
    $report.Path = @($env:Path -split ';' | Where-Object { $_ })
    $report.UnexpandedPathEntries = @($report.Path | Where-Object { $_ -match '%[^%;]+%' })
    $report.MachineResult = Get-Content 'C:\ProgramData\CalmOS-Offline\machine-setup-result.json' -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    $report.UserResult = Get-Content (Join-Path $env:LOCALAPPDATA 'CalmOS\offline-user-setup-result.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    $report.Commands = [ordered]@{}
    foreach ($command in 'git', 'gh', 'az', 'code', 'dotnet', 'python', 'node', 'nvm', 'uv', 'copilot', 'oh-my-posh', 'winapp', 'pwsh', 'wt', 'winget', 'wsl') {
        $found = Get-Command $command -ErrorAction SilentlyContinue | Select-Object -First 1
        $report.Commands[$command] = if ($found) { $found.Source } else { $null }
    }
    $report.Apps = @(Get-AppxPackage | Where-Object { $_.Name -match 'WindowsTerminal|IntelligentTerminal|PowerShell|ohmyposh|winapp|DesktopAppInstaller' } |
        ForEach-Object { "$($_.Name) $($_.Version)" })
    $advanced = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -ErrorAction SilentlyContinue
    $theme = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
    $report.Settings = [ordered]@{
        HideFileExt        = $advanced.HideFileExt
        Hidden             = $advanced.Hidden
        LaunchTo           = $advanced.LaunchTo
        StartIris          = $advanced.Start_IrisRecommendations
        TaskbarEndTask     = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' -ErrorAction SilentlyContinue).TaskbarEndTask
        AppsUseLightTheme  = $theme.AppsUseLightTheme
        LongPathsEnabled   = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem').LongPathsEnabled
        CascadiaMonoNF     = Test-Path 'C:\Windows\Fonts\CascadiaMonoNF.ttf'
    }
    $terminal = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_*\LocalState\settings.json') -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($terminal) {
        $settings = Get-Content $terminal.FullName -Raw | ConvertFrom-Json
        $report.Terminal = [ordered]@{ DefaultProfile = $settings.defaultProfile; Font = $settings.profiles.defaults.font.face }
    }
    $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1'
    $report.OhMyPoshProfile = (Test-Path $profilePath) -and ((Get-Content $profilePath -Raw) -match 'oh-my-posh init pwsh')
    $env:WSL_UTF8 = '1'
    $report.WslDistros = @(& wsl.exe --list --quiet 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    $report.CopilotPlugins = if (Get-Command copilot -ErrorAction SilentlyContinue) { (& copilot plugin list --json 2>&1 | Out-String) }
    $report.WingetVersion = if (Get-Command winget -ErrorAction SilentlyContinue) { (& winget --version 2>&1 | Out-String).Trim() }
    $report.Network = @(Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) $($_.Status)" })
    [pscustomobject]$report
}

#region Main

$Script:ProbeUser = 'e2eprobe'
$password = New-E2EPassword
Set-Content -LiteralPath (Join-Path $ResultsPath 'credentials.txt') -Value "$UserName / $password"
$credential = [pscredential]::new($UserName, (ConvertTo-SecureString $password -AsPlainText -Force))
$probeCredential = [pscredential]::new($Script:ProbeUser, (ConvertTo-SecureString $password -AsPlainText -Force))

function Get-E2EMediaStatus {
    try {
        $status = Invoke-Command -VMName $VMName -Credential $probeCredential -ErrorAction Stop -ArgumentList $UserName -ScriptBlock {
            param($User)
            @{
                DevSetupMachine  = [string](Test-Path 'C:\ProgramData\CalmOS-Offline\machine-setup-result.json')
                DevSetupUser     = [string](Test-Path "C:\Users\$User\AppData\Local\CalmOS\offline-user-setup-result.json")
                DevSetupUserName = [string](Get-CimInstance Win32_ComputerSystem).UserName
            }
        }
        return $status
    } catch {
        return @{}
    }
}

function Invoke-E2EProbe {
    param([Parameter(Mandatory)] [scriptblock] $ScriptBlock, [object[]] $ArgumentList = @())
    Invoke-Command -VMName $VMName -Credential $probeCredential -ErrorAction Stop -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

# Waits until audit mode has signed the built-in Administrator in, and returns the boot time.
function Wait-E2EAuditDesktop {
    param([datetime] $After = [datetime]::MinValue, [int] $Minutes = 60)
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        try {
            $state = Invoke-E2EProbe -ScriptBlock {
                [pscustomobject]@{
                    # Windows 11 26H1 in audit mode sets this image state but not AuditInProgress.
                    Audit    = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState -eq 'IMAGE_STATE_SPECIALIZE_RESEAL_TO_AUDIT'
                    User     = [string](Get-CimInstance Win32_ComputerSystem).UserName
                    Explorer = [bool](Get-Process explorer -ErrorAction SilentlyContinue)
                    Boot     = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                }
            }
            if ($state.Audit -and $state.User -like '*\Administrator' -and $state.Explorer -and $state.Boot -gt $After) {
                return $state.Boot
            }
        } catch {
            Write-Verbose "Probe not ready: $($_.Exception.Message)"
        }
    }
    throw "Audit mode did not reach the Administrator desktop within $Minutes minutes."
}

# Runs a command in the guest as the probe administrator, elevated, as the README's technician
# would. Task Scheduler queues tasks while audit mode is in progress, so it runs over PowerShell Direct.
function Invoke-E2EAuditCommand {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Command)
    $exit = Invoke-E2EProbe -ArgumentList $Name, $Command -ScriptBlock {
        param($Name, $Command)
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
        $global:LASTEXITCODE = 0
        & ([scriptblock]::Create($Command)) *>&1 | Out-File -LiteralPath "C:\Windows\Temp\devsetup-e2e-$Name.txt" -Encoding utf8
        $LASTEXITCODE
    }
    $session = New-PSSession -VMName $VMName -Credential $probeCredential
    try {
        Copy-Item -FromSession $session -Path "C:\Windows\Temp\devsetup-e2e-$Name.txt" -Destination $ResultsPath -ErrorAction SilentlyContinue
    } finally {
        Remove-PSSession $session
    }
    return $exit
}

function Invoke-E2EAuditMode {
    Write-E2E 'Waiting for audit mode (built-in Administrator desktop)'
    $boot = Wait-E2EAuditDesktop
    Save-E2EScreenshot -Name '10-audit-desktop'
    # On 26H1, PowerShell Direct stops authenticating a few minutes into the first audit-mode boot
    # (no failed logon is recorded); after one restart it stays reliable.
    Write-E2E 'Audit mode: restarting once so PowerShell Direct stays reliable'
    Invoke-E2EProbe -ScriptBlock { shutdown.exe /r /t 5 /f } | Out-Null
    $boot = Wait-E2EAuditDesktop -After $boot -Minutes 20
    $skip = $AuditSkip -join ','
    $setup = "& 'C:\setup\devsetup\machine-setup.ps1' -PerUserApps -Skip $skip"

    Write-E2E "Audit mode: machine-setup.ps1 -PerUserApps -Skip $skip (first run)"
    $exit = Invoke-E2EAuditCommand -Name 'audit-run1' -Command $setup
    Write-E2E "  exit code $exit" 'DarkGray'
    Save-E2EScreenshot -Name '11-audit-run1'

    Write-E2E 'Audit mode: restarting so the WSL features finish turning on'
    Invoke-E2EProbe -ScriptBlock { shutdown.exe /r /t 5 /f } | Out-Null
    $boot = Wait-E2EAuditDesktop -After $boot -Minutes 20

    Write-E2E "Audit mode: machine-setup.ps1 -PerUserApps -Skip $skip (second run; expect already OK)"
    $exit = Invoke-E2EAuditCommand -Name 'audit-run2' -Command $setup
    Write-E2E "  exit code $exit" 'DarkGray'
    Save-E2EScreenshot -Name '12-audit-run2'
    $Script:AuditState = Invoke-E2EProbe -ScriptBlock {
        $result = Get-Content 'C:\ProgramData\CalmOS-Offline\machine-setup-result.json' -Raw | ConvertFrom-Json
        [pscustomobject]@{
            Completed     = $result.Completed
            Flagged       = @($result.Flagged)
            PythonPresent = Test-Path 'C:\Program Files\Python314\python.exe'
        }
    }
    Write-E2E "  completed=$($Script:AuditState.Completed) flagged=[$(@($Script:AuditState.Flagged) -join ', ')] python-before-sysprep=$($Script:AuditState.PythonPresent)" 'DarkGray'

    Write-E2E 'Generalizing with sysprep; its answer file runs machine-setup.ps1 in the specialize pass'
    $sysprepXml = Get-E2EAnswerFile -Password $password -Sysprep
    Invoke-E2EProbe -ArgumentList $sysprepXml -ScriptBlock {
        param($Xml)
        [IO.File]::WriteAllText('C:\Windows\Temp\devsetup-e2e-sysprep.xml', $Xml, [Text.UTF8Encoding]::new($false))
        # Audit mode opens the System Preparation Tool window at sign-in; a second sysprep refuses to start.
        Get-Process sysprep -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
    }
    # sysprep.exe is a GUI program: Start-Process -Wait keeps the session open until it shuts the VM down.
    $sysprepJob = Invoke-Command -VMName $VMName -Credential $probeCredential -AsJob -ScriptBlock {
        (Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\sysprep.exe" -Wait -PassThru -ArgumentList @(
            '/generalize', '/oobe', '/shutdown', '/quiet', '/unattend:C:\Windows\Temp\devsetup-e2e-sysprep.xml')).ExitCode
    }
    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-VM -Name $VMName).State -ne 'Off') {
        if ((Get-Date) -gt $deadline -or ($sysprepJob.State -eq 'Completed' -and (Get-VM -Name $VMName).State -ne 'Off')) {
            Start-Sleep -Seconds 30
            if ((Get-VM -Name $VMName).State -eq 'Off') { break }
            Save-E2EScreenshot -Name '13-sysprep-stuck'
            $session = New-PSSession -VMName $VMName -Credential $probeCredential
            try {
                Copy-Item -FromSession $session -Path 'C:\Windows\System32\Sysprep\Panther\setuperr.log', 'C:\Windows\System32\Sysprep\Panther\setupact.log' -Destination $ResultsPath -ErrorAction SilentlyContinue
            } finally {
                Remove-PSSession $session
            }
            throw "sysprep did not shut the VM down (exit code $(Receive-Job $sysprepJob -ErrorAction SilentlyContinue)); see setuperr.log in the results."
        }
        Start-Sleep -Seconds 15
    }
    Remove-Job $sysprepJob -Force -ErrorAction SilentlyContinue
    Write-E2E 'Sysprep finished; starting the generalized image (specialize, OOBE, first sign-in)'
    # A shipped device has no answer disc; only the sysprep answer file drives the next boot.
    Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $answerIso } | Remove-VMDvdDrive
    Start-VM -Name $VMName
}

Write-E2E "Refreshing kit scripts in $KitPath from $KitSource"
foreach ($file in @('_oem.ps1', 'machine-setup.ps1', 'user-setup.ps1', 'SetupComplete.cmd', 'README.md')) {
    $source = Join-Path $KitSource $file
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $KitPath -Force }
}

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-E2E "Removing the previous $VMName VM"
    Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $VMName -Force
}
Get-ChildItem -LiteralPath $vmDirectory -Filter '*.vhdx' -ErrorAction SilentlyContinue | Remove-Item -Force

if ($UseMedia) {
    $answerPath = Join-Path $vmDirectory 'test-autounattend.xml'
    [IO.File]::WriteAllText($answerPath, (Get-E2EAnswerFile -Password $password -Media), [Text.UTF8Encoding]::new($false))
    $bootIso = Join-Path $vmDirectory 'devsetup-media.iso'
    Write-E2E "Building installation media with build-media.ps1 at $bootIso"
    & (Join-Path $KitSource 'build-media.ps1') -IsoPath $IsoPath -KitPath $KitPath -OutputPath $bootIso -AnswerFile $answerPath -NoPrompt
    Remove-Item -LiteralPath $answerPath -Force
} else {
    $staging = Join-Path $vmDirectory 'answer'
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null
    [IO.File]::WriteAllText((Join-Path $staging 'autounattend.xml'), (Get-E2EAnswerFile -Password $password -Audit:$AuditMode), [Text.UTF8Encoding]::new($false))
    $specialize = $Script:SpecializeScript + "`r`n"
    $specialize = $specialize.Replace('exit /b 0', @"
copy /y "%~1\devsetup-e2e-status.ps1" C:\Windows\Temp\devsetup-e2e-status.ps1 >> "%LOG%"
schtasks.exe /create /f /tn DevSetupE2EStatus /ru SYSTEM /sc onstart /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Windows\Temp\devsetup-e2e-status.ps1" >> "%LOG%"
exit /b 0
"@)
    if ($AuditMode) { $specialize = $Script:AuditSpecializeScript.Replace('{0}', $Script:ProbeUser).Replace('{1}', $password) + "`r`n" }
    [IO.File]::WriteAllText((Join-Path $staging 'devsetup-specialize.cmd'), $specialize, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $staging 'devsetup-e2e-status.ps1'), $Script:StatusScript, [Text.UTF8Encoding]::new($false))
    $answerIso = Join-Path $vmDirectory 'answer.iso'
    Write-E2E "Building the answer ISO (autounattend.xml + kit) at $answerIso"
    New-E2EIsoImage -StagingPath $staging -KitPath $KitPath -Path $answerIso
    Write-E2E "  $([Math]::Round((Get-Item $answerIso).Length / 1GB, 2)) GB" 'DarkGray'
}

Write-E2E "Creating VM $VMName (Gen 2, vTPM, nested virtualization, no network)"
$vm = New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ([int64]$MemoryGB * 1GB) -Path $VMRoot `
    -NewVHDPath (Join-Path $vmDirectory "$VMName.vhdx") -NewVHDSizeBytes ([int64]$DiskGB * 1GB)
Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
Set-VMProcessor -VM $vm -Count $ProcessorCount -ExposeVirtualizationExtensions $true
Get-VMNetworkAdapter -VM $vm | Remove-VMNetworkAdapter
Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
Enable-VMTPM -VM $vm
if ($UseMedia) {
    # The one disc stands in for the USB drive made from the same ISO.
    $windowsDvd = Add-VMDvdDrive -VM $vm -Path $bootIso -Passthru
} else {
    $windowsDvd = Add-VMDvdDrive -VM $vm -Path $IsoPath -Passthru
    Add-VMDvdDrive -VM $vm -Path $answerIso | Out-Null
}
Set-VMFirmware -VM $vm -FirstBootDevice $windowsDvd
Set-VM -VM $vm -AutomaticCheckpointsEnabled $false

$started = Get-Date
Start-VM -VM $vm
Write-E2E 'Booting Windows Setup from the ISO'
Send-E2EKeys -Seconds 12
Start-Sleep -Seconds 20
Save-E2EScreenshot -Name '00-setup'
$Script:AuditState = $null
if ($AuditMode) { Invoke-E2EAuditMode }

$deadline = $started.AddMinutes($TimeoutMinutes)
$lastStatus = ''
$lastShot = Get-Date
$shot = 1
$done = $false
$status = @{}
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    # Once the machine part is done, the first sign-in is near: take frequent shots to catch any window.
    $interval = if ($status['DevSetupMachine'] -eq 'True') { 15 } else { 180 }
    if (((Get-Date) - $lastShot).TotalSeconds -ge $interval) {
        Save-E2EScreenshot -Name ('{0:000}-progress' -f $shot)
        $shot++
        $lastShot = Get-Date
    }
    $status = if ($UseMedia -or $AuditMode) { Get-E2EMediaStatus } else { Get-E2EGuestStatus }
    $summary = 'machine={0} user={1} logged-on={2}' -f $status['DevSetupMachine'], $status['DevSetupUser'], $status['DevSetupUserName']
    if ($summary -ne $lastStatus) {
        Write-E2E "  [$([int]((Get-Date) - $started).TotalMinutes) min] $summary" 'DarkGray'
        $lastStatus = $summary
    }
    if ($status['DevSetupUser'] -eq 'True') {
        $done = $true
        break
    }
}

# Keep watching the desktop for a minute after setup reports done.
foreach ($i in 1..4) {
    Start-Sleep -Seconds 15
    Save-E2EScreenshot -Name ('zz-final-{0}' -f $i)
}
$elapsed = [int]((Get-Date) - $started).TotalMinutes
if (-not $done) {
    Write-E2E "Timed out after $elapsed minutes; collecting what is available." 'Yellow'
}

Write-E2E 'Collecting logs over PowerShell Direct'
$session = $null
try {
    $session = New-PSSession -VMName $VMName -Credential $credential
    $files = @(
        'C:\ProgramData\CalmOS-Offline\machine-setup-log.txt',
        'C:\ProgramData\CalmOS-Offline\machine-setup-result.json',
        'C:\Windows\Temp\devsetup-machine-setup.txt',
        'C:\Windows\Temp\devsetup-specialize.txt',
        'C:\Windows\Panther\UnattendGC\setupact.log',
        "C:\Users\$UserName\AppData\Local\CalmOS\offline-user-setup-log.txt",
        "C:\Users\$UserName\AppData\Local\CalmOS\offline-user-setup-result.json"
    )
    if ($AuditMode) {
        $files += @('C:\Windows\Temp\devsetup-e2e-sysprep.xml', 'C:\Windows\System32\Sysprep\Panther\setuperr.log')
    }
    foreach ($file in $files) {
        try {
            Copy-Item -FromSession $session -Path $file -Destination $ResultsPath -ErrorAction Stop
        } catch {
            Write-E2E "  missing: $file" 'DarkYellow'
        }
    }
    $report = Invoke-Command -Session $session -ScriptBlock $Script:VerifyScript
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $ResultsPath 'verify.json')
} finally {
    if ($session) { Remove-PSSession $session }
}

$pathOk = $true
if (-not $report) {
    $pathOk = $false
    Write-E2E 'verify.json was not collected, so the PATH check could not run.' 'Red'
} elseif (@($report.UnexpandedPathEntries).Count -gt 0) {
    $pathOk = $false
    Write-E2E "PATH check failed: a new logon's PATH has unexpanded entries: $(@($report.UnexpandedPathEntries) -join '; ')" 'Red'
} else {
    Write-E2E "PATH check passed: no unexpanded entries in a new logon's PATH." 'Green'
}

$passed = $done -and $pathOk
if ($AuditMode -and $report) {
    # The skipped packages must be absent after audit mode and present for the user after OOBE.
    $machine = $report.MachineResult
    $machineOk = $machine -and $machine.Completed -and @($machine.Flagged).Count -eq 0
    $user = $report.UserResult
    $userOk = $user -and $user.Completed -and @($user.Flagged).Count -eq 0
    Write-E2E ("Audit mode check: user part completed={0} flagged=[{1}]" -f $(if ($user) { $user.Completed } else { 'missing' }),
        $(if ($user) { @($user.Flagged) -join ', ' } else { '' })) $(if ($userOk) { 'Green' } else { 'Red' })
    $passed = $passed -and $userOk
    $pythonOk = $Script:AuditState -and -not $Script:AuditState.PythonPresent -and $report.Commands.python
    if ($AuditSkip -notcontains 'Python') { $pythonOk = $true }
    $color = if ($machineOk -and $pythonOk) { 'Green' } else { 'Red' }
    Write-E2E ("Audit mode check: machine part after specialize completed={0} flagged=[{1}]; Python before sysprep={2}, after OOBE={3}" -f
        $(if ($machine) { $machine.Completed } else { 'missing' }), $(if ($machine) { @($machine.Flagged) -join ', ' } else { '' }),
        $(if ($Script:AuditState) { $Script:AuditState.PythonPresent } else { 'unknown' }), $report.Commands.python) $color
    $passed = $passed -and $machineOk -and $pythonOk
}
Write-E2E "Finished in $elapsed minutes. Results: $ResultsPath" $(if ($passed) { 'Green' } else { 'Yellow' })
Write-E2E "VM $VMName is kept for inspection (password in credentials.txt). Remove it with: Remove-VM $VMName -Force" 'DarkGray'
if (-not $passed) { exit 1 }

#endregion
