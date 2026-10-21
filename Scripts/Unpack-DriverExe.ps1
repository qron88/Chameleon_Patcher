<#
.SYNOPSIS
  Extracts an NVIDIA driver self-extracting installer (.exe) into a plain folder.

.DESCRIPTION
  NVIDIA driver downloads are a 7-Zip SFX: a small stub/config block followed by a plain 7z
  archive. Two routes get it out, and the script picks between them:

    1. A 7z-compatible CLI (NanaZip, 7-Zip) - the preferred route. It extracts straight into a
       folder you name, in one step, and does not touch the machine.
    2. NVIDIA's own installer, `setup.exe -x -s` - the no-install fallback. It expands the
       package without installing a driver, so a machine with no third-party tool installed is
       not blocked from patching a driver download. It is slower, and it expands to NVIDIA's own
       fixed location under the current volume's root (C:\NVIDIA\DisplayDriver\...) rather than
       to a path you choose, so the result is moved to -OutputPath afterwards.

  Route 2 runs the downloaded installer, which means it needs the download to be on - and
  runnable on - this machine. Route 1 has no such constraint. That is the whole tradeoff, and
  why 7-Zip stays the first choice.

  The 7z SFX format is unchanged across the releases this toolkit has been verified against
  (595.79 through 617.42), so route 1 is the one exercised in practice; route 2 is the
  documented fallback, not a second tested default.

.PARAMETER ExePath
  Path to the downloaded driver .exe.

.PARAMETER OutputPath
  Folder to extract into. Must not already exist.

.PARAMETER SevenZipPath
  Use this 7z-compatible CLI explicitly. Naming a CLI is a hard request: if it is not there,
  the run fails rather than quietly switching to the installer route.

.PARAMETER SetupExePath
  Use this NVIDIA installer for the expansion route explicitly, bypassing discovery.

.EXAMPLE
  .\Unpack-DriverExe.ps1 -ExePath "D:\Downloads\616.86-desktop-win10-win11-64bit-international-dch-whql.exe" -OutputPath "D:\NVIDIA\stock"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$SevenZipPath,

    [string]$SetupExePath
)

$ErrorActionPreference = 'Stop'

# Reuse the shared discovery instead of a second, simpler copy. That copy used to skip the
# NanaZip candidate, so a NanaZip-only machine passed the pipeline's preflight (which does check
# NanaZip) but then failed here, after the run had already started.
. (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

if (-not (Test-Path $ExePath)) { throw "Not found: $ExePath" }
if (Test-Path $OutputPath) { throw "Output path already exists: $OutputPath - remove it or choose a different path." }

function Test-ExpandedPackageRoot {
    param([string]$Path)
    (Test-Path (Join-Path $Path "setup.exe")) -and
    (Test-Path (Join-Path $Path "setup.cfg")) -and
    (Test-Path (Join-Path $Path "Display.Driver"))
}

function Expand-BySevenZip {
    param([string]$Cli, [string]$Source, [string]$Dest)
    Write-Host "Using 7z CLI: $Cli" -ForegroundColor DarkGray
    & $Cli x $Source "-o$Dest" -y | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "7z extraction failed with exit code $LASTEXITCODE" }
}

function Expand-ByNvidiaInstaller {
    param([string]$Installer, [string]$Source)
    Write-Host "Using NVIDIA installer expansion: $Installer" -ForegroundColor DarkGray
    Write-Host "  -x -s expands the package without installing anything. NVIDIA writes it under" -ForegroundColor DarkGray
    Write-Host "  the current volume's root (C:\NVIDIA\DisplayDriver\<version>\<os>\Current)." -ForegroundColor DarkGray

    # The installer is a GUI app that returns immediately, so the expansion has to be polled for
    # rather than waited on. Polling on the marker file (setup.cfg, the last thing written) is
    # what makes this a real bound: a fixed sleep would either be too short for a 1 GB package or
    # a guaranteed stall on every run.
    $before = @{}
    foreach ($root in @('C:\NVIDIA', (Join-Path $env:TEMP 'NVIDIA Display Operation Server'))) {
        if ($root -and (Test-Path $root)) {
            foreach ($f in @(Get-ChildItem -Path $root -Filter 'setup.cfg' -Recurse -File -ErrorAction SilentlyContinue)) {
                $before[$f.FullName] = $f.LastWriteTime.Ticks
            }
        }
    }

    # NVIDIA's installer is a GUI app, so it needs ShellExecute semantics to launch reliably
    # (file associations, elevation, the loader's own checks). UseShellExecute = $false is the
    # CreateNoWindow/redirect path and fails on some binaries outright. Nothing is read from the
    # process here - the expansion is judged by what lands on disk - so there is nothing to
    # redirect, and this is the safe setting.
    #
    # Built through the ProcessStartInfo constructor: property assignment on a New-Object
    # PSObject wrapper cannot set UseShellExecute (confirmed: "You cannot find the property"),
    # so the properties are set on a real object.
    $psi = New-Object System.Diagnostics.ProcessStartInfo($Installer)
    $psi.Arguments = '-x -s'
    $psi.UseShellExecute = $true
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        throw "Could not start NVIDIA's installer at $Installer : $($_.Exception.Message)"
    }

    # The expansion is judged by what lands on disk, so the process is not waited on. NVIDIA's
    # installer is a GUI app: launched elevated it runs on the secure desktop, where a process
    # wait from a non-elevated caller can block indefinitely, and a 10-minute WaitForExit would
    # then hang the run for its full timeout on a machine that is expanding perfectly well.
    # Polling the marker file is the real bound, and it is what a 1 GB package needs.
    $deadline = (Get-Date).AddMinutes(10)
    $expandedRoot = $null
    while ((Get-Date) -lt $deadline) {
        $candidate = Find-NewestExpansion -Before $before
        if ($candidate) { $expandedRoot = $candidate; break }
        Start-Sleep -Milliseconds 1500
    }
    if (-not $expandedRoot) {
        throw "NVIDIA's installer produced no new expansion under C:\NVIDIA or the NVIDIA Display Operation Server temp folder within 10 minutes. Run the downloaded driver .exe yourself (it expands, then offers to install - cancel the install), then re-run this with -SetupExePath pointing at the setup.exe it produced."
    }
    try {
        if (-not $proc.HasExited) {
            Write-Host "  Expansion found; stopping NVIDIA's installer before it reaches the install step." -ForegroundColor DarkGray
            [void](Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue)
        }
    }
    catch {
        # The process is already gone, or its exit state is unreadable. The expansion is on disk
        # and that is what the rest of the pipeline works from.
    }
    return $expandedRoot
}

function Assert-ExpandedVersionMatchesRequest {
    <#
      Guards the installer unpack route against a silent version substitution, which is the one
      failure that route has and which nothing downstream catches.

      NVIDIA's installer writes into its own fixed roots, and Find-NewestExpansion picks the newest
      setup.cfg that appeared while the process ran. A driver version already sitting under
      C:\NVIDIA\DisplayDriver\<version>\ whose timestamp moves for an unrelated reason - a copy, an
      antivirus scan, a second installer run for a different version - is therefore not
      distinguishable from the expansion this launch caused. Everything downstream is
      version-agnostic: the whitelist splice, the RM override and the verification gate all pass
      happily on the wrong driver version, and the package then gets signed, installed and reported
      as if it were the one that was asked for.

      NVIDIA's own expansion path names the version, so comparing it with the version in the
      requested download's file name turns the silent case into a loud one. Where neither side names
      a version this warns instead of throwing: it is a safety net, not a new hard requirement.
    #>
    param([string]$ExpandedRoot, [string]$RequestedExePath)
    $requested = Get-DriverVersionTextFromPath -Path $RequestedExePath
    $actual = Get-DriverVersionTextFromPath -Path $ExpandedRoot -Deepest
    if (-not $requested) {
        Write-Warning "The requested file name does not name a driver version, so the expansion could not be checked against it. Expansion used: $ExpandedRoot"
        return
    }
    if (-not $actual) {
        Write-Warning "NVIDIA's expansion folder $ExpandedRoot does not name a driver version, so it could not be checked against the requested version $requested. Check the package version before signing it."
        return
    }
    if ($actual -ne $requested) {
        throw @"
NVIDIA's installer route produced an expansion of driver version $actual ($ExpandedRoot), but the requested download is driver version $requested : $RequestedExePath.

The installer writes into its own fixed roots, and the newest expansion to appear on disk is not necessarily the payload of the download this run was asked to patch - C:\NVIDIA can hold expansions of other versions whose timestamps move for unrelated reasons. Everything downstream of this step (the whitelist splice, the RM override, the verification gate) is version-agnostic and would have signed a package of the wrong version without complaining.

Use a 7-Zip compatible tool (7-Zip or NanaZip) so the requested file is extracted directly, or unpack the requested .exe yourself and pass -SourcePackagePath.
"@
    }
    Write-Host "  Expanded package is driver version $actual, matching the requested download." -ForegroundColor DarkGreen
}

function Find-NewestExpansion {
    <#
      Newest setup.cfg under NVIDIA's expansion roots that was not present (or was not modified)
      before the installer was launched. setup.cfg is the last thing the expansion writes, so its
      appearance is the completion signal.
    #>
    param([hashtable]$Before)
    $newest = $null
    foreach ($root in @('C:\NVIDIA', (Join-Path $env:TEMP 'NVIDIA Display Operation Server'))) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        foreach ($f in @(Get-ChildItem -Path $root -Filter 'setup.cfg' -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($Before.ContainsKey($f.FullName) -and $Before[$f.FullName] -eq $f.LastWriteTime.Ticks) { continue }
            if (-not $newest -or $f.LastWriteTime -gt $newest.LastWriteTime) { $newest = $f }
        }
    }
    if (-not $newest) { return $null }
    return (Split-Path $newest.DirectoryName -Parent)
}

# --- Route selection --------------------------------------------------------------------------
# 7z first: it is faster, extracts to the exact folder requested, and runs nothing. The
# installer route is the fallback that keeps 7-Zip off the list of hard requirements.
# The fallback picks an expansion by timestamp, which is why it also verifies the version it ended
# up with - see Assert-ExpandedVersionMatchesRequest below, and the -ExpectedVersion filter it asks
# discovery for. A cached C:\NVIDIA folder of another driver version is otherwise
# indistinguishable from the payload of the download this run was asked to patch.
$sevenZip = $null
if ($SevenZipPath) {
    $sevenZip = Find-SevenZip -ExplicitPath $SevenZipPath
}
else {
    try { $sevenZip = Find-SevenZip } catch { $sevenZip = $null }
}

$installer = $null
if (-not $sevenZip) {
    $installer = if ($SetupExePath) {
        if (-not (Test-Path $SetupExePath)) { throw "NVIDIA installer not found at the path you passed: $SetupExePath" }
        (Resolve-Path $SetupExePath).Path
    }
    else {
        Find-NvidiaSetupExe -ExpectedVersion (Get-DriverVersionTextFromPath -Path $ExePath)
    }
}

if (-not $sevenZip -and -not $installer) {
    throw @"
Neither a 7z-compatible CLI nor NVIDIA's own installer is available, so this download cannot be unpacked.

$(Get-MissingToolHelp -ToolNames @('7z') -join "`n")
Or unpack the driver yourself and use -SourcePackagePath: run the downloaded .exe once (it
expands under C:\NVIDIA\DisplayDriver\, then offers to install - cancel the install) and point
Invoke-DriverPatchPipeline.ps1 at that folder.
"@
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Host "Extracting $ExePath ..." -ForegroundColor Cyan
try {
    if ($sevenZip) {
        Expand-BySevenZip -Cli $sevenZip -Source $ExePath -Dest $OutputPath
    }
    else {
        $expanded = Expand-ByNvidiaInstaller -Installer $installer -Source $ExePath
        if (-not (Test-ExpandedPackageRoot $expanded)) {
            throw "NVIDIA expanded to $expanded, which does not look like a driver package root (expected setup.exe, setup.cfg, Display.Driver)."
        }
        Assert-ExpandedVersionMatchesRequest -ExpandedRoot $expanded -RequestedExePath $ExePath

        Write-Host "Expanded to $expanded - copying into $OutputPath" -ForegroundColor DarkGray
        Copy-Item -Path (Join-Path $expanded '*') -Destination $OutputPath -Recurse -Force
    }
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
