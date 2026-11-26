# What a driver package is and where it lives: package-root test, the package NVIDIA App
# stages, the default output folder, and this boot's Test Signing / Secure Boot state.
#
# Part of the shared helper library. Do not dot-source this file on its own: load
# Scripts\PatchToolDiscovery.ps1, which loads every part in a fixed order.

function Test-DriverPackageRoot {
    <#
      Does this folder look like the root of an unpacked NVIDIA driver package: setup.exe,
      setup.cfg and Display.Driver side by side.

      The unpack step and the pipeline both need this exact answer and each carried its own copy of
      three Test-Path calls (Test-ExpandedPackageRoot there, Test-DriverPackageRoot here), which is
      how two scripts end up disagreeing about what a package is. -LiteralPath matters here: driver
      folders are created by tools that do not care about PowerShell's wildcard syntax, and a folder
      name with brackets in it is a legal folder name.
    #>
    param([string]$Path)
    (Test-Path -LiteralPath (Join-Path $Path 'setup.exe')) -and
    (Test-Path -LiteralPath (Join-Path $Path 'setup.cfg')) -and
    (Test-Path -LiteralPath (Join-Path $Path 'Display.Driver'))
}

function Find-NvAppStagedPackage {
    <#
      Newest driver package that NVIDIA App has already downloaded and unpacked, or $null.
      NVIDIA App's update framework stages each Game Ready driver download under

        %ProgramData%\NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts\grd\post-processing\<hash>\

      as a fully unpacked package (setup.exe, setup.cfg, Display.Driver) - exactly the layout
      -SourcePackagePath takes, so a staged folder can be a run's source without unpacking
      anything. The GUI asks (via the pipeline's -CheckNvAppStaged) whether to offer it at
      startup; what counts as a package root is the SAME Test-DriverPackageRoot rule a real run
      applies, so the offer and the run cannot disagree.

      Returns @{ Path; Version; Modified } for the newest candidate. Previous patch outputs sit
      beside the staged folders and also pass Test-DriverPackageRoot (their re-signed setup.exe,
      setup.cfg and Display.Driver are all present), so "*_Patched*" leaves are skipped: the
      offer is NVIDIA's staged download, and Test-DriverSource would refuse a patched copy as a
      source anyway. Version comes from setup.cfg's root <setup version="..."> attribute.
    #>
    param([string]$RootPath)
    if (-not $RootPath) { $RootPath = Get-NvAppStagedRoot }
    if (-not $RootPath) { return $null }
    if (-not (Test-Path -LiteralPath $RootPath)) { return $null }

    $best = $null
    foreach ($d in (Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -like '*_Patched*') { continue }
        if (-not (Test-DriverPackageRoot -Path $d.FullName)) { continue }

        $setupExe = Join-Path $d.FullName 'setup.exe'
        $stamp = (Get-Item -LiteralPath $setupExe).LastWriteTimeUtc
        if ($best -ne $null -and $stamp -le $best.Modified) { continue }

        $version = Get-SetupCfgVersion -PackagePath $d.FullName

        $best = [PSCustomObject]@{ Path = $d.FullName; Version = $version; Modified = $stamp }
    }
    return $best
}

function Get-NvAppStagedRoot {
    <# The folder NVIDIA App stages unpacked driver downloads in, or $null without %ProgramData%. #>
    $common = $env:ProgramData
    if (-not $common) { return $null }
    return (Join-Path $common 'NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts\grd\post-processing')
}

function Get-SetupCfgVersion {
    <#
      The driver version a package's setup.cfg declares (<setup ... version="621.40">), or ''.
      setup.cfg is NVIDIA's installer manifest; the attribute sits on the <setup> element near its
      top. A few head lines are read rather than the whole file, and matched tolerantly: this is
      only a label (the GUI's offer, an output folder name) - the full XML is parsed by later steps
      of an actual run.
    #>
    param([Parameter(Mandatory = $true)][string]$PackagePath)
    try {
        $head = (Get-Content -LiteralPath (Join-Path $PackagePath 'setup.cfg') -TotalCount 5) -join ' '
        $m = [regex]::Match($head, '<setup[^>]*version="([^"]+)"')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return ''
}

function Get-DefaultOutputPath {
    <#
      Where a run puts its result when -OutputPath is not given: "<source><suffix>" beside the
      source - with ONE exception. A package NVIDIA App staged lives in NVIDIA App's own
      update-framework folder under %ProgramData%; writing "<hash>_Patched" beside it (what 1.2.0
      did) leaves multi-GB folders in a directory another product owns, cleans up and scans, under
      a name that says nothing. For that source the result goes to the user's Downloads folder (or
      %LOCALAPPDATA%\ChameleonPatcher\Output when there is none) as
      "NVIDIA-<version>-<hash8><suffix>".

      -NvAppRoot and -UserOutputParent exist so tests can pin both places.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [switch]$IsExe,
        [string]$Suffix = '_Patched',
        [string]$NvAppRoot,
        [string]$UserOutputParent
    )
    $parent = Split-Path $SourcePath -Parent
    if ($IsExe) { return (Join-Path $parent ([System.IO.Path]::GetFileNameWithoutExtension($SourcePath) + $Suffix)) }

    $leaf = Split-Path $SourcePath -Leaf
    if (-not $NvAppRoot) { $NvAppRoot = Get-NvAppStagedRoot }
    $staged = $false
    if ($NvAppRoot -and $parent) {
        $staged = [string]::Equals($parent.TrimEnd('\'), $NvAppRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $staged) { return (Join-Path $parent ($leaf + $Suffix)) }

    if (-not $UserOutputParent) {
        $downloads = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Downloads' } else { $null }
        if ($downloads -and (Test-Path -LiteralPath $downloads -PathType Container)) { $UserOutputParent = $downloads }
        elseif ($env:LOCALAPPDATA) { $UserOutputParent = Join-Path $env:LOCALAPPDATA 'ChameleonPatcher\Output' }
        else { return (Join-Path $parent ($leaf + $Suffix)) }
    }
    $version = Get-SetupCfgVersion -PackagePath $SourcePath
    $short = if ($leaf.Length -gt 8) { $leaf.Substring(0, 8) } else { $leaf }
    $name = if ($version) { "NVIDIA-$version-$short" } else { "NVIDIA-$short" }
    # Path.Combine, not Join-Path: Join-Path resolves the drive and throws for one that is not
    # there (a redirected Downloads on an unplugged disk); the run's own "cannot create" error is
    # the clearer one.
    return [System.IO.Path]::Combine($UserOutputParent, ($name + $Suffix))
}

# --- Boot state: Test Signing and Secure Boot ------------------------------------------------------
function Test-StartOptionsTestSigning {
    <#
      Does a SystemStartOptions string (HKLM\SYSTEM\CurrentControlSet\Control) say this boot runs
      with Test Signing on. The kernel writes the load options of the CURRENT boot there as plain
      upper-case tokens (" NOEXECUTE=OPTIN  TESTSIGNING"), in every display language - unlike
      bcdedit, whose "testsigning  Yes" value text is localized and which needs elevation to answer
      at all. Token match, not a substring: NOTESTSIGNING-style neighbours must not count.
    #>
    param([string]$StartOptions)
    if (-not $StartOptions) { return $false }
    return [bool]($StartOptions -match '(^|\s)TESTSIGNING(\s|$)')
}

function Get-BootSigningState {
    <#
      @{ TestSigning; SecureBoot }, each $true, $false or $null (could not be read). Both come from
      the registry, so the answer needs no elevation and does not depend on the display language.
        TestSigning  this boot's SystemStartOptions (see Test-StartOptionsTestSigning). It reflects
                     the boot that is RUNNING: "bcdedit /set testsigning on" without a reboot is
                     still $false here, which is the honest answer to "will the driver load now".
        SecureBoot   SecureBoot\State\UEFISecureBootEnabled. With Secure Boot on, Windows refuses
                     to turn Test Signing on at all, so a self-signed driver cannot load.
    #>
    $test = $null; $secure = $null
    try {
        $ctl = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control' -ErrorAction Stop
        $test = Test-StartOptionsTestSigning -StartOptions ([string]$ctl.SystemStartOptions)
    } catch { $test = $null }
    try {
        $sb = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop
        $secure = ([int]$sb.UEFISecureBootEnabled -ne 0)
    } catch { $secure = $null }   # legacy BIOS boot: the key does not exist, and neither does Secure Boot
    return [PSCustomObject]@{ TestSigning = $test; SecureBoot = $secure }
}

function Get-BootSigningAdvice {
    <#
      The warning lines (possibly none) a boot state earns, shared by the pipeline's preflight and
      Approve-DriverPatchCert.ps1 so both say the same thing. Takes the state as a parameter so the
      wording is testable without touching the machine.
    #>
    param([Parameter(Mandatory = $true)]$State)
    $lines = @()
    if ($State.SecureBoot -eq $true) {
        $lines += "Secure Boot is ON. Windows will not enable Test Signing while it is on, so a driver signed with a self-signed certificate cannot load on this PC until Secure Boot is turned off in the firmware setup."
    }
    if ($State.TestSigning -eq $false) {
        $lines += "Test Signing mode is OFF on this boot. Trusting the certificate alone will not let the patched driver load - run 'bcdedit /set testsigning on' (elevated, Secure Boot off) and reboot, or disable driver signature enforcement for one boot."
    }
    return $lines
}
