<#
.SYNOPSIS
  Download-time helpers for the offline Windows Dev Config kit.

.DESCRIPTION
  Dot-sourced only by download.ps1 on the internet-connected PC: it reads WinGet manifests and
  builds the install plan in devsetup.json. Nothing here runs on the device being set up.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevSetupPortableSource = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
#region Minimal YAML reader for WinGet manifests

# WinGet writes block-style YAML (maps, sequences, plain or quoted scalars), which is all this reads.
function ConvertFrom-DevSetupYaml {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
    )
    $lines = New-Object System.Collections.Generic.List[object]
    foreach ($raw in ($Text -split "\r?\n")) {
        $trimmed = $raw.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed -eq '---' -or $trimmed -eq '...') {
            continue
        }
        $indent = $raw.Length - $raw.TrimStart(' ').Length
        $lines.Add([pscustomobject]@{ Indent = $indent; Text = $raw.Substring($indent).TrimEnd() })
    }
    if ($lines.Count -eq 0) {
        return [ordered]@{}
    }
    $state = @{ Lines = $lines; Index = 0 }
    return Read-DevSetupYamlBlock -State $state -Indent $lines[0].Indent
}

function Test-DevSetupYamlSequenceLine {
    param([Parameter(Mandatory)] [string] $Text)
    return ($Text -eq '-' -or $Text.StartsWith('- '))
}

function Read-DevSetupYamlBlock {
    param(
        [Parameter(Mandatory)] [hashtable] $State,
        [Parameter(Mandatory)] [int] $Indent
    )
    if (Test-DevSetupYamlSequenceLine -Text $State.Lines[$State.Index].Text) {
        return , (Read-DevSetupYamlSequence -State $State -Indent $Indent)
    }
    return Read-DevSetupYamlMapping -State $State -Indent $Indent
}

function Read-DevSetupYamlMapping {
    param(
        [Parameter(Mandatory)] [hashtable] $State,
        [Parameter(Mandatory)] [int] $Indent
    )
    $map = [ordered]@{}
    $lines = $State.Lines
    while ($State.Index -lt $lines.Count) {
        $line = $lines[$State.Index]
        if ($line.Indent -lt $Indent -or ($line.Indent -eq $Indent -and (Test-DevSetupYamlSequenceLine -Text $line.Text))) {
            break
        }
        if ($line.Indent -gt $Indent) {
            throw "Unexpected YAML indentation near '$($line.Text)'."
        }
        $match = [regex]::Match($line.Text, '^(?<key>[^:]+?):(?:\s+(?<value>.*))?$')
        if (-not $match.Success) {
            throw "Unsupported YAML line '$($line.Text)'."
        }
        $key = $match.Groups['key'].Value.Trim().Trim('"', "'")
        $value = $match.Groups['value'].Value
        $State.Index++
        if ($value) {
            $map[$key] = Read-DevSetupYamlScalar -State $State -First $value -ParentIndent $Indent
            continue
        }
        $map[$key] = $null
        if ($State.Index -lt $lines.Count) {
            $next = $lines[$State.Index]
            if ($next.Indent -gt $Indent) {
                $map[$key] = Read-DevSetupYamlBlock -State $State -Indent $next.Indent
            } elseif ($next.Indent -eq $Indent -and (Test-DevSetupYamlSequenceLine -Text $next.Text)) {
                $map[$key] = Read-DevSetupYamlSequence -State $State -Indent $Indent
            }
        }
    }
    return $map
}

function Read-DevSetupYamlSequence {
    param(
        [Parameter(Mandatory)] [hashtable] $State,
        [Parameter(Mandatory)] [int] $Indent
    )
    $items = New-Object System.Collections.Generic.List[object]
    $lines = $State.Lines
    while ($State.Index -lt $lines.Count) {
        $line = $lines[$State.Index]
        if ($line.Indent -ne $Indent -or -not (Test-DevSetupYamlSequenceLine -Text $line.Text)) {
            break
        }
        $content = if ($line.Text -eq '-') { '' } else { $line.Text.Substring(2).TrimStart() }
        $contentIndent = $Indent + ($line.Text.Length - $content.Length)
        if (-not $content) {
            $State.Index++
            if ($State.Index -lt $lines.Count -and $lines[$State.Index].Indent -gt $Indent) {
                $items.Add((Read-DevSetupYamlBlock -State $State -Indent $lines[$State.Index].Indent))
            } else {
                $items.Add($null)
            }
        } elseif ($content -match '^[^\s"''\[{][^:]*:(\s|$)') {
            # Re-read the item's first key as if it started its own line at the item's indentation.
            $lines[$State.Index] = [pscustomobject]@{ Indent = $contentIndent; Text = $content }
            $items.Add((Read-DevSetupYamlMapping -State $State -Indent $contentIndent))
        } else {
            $State.Index++
            $items.Add((Read-DevSetupYamlScalar -State $State -First $content -ParentIndent $Indent))
        }
    }
    return , $items.ToArray()
}

function Read-DevSetupYamlScalar {
    param(
        [Parameter(Mandatory)] [hashtable] $State,
        [Parameter(Mandatory)] [string] $First,
        [Parameter(Mandatory)] [int] $ParentIndent
    )
    # Continuation lines of folded, quoted, or block scalars are indented past their key.
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($First)
    while ($State.Index -lt $State.Lines.Count -and $State.Lines[$State.Index].Indent -gt $ParentIndent) {
        $parts.Add($State.Lines[$State.Index].Text)
        $State.Index++
    }
    if ($First -match '^[|>][-+0-9]*$') {
        return (@($parts | Select-Object -Skip 1) -join "`n")
    }
    $text = ($parts -join ' ').Trim()
    if ($text.StartsWith('"')) {
        $inner = $text.Substring(1)
        if ($inner.EndsWith('"')) { $inner = $inner.Substring(0, $inner.Length - 1) }
        return [regex]::Replace($inner, '\\(U[0-9A-Fa-f]{8}|u[0-9A-Fa-f]{4}|x[0-9A-Fa-f]{2}|.)', {
            param($m)
            $code = $m.Groups[1].Value
            switch -CaseSensitive ($code[0]) {
                'n' { return "`n" }
                't' { return "`t" }
                'r' { return "`r" }
                'U' { return [char]::ConvertFromUtf32([Convert]::ToInt32($code.Substring(1), 16)) }
                'u' { return [string][char][Convert]::ToInt32($code.Substring(1), 16) }
                'x' { return [string][char][Convert]::ToInt32($code.Substring(1), 16) }
                default { return $code }
            }
        })
    }
    if ($text.StartsWith("'")) {
        $inner = $text.Substring(1)
        if ($inner.EndsWith("'")) { $inner = $inner.Substring(0, $inner.Length - 1) }
        return $inner.Replace("''", "'")
    }
    if ($text -match '^\[(.*)\]$') {
        $body = $Matches[1].Trim()
        if (-not $body) { return , @() }
        return , @($body -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") })
    }
    if ($text -eq '{}') { return [ordered]@{} }
    if ($text -in @('~', 'null')) { return $null }
    return $text
}

# Root-level installer fields apply to every installer unless the installer overrides them.
function Get-DevSetupWingetInstaller {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Manifest
    )
    $merged = [ordered]@{}
    foreach ($key in $Manifest.Keys) {
        if ($key -ne 'Installers') { $merged[$key] = $Manifest[$key] }
    }
    $installers = @($Manifest['Installers'])
    if ($installers.Count -ne 1 -or $installers[0] -isnot [System.Collections.IDictionary]) {
        throw "Expected exactly one installer in the downloaded manifest for $($Manifest['PackageIdentifier'])."
    }
    foreach ($key in $installers[0].Keys) {
        $merged[$key] = $installers[0][$key]
    }
    return $merged
}

#endregion

#region Install plan (built on the online PC, read offline)

function Get-DevSetupPublisherId {
    param(
        [Parameter(Mandatory)] [string] $Publisher
    )
    # Windows derives the family-name suffix from the first 8 bytes of SHA-256(UTF-16LE publisher), base32-encoded.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::Unicode.GetBytes($Publisher)) } finally { $sha.Dispose() }
    $bits = (@($hash[0..7] | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join '') + '0'
    $alphabet = '0123456789abcdefghjkmnpqrstvwxyz'
    $id = ''
    for ($i = 0; $i -lt 65; $i += 5) {
        $id += $alphabet[[Convert]::ToInt32($bits.Substring($i, 5), 2)]
    }
    return $id
}

function Get-DevSetupMsixIdentity {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Architecture = 'x64'
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry('AppxMetadata/AppxBundleManifest.xml')
        if (-not $entry) { $entry = $zip.GetEntry('AppxManifest.xml') }
        if (-not $entry) { throw "No package manifest found in $Path." }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $zip.Dispose()
    }
    $isBundle = [bool]$xml.DocumentElement.LocalName.Equals('Bundle')
    $root = $xml.DocumentElement
    $version = [string]$root.Identity.Version
    if ($isBundle) {
        # Provisioned packages report the inner application package's version, not the bundle's.
        # A bundle can carry several builds per architecture for different Windows versions, and
        # Windows installs whichever applies, so the lowest one for the target is the bar to meet.
        $applications = @($root.Packages.Package | Where-Object {
            $_.Type -eq 'application' -and ($_.Architecture -eq $Architecture -or $_.Architecture -eq 'neutral' -or -not $_.Architecture)
        })
        if ($applications.Count) {
            $version = [string](@($applications | ForEach-Object { [version]$_.Version } | Sort-Object)[0])
        }
    }
    return [pscustomobject]@{
        Name       = [string]$root.Identity.Name
        Version    = $version
        Publisher  = [string]$root.Identity.Publisher
        FamilyName = "$([string]$root.Identity.Name)_$(Get-DevSetupPublisherId -Publisher ([string]$root.Identity.Publisher))"
        IsBundle   = $isBundle
    }
}

function Get-DevSetupMsiProperty {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Property
    )
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $flags = [Reflection.BindingFlags]::InvokeMethod
    $database = $installer.GetType().InvokeMember('OpenDatabase', $flags, $null, $installer, @($Path, 0))
    $view = $database.GetType().InvokeMember('OpenView', $flags, $null, $database, @("SELECT Value FROM Property WHERE Property='$Property'"))
    try {
        [void]$view.GetType().InvokeMember('Execute', $flags, $null, $view, $null)
        $record = $view.GetType().InvokeMember('Fetch', $flags, $null, $view, $null)
        if (-not $record) { return $null }
        return [string]$record.GetType().InvokeMember('StringData', [Reflection.BindingFlags]::GetProperty, $null, $record, 1)
    } finally {
        [void]$view.GetType().InvokeMember('Close', $flags, $null, $view, $null)
        foreach ($com in @($view, $database, $installer)) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($com)
        }
    }
}

function Get-DevSetupDictionaryValue {
    param(
        $Dictionary,
        [Parameter(Mandatory)] [string] $Key
    )
    if ($Dictionary -is [System.Collections.IDictionary] -and $Dictionary.Contains($Key)) {
        return $Dictionary[$Key]
    }
    return $null
}

# Mirrors WinGet's silent defaults: manifest Silent replaces them, Custom is appended.
function Get-DevSetupInstallerArguments {
    param(
        [Parameter(Mandatory)] [string] $InstallerType,
        [string] $Scope,
        [string] $Silent,
        [string] $Custom
    )
    $defaults = switch ($InstallerType) {
        { $_ -in @('msi', 'wix') } { '/quiet /norestart' }
        'burn'     { '/quiet /norestart' }
        'inno'     { '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
        'nullsoft' { '/S' }
        'exe'      { '' }
        default    { throw "Installer type '$InstallerType' has no silent defaults." }
    }
    $parts = @(if ($Silent) { $Silent } else { $defaults })
    # The offline kit installs machine-wide; installers that cannot honor this ignore the switch.
    if ($InstallerType -in @('msi', 'wix')) { $parts += 'ALLUSERS=1' }
    if ($InstallerType -eq 'inno') { $parts += '/ALLUSERS' }
    if ($Custom) { $parts += $Custom }
    $arguments = (@($parts | Where-Object { $_ }) -join ' ').Trim()
    if ($InstallerType -eq 'exe' -and -not $Silent) {
        throw 'The manifest declares an exe installer without silent switches, so it cannot run unattended.'
    }
    return $arguments
}

function Get-DevSetupSuccessCodes {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Installer
    )
    $codes = @(0, 1641, 3010)
    foreach ($code in @(Get-DevSetupDictionaryValue -Dictionary $Installer -Key 'InstallerSuccessCodes')) {
        if ($null -ne $code) { $codes += [int64]$code }
    }
    foreach ($expected in @(Get-DevSetupDictionaryValue -Dictionary $Installer -Key 'ExpectedReturnCodes')) {
        $response = Get-DevSetupDictionaryValue -Dictionary $expected -Key 'ReturnResponse'
        if ($response -in @('alreadyInstalled', 'rebootRequiredToFinish', 'rebootRequiredForInstall', 'rebootInitiated')) {
            $codes += [int64](Get-DevSetupDictionaryValue -Dictionary $expected -Key 'InstallerReturnCode')
        }
    }
    return @($codes | Select-Object -Unique)
}

# Turns one `winget download` folder into an install-plan entry that machine-setup.ps1 runs offline.
function New-DevSetupPackageEntry {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [string] $Root,
        [string] $Architecture = 'x64',
        [hashtable] $Override = @{}
    )
    $manifestFile = @(Get-ChildItem -LiteralPath $Directory -Filter '*.yaml' -File)
    $installerFile = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object { $_.Extension -ne '.yaml' })
    if ($manifestFile.Count -ne 1 -or $installerFile.Count -ne 1) {
        throw "Expected one installer and one manifest in $Directory."
    }
    $manifest = ConvertFrom-DevSetupYaml -Text ([IO.File]::ReadAllText($manifestFile[0].FullName))
    $installer = Get-DevSetupWingetInstaller -Manifest $manifest
    $type = ([string](Get-DevSetupDictionaryValue -Dictionary $installer -Key 'InstallerType')).ToLowerInvariant()
    $nestedType = [string](Get-DevSetupDictionaryValue -Dictionary $installer -Key 'NestedInstallerType')
    $switches = Get-DevSetupDictionaryValue -Dictionary $installer -Key 'InstallerSwitches'
    $id = [string]$manifest['PackageIdentifier']
    $version = [string]$manifest['PackageVersion']

    # Spaces in WinGet's file names would need quoting in every installer command line.
    $safeName = ("$id-$version" -replace '[^A-Za-z0-9._+-]', '_') + $installerFile[0].Extension.ToLowerInvariant()
    $installerPath = Join-Path $Directory $safeName
    if ($installerFile[0].Name -ne $safeName) {
        Move-Item -LiteralPath $installerFile[0].FullName -Destination $installerPath -Force
    }

    $entry = [ordered]@{
        Name          = $Name
        Id            = $id
        Version       = $version
        PackageName   = [string](Get-DevSetupDictionaryValue -Dictionary $manifest -Key 'PackageName')
        Publisher     = [string](Get-DevSetupDictionaryValue -Dictionary $manifest -Key 'Publisher')
        InstallerType = $type
        Scope         = [string](Get-DevSetupDictionaryValue -Dictionary $installer -Key 'Scope')
        Architecture  = [string](Get-DevSetupDictionaryValue -Dictionary $installer -Key 'Architecture')
        File          = $installerPath.Substring($Root.Length).TrimStart('\')
        Sha256        = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
        Kind          = $null
        Arguments     = $null
        SuccessCodes  = @(Get-DevSetupSuccessCodes -Installer $installer)
        Dependencies  = @()
        Portable      = @()
        Detection     = $null
    }

    switch ($type) {
        { $_ -in @('msix', 'appx') } {
            $identity = Get-DevSetupMsixIdentity -Path $installerPath -Architecture $Architecture
            $entry.Kind = 'msix'
            $entry.Detection = [ordered]@{ IdentityName = $identity.Name; Version = $identity.Version; FamilyName = $identity.FamilyName }
            $dependencyDir = Join-Path $Directory 'Dependencies'
            if (Test-Path -LiteralPath $dependencyDir) {
                $entry.Dependencies = @(Get-ChildItem -LiteralPath $dependencyDir -File |
                    Where-Object { $_.Extension -in @('.msix', '.appx', '.msixbundle', '.appxbundle') } |
                    ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\') })
            }
        }
        'zip' {
            if ($nestedType -notin @('portable')) {
                throw "$id uses a zip with a nested '$nestedType' installer, which the offline kit does not support yet."
            }
            $entry.Kind = 'portable'
            $entry.Portable = @(foreach ($nested in @(Get-DevSetupDictionaryValue -Dictionary $installer -Key 'NestedInstallerFiles')) {
                [ordered]@{
                    RelativeFilePath     = [string](Get-DevSetupDictionaryValue -Dictionary $nested -Key 'RelativeFilePath')
                    PortableCommandAlias = [string](Get-DevSetupDictionaryValue -Dictionary $nested -Key 'PortableCommandAlias')
                }
            })
            if ($entry.Portable.Count -eq 0) { throw "$id is a portable zip without NestedInstallerFiles." }
            $entry.Detection = [ordered]@{ PackageDirectory = "WinGet\Packages\$($id)_$Script:DevSetupPortableSource" }
        }
        { $_ -in @('msi', 'wix') } {
            $entry.Kind = 'msi'
            $productCode = [string](Get-DevSetupDictionaryValue -Dictionary $installer -Key 'ProductCode')
            if (-not $productCode) { $productCode = Get-DevSetupMsiProperty -Path $installerPath -Property 'ProductCode' }
            $entry.Arguments = Get-DevSetupInstallerArguments -InstallerType $type -Scope $entry.Scope `
                -Silent ([string](Get-DevSetupDictionaryValue -Dictionary $switches -Key 'Silent')) `
                -Custom ([string](Get-DevSetupDictionaryValue -Dictionary $switches -Key 'Custom'))
            $entry.Detection = [ordered]@{ ProductCodes = @($productCode) }
        }
        { $_ -in @('inno', 'burn', 'nullsoft', 'exe') } {
            $entry.Kind = 'exe'
            $entry.Arguments = Get-DevSetupInstallerArguments -InstallerType $type -Scope $entry.Scope `
                -Silent ([string](Get-DevSetupDictionaryValue -Dictionary $switches -Key 'Silent')) `
                -Custom ([string](Get-DevSetupDictionaryValue -Dictionary $switches -Key 'Custom'))
            $codes = @()
            $names = @()
            foreach ($arp in @(Get-DevSetupDictionaryValue -Dictionary $installer -Key 'AppsAndFeaturesEntries')) {
                $code = [string](Get-DevSetupDictionaryValue -Dictionary $arp -Key 'ProductCode')
                $displayName = [string](Get-DevSetupDictionaryValue -Dictionary $arp -Key 'DisplayName')
                if ($code) { $codes += $code }
                if ($displayName) { $names += $displayName }
            }
            $productCode = [string](Get-DevSetupDictionaryValue -Dictionary $installer -Key 'ProductCode')
            if ($productCode) { $codes += $productCode }
            if ($entry.PackageName) { $names += $entry.PackageName }
            $entry.Detection = [ordered]@{ ProductCodes = @($codes | Select-Object -Unique); DisplayNames = @($names | Select-Object -Unique) }
        }
        default {
            throw "$id uses installer type '$type', which the offline kit does not support yet."
        }
    }

    if ($Override['ExtraArguments']) {
        $entry.Arguments = "$($entry.Arguments) $($Override['ExtraArguments'])".Trim()
    }
    if ($Override['DisplayNames']) {
        $entry.Detection.DisplayNames = @($Override['DisplayNames'])
    }
    return $entry
}

#endregion
