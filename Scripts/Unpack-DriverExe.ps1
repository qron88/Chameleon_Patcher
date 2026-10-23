<#
.SYNOPSIS
  Extracts an NVIDIA driver self-extracting installer (.exe) into a plain folder.

.DESCRIPTION
  NVIDIA driver downloads are a 7-Zip SFX: a small stub/config block followed by a plain 7z
  archive. This script takes that archive out with a 7z-compatible CLI - 7-Zip, NanaZip, anything
  else answering to 7z - and with nothing else. The CLI is looked for in the WindowsApps alias,
  Program Files\7-Zip, Program Files (x86)\7-Zip, Program Files\NanaZip and PATH; when none is
  found the run stops there and says how to install one.

  A 7z-compatible CLI is a hard requirement, and that is a decision rather than an oversight. The
  alternative this toolkit tried first was NVIDIA's own launcher: run the downloaded .exe with -x,
  poll for the package it unpacks, and stop the process tree before anything installs. On a real
  machine that route needed elevation, then asked for the folder to unpack into, then unpacked into
  C:\WINDOWS\Temp under a folder named with a GUID - and a run holding a UAC-filtered token is
  refused even the right to list C:\WINDOWS\Temp. It was polled for ten minutes with nothing landing
  in anything it could read, while a 7z CLI expanded the same 621.01 file in seconds. There is no
  reason to carry a route that cannot be trusted over one that installs in one command, so the
  launcher route is gone and 7-Zip is a documented dependency.

  The 7z SFX format is unchanged across the releases this toolkit has been verified against
  (595.79 through 621.01), and a folder extracted by hand is just as usable: point the pipeline at
  it with -SourcePackagePath instead.

.PARAMETER ExePath
  Path to the downloaded driver .exe.

.PARAMETER OutputPath
  Folder to extract into. Must not already exist.

.PARAMETER SevenZipPath
  Use this 7z-compatible CLI explicitly. Naming a CLI is a hard request: if it is not there, the
  run fails rather than guessing at another one.

.EXAMPLE
  .\Unpack-DriverExe.ps1 -ExePath "D:\Downloads\616.86-desktop-win10-win11-64bit-international-dch-whql.exe" -OutputPath "D:\NVIDIA\stock"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$SevenZipPath
)

$ErrorActionPreference = 'Stop'

# Reuse the shared discovery instead of a second, simpler copy. That copy used to skip the
# NanaZip candidate, so a NanaZip-only machine passed the pipeline's preflight (which does check
# NanaZip) but then failed here, after the run had already started.
. (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

if (-not (Test-Path $ExePath)) { throw "Not found: $ExePath" }
if (Test-Path $OutputPath) { throw "Output path already exists: $OutputPath - remove it or choose a different path." }

function Expand-BySevenZip {
    param([string]$Cli, [string]$Source, [string]$Dest)
    Write-Host "Using 7z CLI: $Cli" -ForegroundColor DarkGray
    & $Cli x $Source "-o$Dest" -y | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "7z extraction failed with exit code $LASTEXITCODE" }
}

# A missing CLI is reported by Find-SevenZip, in front of the extraction and with the install
# command in the message. The pipeline's preflight says the same thing earlier still; this is the
# copy that catches a person running this script on its own.
$sevenZip = if ($SevenZipPath) { Find-SevenZip -ExplicitPath $SevenZipPath } else { Find-SevenZip }

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Host "Extracting $ExePath ..." -ForegroundColor Cyan
try {
    Expand-BySevenZip -Cli $sevenZip -Source $ExePath -Dest $OutputPath
}
catch {
    # A failed extraction leaves a PARTIAL folder behind, and the "Output path already exists"
    # guard at the top of this script would then turn the next attempt into an instant failure.
    # Remove the partial folder so a re-run starts clean, then rethrow the original error.
    if (Test-Path $OutputPath) {
        Remove-Item $OutputPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}

$hasSetup = Test-Path (Join-Path $OutputPath "setup.exe")
$hasCfg = Test-Path (Join-Path $OutputPath "setup.cfg")
$hasDD = Test-Path (Join-Path $OutputPath "Display.Driver")
if (-not ($hasSetup -and $hasCfg -and $hasDD)) {
    throw "Extraction completed but $OutputPath doesn't look like an NVIDIA driver package (missing setup.exe/setup.cfg/Display.Driver). Wrong file, or NVIDIA changed their packaging format."
}

Write-Host "Extracted to $OutputPath" -ForegroundColor Green
