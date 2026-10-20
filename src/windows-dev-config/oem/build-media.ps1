<#
.SYNOPSIS
  Builds bootable Windows installation media (ISO) that sets up Windows Dev Config offline.

.DESCRIPTION
  Run on the technician PC after download.ps1. It copies a Windows 11 ISO and adds:

    sources\$OEM$\$1\setup\devsetup\               the offline kit (Windows Setup copies it to C:\setup\devsetup)
    sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd  starts machine-setup.ps1 as SYSTEM after setup
    autounattend.xml                                turns on the WSL features while Windows installs

  The Windows image itself is not modified, and Setup and OOBE stay interactive unless you pass
  your own answer file with -AnswerFile (the WSL step is added to it). Write the ISO to a USB
  drive with a tool that handles install.wim files over 4 GB (see README.md).

  No elevation or Windows ADK is needed.

.EXAMPLE
  .\build-media.ps1 -IsoPath D:\iso\Win11_x64.iso -OutputPath D:\iso\Win11_x64_devsetup.iso
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $IsoPath,
    [Parameter(Mandatory)] [string] $OutputPath,
    [string] $KitPath = 'C:\setup\devsetup',
    # An existing unattend file to use as autounattend.xml; the WSL feature step is added to it.
    [string] $AnswerFile,
    # Boots without "Press any key to boot from CD or DVD" (useful for virtual machines).
    [switch] $NoPrompt
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
$KitPath = (Resolve-Path -LiteralPath $KitPath).Path.TrimEnd('\')
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
foreach ($file in @('devsetup.json', 'machine-setup.ps1', 'user-setup.ps1', '_oem.ps1', 'SetupComplete.cmd')) {
    if (-not (Test-Path -LiteralPath (Join-Path $KitPath $file))) {
        throw "$KitPath is not a complete kit (missing $file). Run download.ps1 first."
    }
}
$manifest = [IO.File]::ReadAllText((Join-Path $KitPath 'devsetup.json')) | ConvertFrom-Json
$unattendArchitecture = if ($manifest.Architecture -eq 'arm64') { 'arm64' } else { 'amd64' }

function Write-Media {
    param([string] $Message, [string] $Color = 'Cyan')
    Write-Host $Message -ForegroundColor $Color
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

function Get-MediaAnswerFile {
    [xml]$document = if ($AnswerFile) {
        [IO.File]::ReadAllText((Resolve-Path -LiteralPath $AnswerFile).Path)
    } else {
        "<?xml version=`"1.0`" encoding=`"utf-8`"?><unattend xmlns=`"$Script:UnattendNamespace`"></unattend>"
    }
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

    foreach ($command in $Script:WslFeatureCommands) {
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

#endregion

$work = Join-Path ([IO.Path]::GetTempPath()) ("devsetup-media-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$mounted = $null
$bootStream = $null
try {
    Write-Media "Reading $IsoPath"
    $mounted = Mount-DiskImage -ImagePath $IsoPath -Access ReadOnly -PassThru
    $volume = $mounted | Get-Volume
    $source = "$($volume.DriveLetter):\"
    $bootImage = Join-Path $source ('efi\microsoft\boot\' + $(if ($NoPrompt) { 'efisys_noprompt.bin' } else { 'efisys.bin' }))
    foreach ($required in @($bootImage, (Join-Path $source 'sources\install.wim'), (Join-Path $source 'setup.exe'))) {
        if (-not (Test-Path -LiteralPath $required)) {
            # install.esd media also works with Setup; only the boot image and setup.exe are required.
            if ($required -like '*install.wim' -and (Test-Path -LiteralPath (Join-Path $source 'sources\install.esd'))) { continue }
            throw "$IsoPath is not Windows installation media (missing $required)."
        }
    }
    if (Test-Path -LiteralPath (Join-Path $source 'autounattend.xml')) {
        throw "$IsoPath already contains autounattend.xml. Pass it with -AnswerFile so the WSL step can be added to it."
    }
    if (Test-Path -LiteralPath (Join-Path $source 'sources\$OEM$')) {
        throw "$IsoPath already contains sources\`$OEM`$. Merge the kit into it manually (see README.md)."
    }

    $oem = Join-Path $work '$OEM$'
    $scripts = New-Item -ItemType Directory -Path (Join-Path $oem '$$\Setup\Scripts') -Force
    Copy-Item -LiteralPath (Join-Path $KitPath 'SetupComplete.cmd') -Destination $scripts.FullName
    New-Item -ItemType Directory -Path (Join-Path $oem '$1\setup') -Force | Out-Null
    $rootFiles = New-Item -ItemType Directory -Path (Join-Path $work 'root')
    (Get-MediaAnswerFile).Save((Join-Path $rootFiles.FullName 'autounattend.xml'))

    Write-Media 'Building the image'
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    # Blu-ray sizing allows the Windows files plus the kit (over 10 GB), but it also picks UDF 2.50,
    # which Windows Boot Manager cannot read. Windows media uses UDF 1.02.
    $image.ChooseImageDefaultsForMediaType(18)
    $image.UDFRevision = 0x102
    $image.FileSystemsToCreate = 4
    $label = if ($volume.FileSystemLabel) { $volume.FileSystemLabel } else { 'WIN11_DEVSETUP' }
    $image.VolumeName = $label.Substring(0, [Math]::Min(32, $label.Length))
    $image.Root.AddTree($source, $false)
    $image.Root.AddTree($rootFiles.FullName, $false)
    $sources = $image.Root.Item('sources')
    $sources.AddTree($oem, $true)
    $setupFolder = $sources.Item('$OEM$').Item('$1').Item('setup')
    $setupFolder.AddDirectory('devsetup')
    $setupFolder.Item('devsetup').AddTree($KitPath, $false)

    # UEFI El Torito boot entry, the same boot image Microsoft's own ISOs use.
    $bootStream = New-Object -ComObject ADODB.Stream
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
    Write-Media "Writing $OutputPath ($([Math]::Round($size / 1GB, 2)) GB)"
    New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
    [DevSetupIsoWriter]::Write($result.ImageStream, $OutputPath)
} finally {
    if ($bootStream) { $bootStream.Close() }
    if ($mounted) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Media "Media ready: $OutputPath" 'Green'
Write-Media '  Write it to a USB drive with Rufus (it handles install.wim over 4 GB), or boot it in a VM.' 'DarkGray'
