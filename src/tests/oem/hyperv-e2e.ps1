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

.EXAMPLE
  .\hyperv-e2e.ps1 -IsoPath C:\iso\win11.iso

.EXAMPLE
  .\hyperv-e2e.ps1 -IsoPath C:\iso\win11.iso -UseMedia
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
    [switch] $UseMedia
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

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
    param([string] $Password, [switch] $Media)
    $user = [Security.SecurityElement]::Escape($UserName)
    $secret = [Security.SecurityElement]::Escape($Password)
    $component = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"'
    # The media brings the kit itself; only the answer-ISO test needs the specialize copy step.
    $specialize = if ($Media) { '' } else { @"
    <component name="Microsoft-Windows-Deployment" $component>
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd.exe /c for %d in (D E F G H I J K L M) do @if exist %d:\devsetup-specialize.cmd call %d:\devsetup-specialize.cmd %d:</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
"@ }
    # Test-only administrator for PowerShell Direct, so polling never signs in as the user under test.
    $probe = if ($Media) { @"
          <LocalAccount wcm:action="add">
            <Name>$Script:ProbeUser</Name><Group>Administrators</Group>
            <Password><Value>$secret</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
"@ } else { '' }
    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
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
  <settings pass="specialize">
$specialize    <component name="Microsoft-Windows-Shell-Setup" $component>
      <ComputerName>DEVSETUP-E2E</ComputerName>
      <TimeZone>Pacific Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $component>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
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
  </settings>
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
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $report = [ordered]@{}
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
    $report.CopilotPlugins = (& copilot plugin list --json 2>&1 | Out-String)
    $report.WingetVersion = (& winget --version 2>&1 | Out-String).Trim()
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
    [IO.File]::WriteAllText((Join-Path $staging 'autounattend.xml'), (Get-E2EAnswerFile -Password $password), [Text.UTF8Encoding]::new($false))
    $specialize = $Script:SpecializeScript + "`r`n"
    $specialize = $specialize.Replace('exit /b 0', @"
copy /y "%~1\devsetup-e2e-status.ps1" C:\Windows\Temp\devsetup-e2e-status.ps1 >> "%LOG%"
schtasks.exe /create /f /tn DevSetupE2EStatus /ru SYSTEM /sc onstart /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Windows\Temp\devsetup-e2e-status.ps1" >> "%LOG%"
exit /b 0
"@)
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
    $status = if ($UseMedia) { Get-E2EMediaStatus } else { Get-E2EGuestStatus }
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

Write-E2E "Finished in $elapsed minutes. Results: $ResultsPath" $(if ($done) { 'Green' } else { 'Yellow' })
Write-E2E "VM $VMName is kept for inspection (password in credentials.txt). Remove it with: Remove-VM $VMName -Force" 'DarkGray'
if (-not $done) { exit 1 }

#endregion
