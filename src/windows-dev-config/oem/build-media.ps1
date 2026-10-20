<#
.SYNOPSIS
  Builds Windows installation media that sets up Windows Dev Config offline.

.DESCRIPTION
  Run on the technician PC after download.ps1. It puts these on Windows 11 installation media:

    sources\$OEM$\$1\setup\devsetup\                 the offline kit (Windows Setup copies it to C:\setup\devsetup)
    sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd  starts machine-setup.ps1 as SYSTEM after setup
    autounattend.xml                                  turns on the WSL features while Windows installs

  The Windows image itself is not modified, and Setup and OOBE stay interactive unless you pass
  your own answer file with -AnswerFile (the WSL step is added to it). Three ways to build:

    -OutputPath   a bootable ISO (about 10 GB). No elevation. Write it to USB with Rufus.
    -UsbDrive     erases a USB drive and writes FAT32 media, splitting install.wim into
                  install.swm files under 4 GB. Boots on every UEFI PC. Needs an elevated shell.
    -AddToUsb     adds the kit to existing Windows installation media, for example a USB drive
                  made with the Media Creation Tool. No elevation; nothing else is changed.

.EXAMPLE
  .\build-media.ps1 -IsoPath D:\iso\Win11_x64.iso -OutputPath D:\iso\Win11_x64_devsetup.iso

.EXAMPLE
  .\build-media.ps1 -IsoPath D:\iso\Win11_x64.iso -UsbDrive E:

.EXAMPLE
  .\build-media.ps1 -AddToUsb E:
#>

[CmdletBinding(DefaultParameterSetName = 'Iso')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Iso')]
    [Parameter(Mandatory, ParameterSetName = 'Usb')]
    [string] $IsoPath,

    [Parameter(Mandatory, ParameterSetName = 'Iso')]
    [string] $OutputPath,

    # Drive letter of a USB drive to erase and write as FAT32 installation media.
    [Parameter(Mandatory, ParameterSetName = 'Usb')]
    [ValidatePattern('^[A-Za-z]:?\\?$')]
    [string] $UsbDrive,

    # Drive letter or root folder of existing Windows installation media to add the kit to.
    [Parameter(Mandatory, ParameterSetName = 'AddToUsb')]
    [string] $AddToUsb,

    [string] $KitPath = 'C:\setup\devsetup',

    # An existing unattend file to use as autounattend.xml; the WSL feature step is added to it.
    [string] $AnswerFile,

    # Boots without "Press any key to boot from CD or DVD" (useful for virtual machines).
    [Parameter(ParameterSetName = 'Iso')]
    [switch] $NoPrompt,

    # -UsbDrive: skips the erase confirmation. -AddToUsb: replaces an existing sources\$OEM$ folder.
    [Parameter(ParameterSetName = 'Usb')]
    [Parameter(ParameterSetName = 'AddToUsb')]
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$KitPath = (Resolve-Path -LiteralPath $KitPath).Path.TrimEnd('\')
foreach ($file in @('devsetup.json', 'machine-setup.ps1', 'user-setup.ps1', '_oem.ps1', 'SetupComplete.cmd')) {
    if (-not (Test-Path -LiteralPath (Join-Path $KitPath $file))) {
        throw "$KitPath is not a complete kit (missing $file). Run download.ps1 first."
    }
}
$manifest = [IO.File]::ReadAllText((Join-Path $KitPath 'devsetup.json')) | ConvertFrom-Json
$unattendArchitecture = if ($manifest.Architecture -eq 'arm64') { 'arm64' } else { 'amd64' }
$Script:Fat32MaxFile = 4GB - 1

function Write-Media {
    param([string] $Message, [string] $Color = 'Cyan')
    Write-Host $Message -ForegroundColor $Color
}

function Get-MediaFolderSize {
    param([Parameter(Mandatory)] [string] $Path)
    return [int64](Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
}

#region Answer file

$Script:UnattendNamespace = 'urn:schemas-microsoft-com:unattend'
$Script:WcmNamespace = 'http://schemas.microsoft.com/WMIConfig/2002/State'

# Enabled during the specialize pass, the features are active after Setup's next restart, so Ubuntu
# can be added at the first sign-in. A hidden PowerShell keeps a console window off the screen.
$Script:WslFeatureCommands = @(
    @{ Description = 'Windows Dev Config: turn on Virtual Machine Platform'; Feature = 'VirtualMachinePlatform' }
    @{ Description = 'Windows Dev Config: turn on Windows Subsystem for Linux'; Feature = 'Microsoft-Windows-Subsystem-Linux' }
)

function New-MediaElement {
    param(
        [Parameter(Mandatory)] [xml] $Document,
        [Parameter(Mandatory)] [Xml.XmlElement] $Parent,
        [Parameter(Mandatory)] [string] $Name,
        [string] $Text
    )
    $element = $Document.CreateElement($Name, $Script:UnattendNamespace)
    if ($PSBoundParameters.ContainsKey('Text')) { $element.InnerText = $Text }
    [void]$Parent.AppendChild($element)
    return $element
}

# Adds the WSL feature commands to an answer file (or a new one); running it twice adds them once.
function Get-MediaAnswerFile {
    param([string] $BasePath)
    $text = if ($BasePath -and (Test-Path -LiteralPath $BasePath)) { [IO.File]::ReadAllText($BasePath) } else { '' }
    if (-not $text -or -not ([regex]::IsMatch($text, '<unattend[\s>]'))) {
        $text = "<?xml version=`"1.0`" encoding=`"utf-8`"?><unattend xmlns=`"$Script:UnattendNamespace`"></unattend>"
    }
    [xml]$document = $text
    $ns = New-Object Xml.XmlNamespaceManager($document.NameTable)
    $ns.AddNamespace('u', $Script:UnattendNamespace)

    $settings = $document.SelectSingleNode("/u:unattend/u:settings[@pass='specialize']", $ns)
    if (-not $settings) {
        $settings = New-MediaElement -Document $document -Parent $document.DocumentElement -Name 'settings'
        $settings.SetAttribute('pass', 'specialize')
    }
    $component = $settings.SelectSingleNode("u:component[@name='Microsoft-Windows-Deployment']", $ns)
    if (-not $component) {
        $component = New-MediaElement -Document $document -Parent $settings -Name 'component'
        foreach ($attribute in @{
            name = 'Microsoft-Windows-Deployment'; processorArchitecture = $unattendArchitecture
            publicKeyToken = '31bf3856ad364e35'; language = 'neutral'; versionScope = 'nonSxS'
        }.GetEnumerator()) {
            $component.SetAttribute($attribute.Key, $attribute.Value)
        }
    }
    $run = $component.SelectSingleNode('u:RunSynchronous', $ns)
    if (-not $run) { $run = New-MediaElement -Document $document -Parent $component -Name 'RunSynchronous' }
    $orders = @($run.SelectNodes('u:RunSynchronousCommand/u:Order', $ns) | ForEach-Object { [int]$_.InnerText })
    $order = if ($orders.Count) { ($orders | Measure-Object -Maximum).Maximum } else { 0 }
    $existing = @($run.SelectNodes('u:RunSynchronousCommand/u:Description', $ns) | ForEach-Object { $_.InnerText })

    foreach ($command in $Script:WslFeatureCommands) {
        if ($existing -contains $command.Description) { continue }
        $order++
        $entry = New-MediaElement -Document $document -Parent $run -Name 'RunSynchronousCommand'
        $action = $document.CreateAttribute('wcm', 'action', $Script:WcmNamespace)
        $action.Value = 'add'
        [void]$entry.Attributes.Append($action)
        [void](New-MediaElement -Document $document -Parent $entry -Name 'Order' -Text ([string]$order))
        [void](New-MediaElement -Document $document -Parent $entry -Name 'Description' -Text $command.Description)
        [void](New-MediaElement -Document $document -Parent $entry -Name 'Path' -Text (
            "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command `"dism.exe /online /enable-feature /featurename:$($command.Feature) /all /norestart /quiet`""))
    }
    return $document
}

#endregion

#region Writing to installation media on a drive or folder

function Assert-InstallMedia {
    param([Parameter(Mandatory)] [string] $Root)
    $image = @('install.wim', 'install.esd', 'install.swm') | Where-Object { Test-Path -LiteralPath (Join-Path $Root "sources\$_") }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'setup.exe')) -or -not $image) {
        throw "$Root is not Windows installation media (it needs setup.exe and sources\install.wim, .esd, or .swm)."
    }
}

# Copies the kit and SetupComplete.cmd into sources\$OEM$ and merges autounattend.xml at the root.
function Add-MediaKit {
    param([Parameter(Mandatory)] [string] $Root)
    $oem = Join-Path $Root 'sources\$OEM$'
    if (Test-Path -LiteralPath $oem) {
        if (-not $Force) {
            throw "$oem already exists. Pass -Force to replace it (anything else in it is removed too)."
        }
        Write-Media "  Replacing $oem"
        Remove-Item -LiteralPath $oem -Recurse -Force
    }

    $volume = Get-Volume -FilePath $Root -ErrorAction SilentlyContinue
    $kitSize = Get-MediaFolderSize -Path $KitPath
    if ($volume) {
        if ($volume.FileSystem -eq 'FAT32') {
            $large = @(Get-ChildItem -LiteralPath $KitPath -Recurse -File | Where-Object { $_.Length -gt $Script:Fat32MaxFile })
            if ($large.Count) { throw "FAT32 cannot hold $($large[0].FullName) (over 4 GB)." }
        }
        if ($volume.SizeRemaining -lt $kitSize + 64MB) {
            throw "$Root needs $([Math]::Round($kitSize / 1GB, 1)) GB free for the kit; it has $([Math]::Round($volume.SizeRemaining / 1GB, 1)) GB."
        }
    }

    Write-Media "  Copying the kit ($([Math]::Round($kitSize / 1GB, 2)) GB) to sources\`$OEM`$\`$1\setup\devsetup"
    $kitTarget = Join-Path $oem '$1\setup\devsetup'
    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    & $robocopy $KitPath $kitTarget /E /R:1 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying the kit to $kitTarget failed (robocopy exit code $LASTEXITCODE)." }
    $scripts = New-Item -ItemType Directory -Path (Join-Path $oem '$$\Setup\Scripts') -Force
    Copy-Item -LiteralPath (Join-Path $KitPath 'SetupComplete.cmd') -Destination $scripts.FullName -Force

    # The caller's answer file wins; otherwise the media's own autounattend.xml is kept and extended.
    $target = Join-Path $Root 'autounattend.xml'
    $base = if ($AnswerFile) { (Resolve-Path -LiteralPath $AnswerFile).Path } else { $target }
    $document = Get-MediaAnswerFile -BasePath $base
    if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath "$target.bak")) {
        Copy-Item -LiteralPath $target -Destination "$target.bak"
    }
    $document.Save($target)

    if ((Get-MediaFolderSize -Path $kitTarget) -ne $kitSize) {
        throw "The kit on $Root does not match $KitPath after copying. Check the drive and try again."
    }
    Write-Media '  Added sources\$OEM$ and autounattend.xml.' 'DarkGray'
}

#endregion

#region ISO writer

if (-not ('DevSetupIsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class DevSetupIsoWriter {
    public static void Write(object source, string path) {
        IStream stream = (IStream)source;
        byte[] buffer = new byte[4 << 20];
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

function New-MediaIso {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Work
    )
    $bootImage = Join-Path $Source ('efi\microsoft\boot\' + $(if ($NoPrompt) { 'efisys_noprompt.bin' } else { 'efisys.bin' }))
    if (-not (Test-Path -LiteralPath $bootImage)) { throw "The ISO has no UEFI boot image ($bootImage)." }
    if (Test-Path -LiteralPath (Join-Path $Source 'autounattend.xml')) {
        throw 'The ISO already contains autounattend.xml. Pass it with -AnswerFile so the WSL step can be added to it.'
    }
    if (Test-Path -LiteralPath (Join-Path $Source 'sources\$OEM$')) {
        throw 'The ISO already contains sources\$OEM$. Use -AddToUsb on media made from it, with -Force to replace it.'
    }

    # The kit is added straight from -KitPath, so only the small files are staged.
    $oem = Join-Path $Work '$OEM$'
    $scripts = New-Item -ItemType Directory -Path (Join-Path $oem '$$\Setup\Scripts') -Force
    Copy-Item -LiteralPath (Join-Path $KitPath 'SetupComplete.cmd') -Destination $scripts.FullName
    New-Item -ItemType Directory -Path (Join-Path $oem '$1\setup') -Force | Out-Null
    $rootFiles = New-Item -ItemType Directory -Path (Join-Path $Work 'root')
    (Get-MediaAnswerFile -BasePath $AnswerFile).Save((Join-Path $rootFiles.FullName 'autounattend.xml'))

    Write-Media 'Building the image'
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    # Blu-ray sizing allows the Windows files plus the kit (over 10 GB), but it also picks UDF 2.50,
    # which Windows Boot Manager cannot read. Windows media uses UDF 1.02.
    $image.ChooseImageDefaultsForMediaType(18)
    $image.UDFRevision = 0x102
    $image.FileSystemsToCreate = 4
    $image.VolumeName = $Label.Substring(0, [Math]::Min(32, $Label.Length))
    $image.Root.AddTree($Source, $false)
    $image.Root.AddTree($rootFiles.FullName, $false)
    $sources = $image.Root.Item('sources')
    $sources.AddTree($oem, $true)
    $setupFolder = $sources.Item('$OEM$').Item('$1').Item('setup')
    $setupFolder.AddDirectory('devsetup')
    $setupFolder.Item('devsetup').AddTree($KitPath, $false)

    # UEFI El Torito boot entry, the same boot image Microsoft's own ISOs use.
    $bootStream = New-Object -ComObject ADODB.Stream
    try {
        $bootStream.Open()
        $bootStream.Type = 1
        $bootStream.LoadFromFile($bootImage)
        $boot = New-Object -ComObject IMAPI2FS.BootOptions
        $boot.AssignBootImage($bootStream)
        $boot.PlatformId = 0xEF
        $boot.Emulation = 0
        $image.BootImageOptions = $boot

        $result = $image.CreateResultImage()
        $size = [int64]$result.TotalBlocks * [int64]$result.BlockSize
        Write-Media "Writing $Path ($([Math]::Round($size / 1GB, 2)) GB)"
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [DevSetupIsoWriter]::Write($result.ImageStream, $Path)
    } finally {
        $bootStream.Close()
    }
}

#endregion

#region FAT32 USB drive

function Write-MediaUsb {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $DriveLetter
    )
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '-UsbDrive formats the drive and splits install.wim with DISM, which needs an elevated PowerShell.'
    }
    $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber
    if ([string]$disk.BusType -ne 'USB') { throw "${DriveLetter}: is on a $($disk.BusType) disk, not a USB drive." }
    if ($disk.IsBoot -or $disk.IsSystem) { throw "${DriveLetter}: is on this PC's system disk." }

    # Windows formats FAT32 volumes up to 32 GB, which holds Windows and the kit.
    $needed = (Get-MediaFolderSize -Path $Source) + (Get-MediaFolderSize -Path $KitPath) + 512MB
    $partitionMB = [int64][Math]::Floor([Math]::Min($disk.Size - 8MB, 32GB) / 1MB)
    if ($partitionMB * 1MB -lt $needed) {
        throw "Disk $($disk.Number) is too small: Windows and the kit need $([Math]::Ceiling($needed / 1GB)) GB. Use a 16 GB or larger USB drive."
    }

    $description = "disk $($disk.Number), $($disk.FriendlyName), $([Math]::Round($disk.Size / 1GB, 1)) GB"
    Write-Media "This erases everything on $description." 'Yellow'
    if (-not $Force) {
        $answer = Read-Host 'Type ERASE to continue'
        if ($answer -cne 'ERASE') { throw 'Cancelled; nothing was changed.' }
    }

    Write-Media "Formatting $description as FAT32"
    $script = Join-Path ([IO.Path]::GetTempPath()) ("devsetup-diskpart-" + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($script, @"
select disk $($disk.Number)
clean
create partition primary size=$partitionMB
format fs=fat32 quick label="WIN11DEV"
active
assign
exit
"@, [Text.Encoding]::ASCII)
    try {
        $output = & (Join-Path $env:SystemRoot 'System32\diskpart.exe') /s $script 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "diskpart failed (exit code $LASTEXITCODE): $output" }
    } finally {
        Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    Update-HostStorageCache
    $letter = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter })[0]
    if (-not $letter) { throw "The USB drive was formatted but has no drive letter. Assign one in Disk Management and run -AddToUsb." }
    $target = "${letter}:\"

    Write-Media "Copying the Windows files to $target"
    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    & $robocopy $Source $target /E /A-:R /XF install.wim /R:1 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying the Windows files failed (robocopy exit code $LASTEXITCODE)." }

    $wim = Join-Path $Source 'sources\install.wim'
    if (Test-Path -LiteralPath $wim) {
        if ((Get-Item -LiteralPath $wim).Length -gt $Script:Fat32MaxFile) {
            # Windows Setup reads install.swm, install2.swm, ... as one image.
            Write-Media 'Splitting install.wim into install.swm files under 4 GB (DISM, a few minutes)'
            $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
            $swm = Join-Path $target 'sources\install.swm'
            $output = & $dism /Split-Image "/ImageFile:$wim" "/SWMFile:$swm" /FileSize:3800 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "DISM could not split install.wim (exit code $LASTEXITCODE): $output" }
        } else {
            Copy-Item -LiteralPath $wim -Destination (Join-Path $target 'sources') -Force
        }
    }

    Add-MediaKit -Root $target
    return $target
}

#endregion

$work = Join-Path ([IO.Path]::GetTempPath()) ("devsetup-media-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$mountedIso = $null
try {
    if ($PSCmdlet.ParameterSetName -eq 'AddToUsb') {
        $root = if ($AddToUsb -match '^[A-Za-z]:?\\?$') { "$($AddToUsb.Substring(0, 1)):\" } else { (Resolve-Path -LiteralPath $AddToUsb).Path }
        Assert-InstallMedia -Root $root
        Write-Media "Adding the kit to $root"
        Add-MediaKit -Root $root
        Write-Media "Media ready: $root" 'Green'
        return
    }

    $IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
    Write-Media "Reading $IsoPath"
    $mountedIso = Mount-DiskImage -ImagePath $IsoPath -Access ReadOnly -PassThru
    $volume = $mountedIso | Get-Volume
    $source = "$($volume.DriveLetter):\"
    Assert-InstallMedia -Root $source
    $label = if ($volume.FileSystemLabel) { $volume.FileSystemLabel } else { 'WIN11_DEVSETUP' }

    if ($PSCmdlet.ParameterSetName -eq 'Usb') {
        $target = Write-MediaUsb -Source $source -DriveLetter $UsbDrive.Substring(0, 1).ToUpperInvariant()
        Write-Media "Media ready: $target" 'Green'
        Write-Media '  Boot the PC from this USB drive (UEFI). Windows Setup uses install.swm automatically.' 'DarkGray'
        return
    }

    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    New-MediaIso -Source $source -Label $label -Path $OutputPath -Work $work
    Write-Media "Media ready: $OutputPath" 'Green'
    Write-Media '  Write it to a USB drive with Rufus, or use -UsbDrive for a FAT32 drive, or boot it in a VM.' 'DarkGray'
} finally {
    if ($mountedIso) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
