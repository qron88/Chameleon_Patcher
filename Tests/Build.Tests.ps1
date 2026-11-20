# Tests for Source\Build.ps1: output naming of the variants and the payload contract between
# the compiler (csc /resource names) and the GUI's extractor (Chameleon-Patcher.cs).
# Ported from the Chameleon_Patcher_Qwen branch and adapted to -Variant / "Scripts/" resources.
#
# The suite compiles throwaway .exe files into %TEMP% with the real csc.exe (a few seconds);
# nothing touches a certificate store, the repo root, the real Drivers\ folder or the network.
#
# Pester 3.4.0 syntax (the version shipped with PowerShell 5.1): "Should Be", not "Should -Be".
#
# Run:  .\Tests\Run.ps1   (from the repository root)

$ErrorActionPreference = 'Stop'

$script:RepoRoot   = Split-Path $PSScriptRoot -Parent
$script:ScriptsDir = Join-Path $RepoRoot 'Scripts'
$script:BuildPs1   = Join-Path $RepoRoot 'Source\Build.ps1'
$script:IconSrc    = Join-Path $RepoRoot 'Assets\Chameleon.ico'

# Resource-name prefix Build.ps1 stamps on every payload file; ExtractEmbeddedScripts in
# Chameleon-Patcher.cs matches on the same constant. Keep the two in step.
$script:PayloadPrefix = 'Scripts/'

function New-ScratchDir {
    param([string]$Hint = 'scratch')
    $root = Join-Path ([System.IO.Path]::GetTempPath()) 'chameleon-patcher-tests'
    $dir = Join-Path $root ($Hint + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

# Assembly.Load(byte[]) reads the image from memory, so the built file is never locked.
function Get-EmbeddedPayloadNames {
    param([string]$ExePath)
    $asm = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($ExePath))
    return @($asm.GetManifestResourceNames() | Where-Object { $_.StartsWith($script:PayloadPrefix) } | Sort-Object)
}

function Get-EmbeddedPayloadBytes {
    param([string]$ExePath, [string]$ResourceName)
    $asm = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($ExePath))
    $stream = $asm.GetManifestResourceStream($ResourceName)
    if (-not $stream) { return $null }
    try {
        $ms = New-Object System.IO.MemoryStream
        $stream.CopyTo($ms)
        return $ms.ToArray()
    }
    finally { $stream.Dispose() }
}

# A project shaped like the real one with its own version attribute, so naming (output lands in
# the PROJECT ROOT) can be tested without writing into the repository.
function New-FakeProject {
    param([string]$Dir)
    New-Item -ItemType Directory -Path (Join-Path $Dir 'Source') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Dir 'Assets') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Dir 'Scripts\templates') -Force | Out-Null
    Copy-Item -LiteralPath $script:BuildPs1 -Destination (Join-Path $Dir 'Source\Build.ps1')
    Copy-Item -LiteralPath $script:IconSrc -Destination (Join-Path $Dir 'Assets\Chameleon.ico')
    Set-Content -LiteralPath (Join-Path $Dir 'Source\Chameleon-Patcher.cs') -Encoding ASCII -Value @'
using System;
using System.Reflection;
[assembly: AssemblyTitle("Fake Patcher")]
[assembly: AssemblyVersion("9.9.0.0")]
[assembly: AssemblyFileVersion("9.9.9.0")]
[assembly: AssemblyInformationalVersion("9.9.9")]
internal static class Program { private static void Main() { } }
'@
    Set-Content -LiteralPath (Join-Path $Dir 'Scripts\Invoke-DriverPatchPipeline.ps1') -Encoding ASCII -Value "Write-Host 'fake pipeline'"
    Set-Content -LiteralPath (Join-Path $Dir 'Scripts\templates\x.nvi.template') -Encoding ASCII -Value "fake template body"
}

$script:Work = New-ScratchDir -Hint 'build'

# Default build first (must not make the overlay), then the overlay, on the fake project.
$script:FakeRoot = Join-Path $Work 'proj'
New-FakeProject -Dir $FakeRoot
& (Join-Path $FakeRoot 'Source\Build.ps1') | Out-Null
$script:FakeStandaloneExe = Join-Path $FakeRoot 'Chameleon-Patcher-9.9.9.exe'
$script:FakeOverlayExe    = Join-Path $FakeRoot 'Chameleon-Patcher-Overlay-9.9.9.exe'
$script:OverlayAfterDefault = Test-Path -LiteralPath $script:FakeOverlayExe
& (Join-Path $FakeRoot 'Source\Build.ps1') -Variant Overlay | Out-Null

# The real source once, to check the real Scripts tree is embedded in full.
$script:RealStandaloneExe = Join-Path $Work 'Chameleon-Patcher-real.exe'
& $BuildPs1 -OutputPath $RealStandaloneExe | Out-Null

$script:RealPayloadNames = @(Get-ChildItem -LiteralPath $ScriptsDir -Recurse -File | ForEach-Object {
    $script:PayloadPrefix + $_.FullName.Substring($ScriptsDir.Length + 1).Replace('\', '/')
} | Sort-Object)

Describe 'Build.ps1 output naming' {
    It 'names the default build Chameleon-Patcher-<version>.exe in the project root and does not build the overlay' {
        (Test-Path -LiteralPath $script:FakeStandaloneExe) | Should Be $true
        $script:OverlayAfterDefault | Should Be $false
    }

    It 'names the overlay build Chameleon-Patcher-Overlay-<version>.exe in the project root' {
        (Test-Path -LiteralPath $script:FakeOverlayExe) | Should Be $true
    }

    It 'stamps the version read from the assembly attributes into the file resource' {
        ((Get-Item -LiteralPath $script:FakeStandaloneExe).VersionInfo).ProductVersion | Should Be '9.9.9'
    }

    It 'refuses -OutputPath together with -Variant All' {
        $thrown = $null
        try { & $script:BuildPs1 -Variant All -OutputPath (Join-Path $script:Work 'x.exe') | Out-Null }
        catch { $thrown = $_.Exception.Message }
        ($thrown -like '*single -Variant*') | Should Be $true
    }
}

Describe 'Build.ps1 payload embedding' {
    It 'embeds every file under Scripts\ as Scripts/<relative/path>' {
        (Get-EmbeddedPayloadNames -ExePath $script:FakeStandaloneExe) | Should Be @(
            'Scripts/Invoke-DriverPatchPipeline.ps1'
            'Scripts/templates/x.nvi.template'
        )
    }

    It 'embeds the real Scripts tree in full, so a script added there is distributed automatically' {
        $real = Get-EmbeddedPayloadNames -ExePath $script:RealStandaloneExe
        $real.Count | Should BeGreaterThan 10
        ($real -join "`n") | Should Be ($script:RealPayloadNames -join "`n")
    }

    It 'embeds every payload file byte for byte - BOM, codepage and line endings survive' {
        foreach ($file in (Get-ChildItem -LiteralPath $ScriptsDir -Recurse -File)) {
            $relative = $file.FullName.Substring($ScriptsDir.Length + 1).Replace('\', '/')
            $embedded = Get-EmbeddedPayloadBytes -ExePath $script:RealStandaloneExe -ResourceName ($script:PayloadPrefix + $relative)
            $onDisk = [System.IO.File]::ReadAllBytes($file.FullName)
            $same = ($null -ne $embedded) -and
                ([System.BitConverter]::ToString($embedded) -eq [System.BitConverter]::ToString($onDisk))
            $same | Should Be $true
        }
    }

    It 'embeds nothing in the overlay build, so it keeps running the external Scripts folder' {
        (Get-EmbeddedPayloadNames -ExePath $script:FakeOverlayExe).Count | Should Be 0
    }

    It 'refuses to build when the Scripts folder is missing' {
        $noScripts = New-ScratchDir -Hint 'build-noscripts'
        New-FakeProject -Dir $noScripts
        Remove-Item -LiteralPath (Join-Path $noScripts 'Scripts') -Recurse -Force
        $thrown = $null
        try { & (Join-Path $noScripts 'Source\Build.ps1') -OutputPath (Join-Path $noScripts 'x.exe') | Out-Null }
        catch { $thrown = $_.Exception.Message }
        ($thrown -like '*Scripts*') | Should Be $true
    }
}
