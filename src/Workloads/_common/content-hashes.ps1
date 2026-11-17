$Script:DevConfigWorkloadContentHashes = @{
    'cuda\smoke.cu' = '6252383bda8856daa14c4f315961e17d4de3bdba1cba6bf4c09a5d0aa52a2a6f'
    'electron\configuration.winget' = '22ae732f0d5690f2cbbf63f646d81fc8094b98a139ca38dd6a66336bf73c9f07'
    'flutter\configuration.winget' = 'a71653b08686c85351da42239cb2dd7fac4f00a75df6342c9544a5f5a8310be6'
    'intel-ai\openvino-smoke.py' = '0b71b5f5351dd7536c6352dc02ffd523fa89f2fa60a23ff27d45fd3e8f9c1326'
    'intel-ai\sycl-smoke.cpp' = '6ed0361d8374bcae060b84469b3b167738f016abc9f3b46ba5f19ad870bd74b7'
    'java\configuration.winget' = 'f36edd7ca81b9389ba490505892d6ca5068d5942a249a98f3997356300b8447e'
    'node\configuration.winget' = 'd362399317efd3b734258d3496b6ec9c65d4fcc7dac0933668ed2467984cd270'
    'powershell\configuration.winget' = 'b86d0cc7dea26309a14478e5a94304dc9b037fe32220bdc83da8318ed60e220d'
    'python\configuration.winget' = 'f03cc78cc5cb3e3bd254c1b6a9a54f668508f5437eaa329294aa2891007fe7b8'
    'pytorch\smoke.py' = 'f28b8ca06e0a2832684f1342626c74904c13d575ce96282f86cf66f44d3eba68'
    'pytorch\triton-smoke.py' = 'a2d2a538b1b30315f249753ccad68d6977bf85d711e3e3541c52ae16268814f4'
    'pytorch\xpu-smoke.py' = '7cba1b04e7ecbce0c24a9188ff847cd3c2fd9792810b5fd4324728ad21786c50'
    'react-native\configuration.winget' = '28c808342f8f390afeee7f5bf33f52c34cc43840bf525b8629a69075d13a4f65'
    'rocm\hip-smoke.cpp' = 'ece1ed905b3afc7ceb918cc3ff751d624b8d681444b1c507a74cfef3d326034d'
    'sql\configuration.winget' = '99472e573c10316a17be12d45da834e22be4b1b774afc5c15fdefe3d63bb98e7'
    'tauri\configuration.winget' = 'd2c6ec8f635df6eef1a83c0f59004a1f55ff00084ac77378f48cd3ec14c84f94'
    'temurin\configuration.winget' = '22f625b0426f237e3eebb748e0092978ee16774211a385adb79d1a83c7db93a9'
    'typescript\configuration.winget' = '826e1755d85798e376baa00a9891c58fd2dd6da67d0f54486ad957202ee7c8b1'
    'uv\configuration.winget' = '40fe293d3d9a1e9dd8d252bc1ed1b5b3752e2eb72380eb2c19b1c93a5321eb5d'
    'vscode\configuration.winget' = 'c4f92d8a164acbe9557779d4448e4a98115a2e07f14d4226bf427a28828442e5'
}

function Get-DevConfigCanonicalWorkloadHash {
    param([Parameter(Mandatory)] [string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $stream = [IO.MemoryStream]::new()
    try {
        for ($index = 0; $index -lt $bytes.Length; $index++) {
            if ($bytes[$index] -eq 13 -and
                $index + 1 -lt $bytes.Length -and
                $bytes[$index + 1] -eq 10) {
                $stream.WriteByte(10)
                $index++
            } else {
                $stream.WriteByte($bytes[$index])
            }
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream.ToArray()))).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Assert-DevConfigWorkloadContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WorkloadsRoot)

    $root = (Get-Item -LiteralPath $WorkloadsRoot -Force).FullName.TrimEnd('\')
    $actualFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.Extension -notin @('.ps1', '.psd1') })
    $actualPaths = @($actualFiles | ForEach-Object {
        $_.FullName.Substring($root.Length).TrimStart([char]'\')
    })

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Script:DevConfigWorkloadContentHashes.GetEnumerator()) {
        $path = Join-Path $root $entry.Key
        if (-not (Test-Path -LiteralPath $path)) {
            [void]$failures.Add("$($entry.Key) [missing]")
            continue
        }
        $actualHash = Get-DevConfigCanonicalWorkloadHash -Path $path
        if ($actualHash -ne $entry.Value) {
            [void]$failures.Add("$($entry.Key) [SHA-256 mismatch]")
        }
    }
    foreach ($path in $actualPaths) {
        if (-not $Script:DevConfigWorkloadContentHashes.ContainsKey($path)) {
            [void]$failures.Add("$path [not declared by signed content manifest]")
        }
    }

    if ($failures.Count -gt 0) {
        throw "The Workloads content manifest failed verification: $($failures -join '; ')"
    }
    Write-Host "  Verified $($actualFiles.Count) non-PowerShell workload files." -ForegroundColor DarkGray
}
