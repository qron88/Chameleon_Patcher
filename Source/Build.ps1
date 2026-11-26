<#
.SYNOPSIS
  Builds Chameleon-Patcher-<version>.exe (scripts embedded) and/or
  Chameleon-Patcher-Overlay-<version>.exe from Chameleon-Patcher.cs.

.DESCRIPTION
  The GUI is a single-file WinForms app compiled by the .NET Framework's own csc.exe, which every
  Windows 10/11 install already has. There is no SDK, no NuGet restore and no internet access
  needed to rebuild it - that is deliberate, since the rest of the toolkit is offline-capable too.

  Two variants come from the same source:

    Overlay     Chameleon-Patcher-Overlay-<version>.exe. Runs the scripts from the Scripts\ folder next to it, and
                keeps Certificates\ there too. Must live in the PROJECT ROOT: an .exe sitting in
                Source\ would look for Source\Scripts\ and fail at launch.

    Standalone  Chameleon-Patcher-<version>.exe. Compiled with /define:STANDALONE and every file
                under Scripts\ embedded as a resource. At start it unpacks them (byte for byte,
                only files that are missing or differ) to %LOCALAPPDATA%\ChameleonPatcher\Scripts
                and keeps signing keys in %LOCALAPPDATA%\ChameleonPatcher\Certificates. It can be
                copied anywhere on its own. Rebuild it after every change under Scripts\.

  The version shown in Explorer's Details tab and in every patch log comes from the assembly
  attributes at the top of Chameleon-Patcher.cs. csc folds them into the PE's Win32 version
  resource on its own; there is no .rc file and nothing to bump here.

.PARAMETER Variant
  Standalone (default), Overlay or All. The overlay build is only made on request.

.PARAMETER OutputPath
  Where to write the .exe. Only valid with a single -Variant. Defaults to the variant's name plus
  the version (AssemblyInformationalVersion in the source) in the project root, e.g.
  Chameleon-Patcher-1.2.1.exe (standalone) and Chameleon-Patcher-Overlay-1.2.1.exe.

.PARAMETER CscPath
  Override the compiler location. By default the 64-bit .NET Framework 4.x csc.exe under %WINDIR%.

.EXAMPLE
  # Default: only the standalone executable.
  .\Build.ps1

.EXAMPLE
  # The overlay build (needs Scripts\ beside it), on request only.
  .\Build.ps1 -Variant Overlay

.EXAMPLE
  # Both.
  .\Build.ps1 -Variant All

.EXAMPLE
  # Build somewhere harmless to inspect before replacing the working copy.
  .\Build.ps1 -Variant Overlay -OutputPath "$env:TEMP\Chameleon-Patcher.exe"
#>
[CmdletBinding()]
param(
    [ValidateSet('Standalone', 'Overlay', 'All')]
    [string]$Variant = 'Standalone',
    [string]$OutputPath,
    [string]$CscPath
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty inside a param() default when a script is launched with -File under
# Windows PowerShell 5.1, so every path that depends on it is resolved here instead.
$projectRoot = Split-Path -Parent $PSScriptRoot
$source      = Join-Path $PSScriptRoot 'Chameleon-Patcher.cs'
$icon        = Join-Path $projectRoot  'Assets\Chameleon.ico'
$scriptsRoot = Join-Path $projectRoot  'Scripts'

if (-not $CscPath) { $CscPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe' }

# The version in the file name comes from the same attribute as the Explorer version resource, so
# the name, the resource and the log header cannot drift apart.
$versionMatch = Select-String -LiteralPath $source -Pattern 'AssemblyInformationalVersion\("([^"]+)"\)' |
    Select-Object -First 1
if (-not $versionMatch) { throw "AssemblyInformationalVersion not found in $source." }
$version = $versionMatch.Matches[0].Groups[1].Value

$variants = if ($Variant -eq 'All') { @('Overlay', 'Standalone') } else { @($Variant) }
if ($OutputPath -and $variants.Count -gt 1) {
    throw "-OutputPath names one file, so it needs a single -Variant (Overlay or Standalone)."
}

foreach ($required in @(
    @{ Path = $CscPath;     What = "csc.exe (.NET Framework 4.x compiler)" },
    @{ Path = $source;      What = "Chameleon-Patcher.cs" },
    @{ Path = $icon;        What = "Assets\Chameleon.ico - regenerate it with Assets\Build-Icon.ps1" },
    @{ Path = $scriptsRoot; What = "Scripts folder" }
)) {
    if (-not (Test-Path -LiteralPath $required.Path)) {
        throw "Not found: $($required.What) at $($required.Path)"
    }
}

foreach ($v in $variants) {
    $out = if ($OutputPath) { $OutputPath }
           elseif ($v -eq 'Standalone') { Join-Path $projectRoot "Chameleon-Patcher-$version.exe" }
           else { Join-Path $projectRoot "Chameleon-Patcher-Overlay-$version.exe" }

    $cscArgs = @('/nologo', '/target:winexe', "/out:$out", "/win32icon:$icon",
                 '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll',
                 # JavaScriptSerializer, for the pipeline's -Json answers. Part of the .NET Framework
                 # itself (4.x), so there is still nothing to restore or download.
                 '/reference:System.Web.Extensions.dll', '/platform:x64')

    if ($v -eq 'Standalone') {
        # Every file under Scripts\ (ps1, whitelist.json, templates\*) becomes a
        # "Scripts/<relative path>" resource.
        $res = @(Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($scriptsRoot.Length).TrimStart('\') -replace '\\', '/'
            "/resource:$($_.FullName),Scripts/$rel"
        })
        $cscArgs += '/define:STANDALONE'
        $cscArgs += $res
        Write-Host "Embedding $($res.Count) script file(s) from $scriptsRoot"
    }

    Write-Host "Compiling $v variant: $source" -ForegroundColor Cyan
    Write-Host "       -> $out"

    # Every .cs in Source\: MainForm is one partial class spread over several files, with
    # Chameleon-Patcher.cs (entry point, version attributes) first.
    $sources = @($source) + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.cs -File |
        Where-Object { $_.FullName -ne $source } | Sort-Object Name | ForEach-Object { $_.FullName })
    & $CscPath @cscArgs @sources
    if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE ($v variant)." }

    # Report what the version resource actually came out as. A silent mismatch between the
    # attributes in the source and what Explorer shows is exactly the kind of thing that only
    # surfaces after a release has shipped.
    $info = (Get-Item -LiteralPath $out).VersionInfo
    Write-Host ""
    Write-Host ("Built {0}: {1:N0} bytes" -f $v, (Get-Item -LiteralPath $out).Length) -ForegroundColor Green
    Write-Host ("  product      : {0}" -f $info.ProductName)
    Write-Host ("  file version : {0}" -f $info.FileVersion)
    Write-Host ("  product ver. : {0}" -f $info.ProductVersion)
    Write-Host ""
}
