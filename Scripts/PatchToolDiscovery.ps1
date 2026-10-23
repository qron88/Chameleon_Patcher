<#
.SYNOPSIS
  Shared discovery for the external tools the patch pipeline shells out to
  (a 7z-compatible CLI, Inf2Cat.exe, signtool.exe), plus a safe native-command runner.

.DESCRIPTION
  Dot-source this from any script in this folder:

      . (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

  Provides:
    Find-SevenZip            - locate a 7z-compatible CLI: unpacking a driver .exe needs one
    Test-DriverPackageRoot    - does a folder look like an unpacked driver package
    Find-WdkTool             - locate a Windows Kits tool (Inf2Cat.exe / signtool.exe)
    Assert-PatchTools        - resolve everything up front so a missing tool fails in seconds
                               instead of after a multi-GB unpack/copy
    Get-MissingToolHelp      - plain-language install guidance for a tool that was not found
    Invoke-NativeTool        - run a native exe and return its exit code, without letting its
                               stderr become a terminating error
    Resolve-WhitelistInf     - map a whitelist.json INF name onto the file this driver release
                               actually ships, since NVIDIA renames them between builds
    Get-SigningCerCandidates - the public .cer files to try, in the one order every script uses
    Resolve-SigningCertificate - work out which certificate to sign with, preferring a
                               passwordless key already in the certificate store
    Save-SigningCerIfMissing - write the public .cer for a certificate found only in the store
    Remove-OldDriverPatchCerts - remove old driver-patch signing certs from Cert:\CurrentUser\My,
                                protecting the one you sign with (the safe half of cert cleanup)
    Get-InfDeviceLine        - parse an INF models line into its token, install section and
                               NVIDIA hardware IDs
    Test-InfDeviceIdMatch    - the single rule for "does this hardware ID match DEV/SUBSYS",
                               shared by the patcher, the prune step and the verification gate
    Get-WhitelistEntries /
    Test-WhitelistCoversDevice - the same rule on the whitelist side: entries flattened once, and
                               one answer to "does whitelist.json cover this DEV/SUBSYS"
    Get-LocalNvidiaGpu       - the display-class NVIDIA GPUs in this machine, with DEV/SUBSYS
                               already parsed out
    Test-WhitelistCoversLocalGpu - whether any GPU in this machine is one whitelist.json
                               actually unlocks, which is what a pruned build depends on
    Get-InfTextFile          - a text file read once, keeping everything its bytes say about how
                               to write it back: BOM state, newline style, codepage (strict UTF-8
                               with an ANSI fallback), trailing newline. Get-AnsiEncoding resolves
                               the codepage the same way on PS 5.1 and PS 7. Write-InfLines and
                               Write-InfText write through that state, so a patch never changes a
                               file's encoding, newlines or trailing newline
    Get-InfSectionIndex       - safe insertion point at the end of a section body, so a spliced
                                line never lands outside the section it belongs to
    Test-InfLineContinuations - report backslash continuations inside the sections we patch, which
                                the per-line matchers cannot see

  Resolution is memoized for the lifetime of the dot-sourcing script and re-validated with
  Test-Path on each hit, so an SDK that is updated or removed mid-run cannot leave a stale
  path behind. Paths are deliberately NOT persisted between runs for that same reason.
#>

$script:PatchToolCache = @{}

# Every subject name this project has ever issued signing certificates under: '*Chameleon*' is the
# current name, '*Driver Patch*' the previous one, '*FrankenDriver*' the hand-patched package this
# was reverse-engineered from. Shared by the store search in Resolve-SigningCertificate and by
# Remove-OldDriverPatchCerts, and must match Remove-DriverPatchCert.ps1's -SubjectPattern default.
# Add to this list rather than replacing it, or an old certificate becomes invisible to both.
$script:DriverPatchSubjectPatterns = @('*Chameleon*', '*Driver Patch*', '*FrankenDriver*')

function Invoke-NativeTool {
    <#
      Runs a native executable and returns its exit code.

      Native-command stderr is NOT redirected here on purpose. Under Windows PowerShell 5.1
      with $ErrorActionPreference='Stop', redirecting a native command's stderr (2>&1) wraps
      each stderr line in a NativeCommandError ErrorRecord and aborts the script even when the
      exe returns 0 - that is exactly the confirmed bug the old Sign-DriverPackage.ps1 had to
      work around for `signtool verify`. ErrorActionPreference is relaxed for the duration of
      the call as a second safety net, and success/failure is decided solely by the exit code.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments | Out-Host
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}

function Find-SevenZip {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (-not (Test-Path $ExplicitPath)) { throw "7z CLI not found at the path you passed: $ExplicitPath. There is no fallback route: name a real 7z-compatible CLI with -SevenZipPath, install one (winget install -e --id 7zip.7zip), or unpack the driver by hand and run the pipeline with -SourcePackagePath." }
        return (Resolve-Path $ExplicitPath).Path
    }

    $cacheKey = '7z'
    if ($script:PatchToolCache.ContainsKey($cacheKey)) {
        $cached = $script:PatchToolCache[$cacheKey]
        if ($cached -and (Test-Path $cached)) { return $cached }
        $script:PatchToolCache.Remove($cacheKey)
    }

    $candidates = @(
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\7z.exe",
        "${env:ProgramFiles}\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        "${env:ProgramFiles}\NanaZip\7z.exe",
        "${env:ProgramFiles(x86)}\NanaZip\7z.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $script:PatchToolCache[$cacheKey] = $c; return $c }
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { $script:PatchToolCache[$cacheKey] = $cmd.Source; return $cmd.Source }

    throw "No 7z-compatible CLI found (checked the WindowsApps alias, 7-Zip/NanaZip under Program Files, and PATH). Unpacking a driver .exe needs one and there is no fallback: install 7-Zip with  winget install -e --id 7zip.7zip   (NanaZip works too), or unpack the driver by hand and run the pipeline with -SourcePackagePath."
}

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

function Find-WdkTool {
    <#
      Locates a Windows Kits tool, preferring the NEWEST SDK version and, within that version,
      the x64 build when one exists (Inf2Cat.exe only ships as x86, signtool.exe ships as
      x86/x64/arm64).

      Selection is by parsed [version], not by string-sorting the full path. Older SDK layouts
      put signtool directly under bin\x64\ with no version folder, and a descending string sort
      ranks "...\bin\x64\..." above "...\bin\10.0.26100.0\x64\..." because 'x' > '1' - which on
      a machine carrying both layouts would silently select the OLDER tool. Paths with no
      parseable version segment get a sentinel 0.0 so they rank last but stay usable as a
      fallback.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ExeName,
        [string]$ExplicitPath
    )

    if ($ExplicitPath) {
        if (-not (Test-Path $ExplicitPath)) { throw "$ExeName not found at the path you passed: $ExplicitPath" }
        return (Resolve-Path $ExplicitPath).Path
    }

    $cacheKey = "wdk:$ExeName"
    if ($script:PatchToolCache.ContainsKey($cacheKey)) {
        $cached = $script:PatchToolCache[$cacheKey]
        if ($cached -and (Test-Path $cached)) { return $cached }
        $script:PatchToolCache.Remove($cacheKey)
    }

    $roots = @()
    if ($env:WDKContentRoot) { $roots += (Join-Path $env:WDKContentRoot 'bin') }
    $roots += "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $roots += "${env:ProgramFiles}\Windows Kits\10\bin"

    $candidates = @()
    foreach ($root in $roots) {
        if (Test-Path $root) {
            $candidates += Get-ChildItem -Path $root -Filter $ExeName -Recurse -ErrorAction SilentlyContinue
        }
    }

    if ($candidates.Count -gt 0) {
        $ranked = foreach ($c in $candidates) {
            $ver = [version]'0.0'
            if ($c.FullName -match '\\(\d+\.\d+\.\d+\.\d+)\\') {
                try { $ver = [version]$Matches[1] } catch { $ver = [version]'0.0' }
            }
            [PSCustomObject]@{
                Path    = $c.FullName
                Version = $ver
                IsX64   = [bool]($c.FullName -match '\\x64\\')
            }
        }
        $best = $ranked |
            Sort-Object -Property @{Expression = 'Version'; Descending = $true},
                                  @{Expression = 'IsX64';   Descending = $true} |
            Select-Object -First 1
        if ($best) {
            $script:PatchToolCache[$cacheKey] = $best.Path
            return $best.Path
        }
    }

    $cmd = Get-Command $ExeName -ErrorAction SilentlyContinue
    if ($cmd) { $script:PatchToolCache[$cacheKey] = $cmd.Source; return $cmd.Source }

    throw "$ExeName not found under Windows Kits (checked `$env:WDKContentRoot, Program Files (x86)/Program Files Windows Kits\10\bin, and PATH). Install the Windows Driver Kit / SDK, or pass an explicit path."
}

function Get-MissingToolHelp {
    <#
      Plain-language guidance for a tool that could not be found, for use in the message that
      refuses the run. The point is that the user gets something to act on, not a stack trace. A
      line indented by four is either an address or a terminal command: the GUI shows the address
      and offers to open it in the default browser, and drops the command lines because a window
      with a button that opens the page has no business asking anyone to type anything. A console
      prints both, because whoever is already in a terminal can install it from there. The people
      this message is written for most are the ones with no terminal open.
      the two hard dependencies (Inf2Cat, signtool) both come from the Windows SDK, which is a
      multi-GB install, and the old message said "Windows Driver Kit / SDK" - which reads as
      heavier than what is actually needed. Only the SDK is required; a full WDK is not. When both
      SDK tools are missing they are described once, because there is one package to download and
      one address to hand out.
    #>
    param([string[]]$ToolNames)

    $lines = @()

    # Asked for one tool, a tool-by-tool answer is right. Asked for both SDK tools, it is wrong: the
    # two blocks repeat the same address and the same advice, which reads as two problems when there
    # is one installer to fetch. The pair is described once, naming the two SDK features that have to
    # stay selected - which is the part people actually get wrong.
    $sdkMissing = @($ToolNames | Where-Object { $_ -eq 'Inf2Cat.exe' -or $_ -eq 'signtool.exe' })
    $covered = @()
    if ($sdkMissing.Count -eq 2) {
        $lines += "Both missing tools come from the same package - the"
        $lines += "Windows SDK - so one install fixes both:"
        $lines += ""
        $lines += "    https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/"
        $lines += ""
        $lines += "Inf2Cat.exe rebuilds nv_disp.cat after the INFs are"
        $lines += "edited, and it ships in the SDK as the 'Windows Driver"
        $lines += "Kit' feature. A full Windows Driver Kit install is NOT"
        $lines += "needed, the SDK alone is enough. signtool.exe signs the"
        $lines += "rebuilt catalog, and it ships as 'Windows SDK Signing"
        $lines += "Tools'. Keep both features selected."
        $lines += ""
        $covered = @('Inf2Cat.exe', 'signtool.exe')
    }

    foreach ($t in $ToolNames) {
        if ($covered -contains $t) { continue }
        switch ($t) {
            'Inf2Cat.exe' {
                $lines += "Inf2Cat.exe - rebuilds nv_disp.cat after the"
                $lines += "INFs are edited. It ships in the Windows SDK, as"
                $lines += "its 'Windows Driver Kit' feature. A full Windows"
                $lines += "Driver Kit install is NOT needed - the SDK alone"
                $lines += "is enough. Install the SDK from:"
                $lines += ""
                $lines += "    https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/"
                $lines += ""
                $lines += "and keep the 'Windows Driver Kit' selected."
            }
            'signtool.exe' {
                $lines += "signtool.exe - signs the rebuilt catalog. It"
                $lines += "ships in the Windows SDK, as its 'Windows SDK"
                $lines += "Signing Tools' feature. Install the SDK from:"
                $lines += ""
                $lines += "    https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/"
                $lines += ""
                $lines += "and keep 'Windows SDK Signing Tools' selected."
            }
            '7z' {
                $lines += "A 7z-compatible CLI is required to unpack a driver"
                $lines += ".exe, and none is installed. 7-Zip is free and lives on"
                $lines += "its own download page:"
                $lines += ""
                $lines += "    https://7-zip.org/"
                $lines += ""
                # Both of these lines are indented by four or more, which is how the GUI is told they
                # are for a terminal and not for its window: it shows addresses and leaves these out.
                $lines += "    From a terminal, the same install is:"
                $lines += "        winget install -e --id 7zip.7zip"
                $lines += ""
                $lines += "NanaZip, or any 7z-compatible CLI on PATH, is found the"
                $lines += "same way once it is installed. The other way through is"
                $lines += "-SourcePackagePath: unpack the driver yourself and hand"
                $lines += "this toolkit the folder it produced."
            }
            default {
                $lines += "$t - not found. Pass an explicit path, or install"
                $lines += "the Windows SDK from:"
                $lines += ""
                $lines += "    https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/"
            }
        }
        $lines += ""
    }
    return $lines
}

function Assert-PatchTools {
    <#
      Resolves every external tool a run will need BEFORE any unpacking/copying happens, so a
      missing SDK fails in seconds rather than after a multi-GB extraction. Returns a hashtable
      of the resolved paths.

      All three are hard requirements when -NeedSevenZip is set, and all three throw with an install
      command rather than falling back to something worse. 7-Zip became one the way Inf2Cat and
      signtool always were: NVIDIA's own installer was tried as the fallback for unpacking, it
      needs elevation and a click, and it unpacks into a system-temp folder a normal run may not be
      allowed to read, so it is not a route this toolkit is willing to depend on. Inf2Cat has no
      substitute either - editing INFs invalidates nv_disp.cat, and Inf2Cat is the only tool that
      rebuilds it.
    #>
    param(
        [switch]$NeedSevenZip,
        [string]$SevenZipPath,
        [string]$Inf2CatPath,
        [string]$SignToolPath
    )

    $resolved = @{}
    if ($NeedSevenZip) {
        # An explicit path is a hard request: if the caller named a CLI, use it and fail loudly
        # when it is not there, rather than quietly substituting a different route.
        # An explicit path is a hard request: if the caller named a CLI, use it and fail loudly
        # when it is not there, rather than quietly substituting a different one.
        $resolved['SevenZip'] = if ($SevenZipPath) { Find-SevenZip -ExplicitPath $SevenZipPath } else { Find-SevenZip }
    }

    $missing = @()
    $inf2cat = $null; $signtool = $null
    try { $inf2cat = Find-WdkTool -ExeName 'Inf2Cat.exe'  -ExplicitPath $Inf2CatPath }  catch { $missing += 'Inf2Cat.exe' }
    try { $signtool = Find-WdkTool -ExeName 'signtool.exe' -ExplicitPath $SignToolPath } catch { $missing += 'signtool.exe' }

    if ($missing.Count -gt 0) {
        $help = Get-MissingToolHelp -ToolNames $missing
        throw ("Required tools not found:`n" + ($help -join "`n") + "`nChecked `$env:WDKContentRoot, Windows Kits\10\bin under Program Files (x86) and Program Files, and PATH. Pass -Inf2CatPath / -SignToolPath to point at them directly.")
    }

    $resolved['Inf2Cat']  = $inf2cat
    $resolved['SignTool'] = $signtool
    return $resolved
}

# --- Shared INF layout helpers -------------------------------------------------------------------
# Each INF header pattern used to be written out separately in the patchers and in the verification
# gate: the whitelist patcher required a header at column 0 while the gate allowed leading
# whitespace, and the RM-override patcher allowed a "]" inside the header text. A header one side
# failed to recognise is a section that side silently never looked at - so the gate could certify a
# layout the patchers never understood, or a patcher could mistake a section boundary and splice a
# line into the wrong place. Keep every header test on these constants instead.
$script:InfSectionHeaderRx = [regex]'^\s*\[([^\]]+)\]\s*$'
$script:InfDeviceBlockRx = '^\s*\[NVIDIA_Devices[^\]]*\]\s*$'
$script:InfMiscBaseAddRegRx = '^\s*\[nv_miscBase_addreg__\d+\]\s*$'

function Get-InfSectionIndex {
    <#
      The index at which a body line can be appended to the section starting at HeaderIndex without
      landing outside that section.

      The scanners report EndIndex as an UPPER BOUND, not as a safe insertion point: for the last
      section of a file it is the end of the file. Inserting there puts the new line in the blank
      run after the section, where it belongs to no section at all - for a spliced [Strings]
      definition that means the %Key% token on a device line still reads as undefined to the
      verification gate, which reads the definitions out of the [Strings] body. Blank and comment
      lines at the tail of a body are still inside the section, so walking back over them keeps the
      line in place whatever follows it, including a section that ends the file.
    #>
    param(
        # $Lines is deliberately untyped, like Find-InfDeviceLine's: a Mandatory [string[]] parameter
        # refuses to bind an array whose ELEMENTS include an empty string, and an INF body is full of
        # blank lines - confirmed on PowerShell 5.1 and 7.6. The patchers pass a List[string] here anyway.
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][int]$HeaderIndex,
        [int]$EndIndex = -1
    )
    if ($EndIndex -lt 0 -or $EndIndex -gt $Lines.Count) { $EndIndex = $Lines.Count }
    $at = $EndIndex
    while ($at -gt $HeaderIndex + 1) {
        $tail = ([string]$Lines[$at - 1]).Trim()
        if ($tail -eq '' -or $tail.StartsWith(';')) { $at--; continue }
        break
    }
    return $at
}

function Test-InfLineContinuations {
    <#
      Every INF matcher in this toolkit - the device-line matcher, the section scanners, the
      RM-override presence test, the [Strings] definition scan - reads one physical line at a time.
      INF also lets a logical line be split across physical lines with a trailing backslash, and a
      split device entry stays invisible to the entry matcher while still resolving at install time;
      a split RM1457588 line stays invisible to the presence test, and a split [Strings] definition
      makes a key that IS defined look undefined. Folding continuations into the line buffers would
      rewrite unrelated bytes of an already-patched package, so this reports them instead.

      Scoped to the sections the matchers work on: driver INFs use backslash continuations freely
      elsewhere (CopyFiles, AddReg lists), and warning about those would bury the one warning that
      matters. Returns the number of continued lines found in the sections of interest.
    #>
    param([string]$Path, [string[]]$Lines)
    $section = $null
    $flagged = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $headerMatch = $script:InfSectionHeaderRx.Match([string]$Lines[$i])
        if ($headerMatch.Success) { $section = $headerMatch.Groups[1].Value.Trim(); continue }
        $text = [string]$Lines[$i]
        # The backslash has to be the last non-blank character of the line: INF tolerates spaces
        # after it and Get-Content keeps them, so a plain EndsWith check would miss exactly the kind
        # of split this check exists to find.
        if ($text -notmatch '\\\s*$') { continue }
        if ($section -and $section -match '^(?i:NVIDIA_Devices|nv_miscBase_addreg__|Strings($|\.))') { $flagged += ($i + 1) }
    }
    if ($flagged.Count -eq 0) { return 0 }
    $shown = ($flagged | Select-Object -First 8) -join ', '
    $more = ''
    if ($flagged.Count -gt 8) { $more = " (+$($flagged.Count - 8) more)" }
    Write-Warning "$(Split-Path $Path -Leaf): $($flagged.Count) continued line(s) (trailing backslash) inside the sections this toolkit patches, at line(s) $shown$more. The per-line matchers read one physical line at a time, so a continued device entry, [Strings] definition or RM override is invisible to them - check that none of those is split across lines before trusting this package."
    return $flagged.Count
}

function Get-LocalNvidiaGpu {
    <#
      Every NVIDIA GPU in this machine, as objects carrying the DeviceID, the friendly name, and
      the DEV/SUBSYS already parsed out and upper-cased.

      Display-class only. An NVIDIA GPU also exposes an HD Audio function on the same PCI device
      (e.g. DEV_2291 alongside DEV_25B8), driven by HDAudBus and the HDAudio subpackage, never by
      a display INF - so including it would just produce a device that matches nothing and a
      pointless warning.

      $WhatIfPreference is forced off around the read. Get-CimInstance has no -WhatIf of its own,
      but under -WhatIf the CimCmdlets module autoloads with the preference set and reports a
      dozen "What if: Set Alias" lines, burying the actual dry-run output.

      -AllowNonDisplayFallback keeps NVIDIA PCI devices that report no Display class when NONE of
      them does, on the theory that a machine with an NVIDIA device and an odd PNPClass is better
      served by a guess than by "no GPU found". Callers that only want a label pass it off, so a
      stray audio function can never end up named in an output folder.
    #>
    param([switch]$AllowNonDisplayFallback)

    $prevWhatIf = $WhatIfPreference
    $WhatIfPreference = $false
    try {
        $pnp = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                 Where-Object { $_.DeviceID -like 'PCI\VEN_10DE*' })
    }
    catch { $pnp = @() }
    finally { $WhatIfPreference = $prevWhatIf }

    $display = @($pnp | Where-Object { $_.PNPClass -eq 'Display' -or $_.Service -eq 'nvlddmkm' })
    if ($display.Count -eq 0 -and $pnp.Count -gt 0 -and $AllowNonDisplayFallback) {
        Write-Warning "Found NVIDIA PCI devices but none of Display class - falling back to all of them."
        $display = $pnp
    }

    return @($display | ForEach-Object {
        $dev = $null; $sub = $null
        if ($_.DeviceID -match 'DEV_([0-9A-Fa-f]{4})')    { $dev = $Matches[1].ToUpperInvariant() }
        if ($_.DeviceID -match 'SUBSYS_([0-9A-Fa-f]{8})') { $sub = $Matches[1].ToUpperInvariant() }
        [PSCustomObject]@{
            DeviceID = $_.DeviceID
            Name     = $_.Name
            Dev      = $dev
            Subsys   = $sub
            Label    = $(
                $id = "DEV_$dev"
                if ($sub) { $id += "&SUBSYS_$sub" }
                if ($_.Name) { "$($_.Name) ($id)" } else { $id }
            )
        }
    } | Where-Object { $_.Dev })
}

function Get-WhitelistEntries {
    <#
       Every entry in a parsed whitelist.json, flattened to one object per entry (Key, Dev, Subsys,
       Description), so callers that only need to ask "does whitelist.json cover this device" do not
       each re-walk the JSON's key-by-array structure and each invent their own idea of what an
       entry's fields are called.

       Wrap the call in @(). A whitelist with a single entry returns a bare PSCustomObject there,
       and on Windows PowerShell 5.1 a PSCustomObject has no .Count, so an unwrapped "$entries.Count"
       reads as nothing rather than as one.

       Dev and Subsys come back exactly as whitelist.json writes them, not folded to upper case: the
       callers that compare them use PowerShell's case-insensitive operators or a HashSet built with
       OrdinalIgnoreCase, so a whitelist written in lower case still matches, and normalising here
       would only make a printed entry disagree with its own file.
    #>
    param([Parameter(Mandatory = $true)]$Whitelist)
    $entries = @()
    foreach ($key in $Whitelist.PSObject.Properties.Name) {
        foreach ($e in @($Whitelist.$key)) {
            $entries += [PSCustomObject]@{
                Key         = $key
                Dev         = [string]$e.dev
                Subsys      = [string]$e.subsys
                Description = [string]$e.description
            }
        }
    }
    return $entries
}

function Test-WhitelistCoversDevice {
    <#
       The whitelist half of the rule Test-InfDeviceIdMatch applies to INF lines: an entry with no
       SUBSYS covers every subsystem of that DEV, otherwise both halves have to match. Sharing it
       matters because the local-GPU gate and the prune step's safety net are the same question, and
       the safety net used to ask it with DEV alone - which reported a subsystem-specific entry as
       covering a GPU that entry cannot install on, exactly the false "this build is for you" that
       the gate exists to catch.

       Returns the matching entry, or $null when nothing in the whitelist covers the device.
    #>
    param(
        # Not Mandatory on purpose: PowerShell reads an empty array as $null for a mandatory
        # parameter and then prompts for it, and "this whitelist has no entries" is a real answer.
        [array]$Entries = @(),
        [Parameter(Mandatory = $true)][string]$Dev,
        [string]$Subsys
    )
    foreach ($e in $Entries) {
        if (Test-InfDeviceIdMatch -Id $e -Dev $Dev -Subsys $Subsys -Mode Hardware) { return $e }
    }
    return $null
}

function Test-WhitelistCoversLocalGpu {
    <#
      Is any GPU in this machine one that whitelist.json actually unlocks?

      This is the question a PRUNED build turns on. Pruning cuts the package down to the INFs that
      can match this machine, so if none of this machine's GPUs is a whitelist target, what comes
      out is a driver for hardware that never needed unlocking: the whitelist entries are spliced
      into an INF where nothing present can match them, and the package is then re-signed with a
      certificate Windows does not trust. Confirmed on a box with an RTX 5070 Ti (DEV_2C05), which
      the stock generic INF already carries a bare DEV line for - the run completed, reported
      "verification PASSED", and had unlocked nothing.

      A UNIVERSAL build is a different question and this must not be applied to it. There the
      whole package is kept, every whitelist entry lands in it, and the machine doing the building
      is irrelevant - patching on a 5070 Ti box for a laptop with a locked GPU is a perfectly
      ordinary thing to do.

      Coverage follows the same rule as the prune step, because it IS the same call:
      Test-WhitelistCoversDevice, where a whitelist entry with no subsystem covers every subsystem
      of that device and otherwise both halves must match.

      Detected=$false means no GPU could be read at all (no NVIDIA device, a WMI failure, a
      driverless PCI device). That is NOT the same as "not a target" and callers must not treat it
      as one - there is simply nothing to judge.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WhitelistPath
    )

    if (-not (Test-Path $WhitelistPath)) { throw "whitelist.json not found: $WhitelistPath" }
    $whitelist = Get-Content $WhitelistPath -Raw | ConvertFrom-Json

    $gpus = @(Get-LocalNvidiaGpu -AllowNonDisplayFallback)
    # Plain arrays, not List[object]: a machine has a handful of GPUs so += costs nothing, and
    # under Windows PowerShell 5.1 `[PSCustomObject]@{ K = @($list) }` throws "argument types do
    # not match" for a generic List, which is a needlessly obscure way to fail.
    $covered = @()
    $uncovered = @()

    # Wrapped in @() because a whitelist with exactly ONE entry comes back as a bare object on
    # Windows PowerShell 5.1, where a PSCustomObject has no .Count at all and the count would
    # silently read as empty.
    $entries = @(Get-WhitelistEntries -Whitelist $whitelist)

    foreach ($g in $gpus) {
        # A PCI device with no DEV_ in its ID has nothing to match, so it counts as "not covered"
        # rather than as a judgeable target; Dev is what both halves of the rule start from.
        if (-not $g.Dev) { $uncovered += $g; continue }
        $e = Test-WhitelistCoversDevice -Entries $entries -Dev ([string]$g.Dev) -Subsys ([string]$g.Subsys)
        if (-not $e) { $uncovered += $g; continue }
        $hit = "DEV_$($e.Dev)"
        if ($e.Subsys)      { $hit += "&SUBSYS_$($e.Subsys)" }
        if ($e.Description) { $hit += " ($($e.Description))" }
        $covered += [PSCustomObject]@{ Gpu = $g; Entry = $hit }
    }

    return [PSCustomObject]@{
        Detected      = ($gpus.Count -gt 0)
        Gpus          = $gpus
        Covered       = $covered
        Uncovered     = $uncovered
        AnyCovered    = ($covered.Count -gt 0)
        EntryCount    = $entries.Count
        WhitelistPath = $WhitelistPath
    }
}

function Get-LocalGpuTag {
    <#
      A short, filesystem-safe tag naming the GPU(s) in this machine, for labelling a pruned
      output folder: "RTX-A2000m", or "RTX-5070-Ti+RTX-A2000m" on a multi-GPU box.

      A pruned package only installs on the hardware it was built for, so the folder name is the
      only thing distinguishing it from a universal build once you have a few of them side by
      side. Falls back to the device IDs if the friendly names are unusable, and to "ThisPC" if
      no GPU can be read at all - the tag is a label, so it must never be the reason a run fails.

      This is the single source of truth for that tag. The pipeline calls it for the default
      output path, and the GUI gets the same answer by asking the pipeline with -ShowOutputPath
      rather than reimplementing the rule.
    #>
    param([int]$MaxLength = 40)

    $names = @()
    try {
        # No -AllowNonDisplayFallback: a tag is a label, and labelling a folder after the GPU's
        # HD Audio function would be worse than the "ThisPC" fallback below.
        foreach ($d in @(Get-LocalNvidiaGpu)) {
            $n = $d.Name
            if (-not $n) { $n = "DEV" + $d.Dev }
            if (-not $n) { continue }
            # "NVIDIA RTX A2000m" -> "RTX-A2000m"
            $n = $n -replace '(?i)^\s*NVIDIA\s+', ''
            $n = $n -replace '(?i)\((R|TM)\)', ''
            $n = $n -replace '[^A-Za-z0-9]+', '-'
            $n = $n.Trim('-')
            if ($n) { $names += $n }
        }
    }
    catch { }

    $names = @($names | Select-Object -Unique)
    if ($names.Count -eq 0) { return "ThisPC" }

    $tag = $names -join '+'
    if ($tag.Length -gt $MaxLength) {
        # Too long to be a sensible folder name: fall back to the first GPU, then to a plain label.
        $tag = $names[0]
        if ($tag.Length -gt $MaxLength) { $tag = $tag.Substring(0, $MaxLength).Trim('-') }
        if (-not $tag) { $tag = "ThisPC" }
    }
    return $tag
}

function Resolve-WhitelistInf {
    <#
      Maps a whitelist.json key (an INF filename) to the actual file(s) in a Display.Driver folder.

      NVIDIA does not keep INF filenames stable between builds. The 616.86 desktop-notebook hotfix
      appends a 'g' to every stem - nv_dispi.inf becomes nv_dispig.inf, nvami.inf becomes
      nvamig.inf, uniformly across all 43 INFs. Looking the names up literally made the whitelist
      step skip both target INFs and apply nothing at all, while the RM-override step (which globs
      *.inf and so never cared about names) still ran. The package therefore came out installable,
      correctly signed, and with no GPU unlock whatsoever.

      This deliberately is NOT a "notebook builds use g" rule. The 581.94 desktop-notebook hotfix
      uses the ordinary names, so the suffix is a per-build quirk, not a flavour convention, and
      hardcoding it would just fail differently on the next release.

      Nor is the quirk always an APPENDED letter, which is what a plain "<stem>*.inf" glob assumes.
      The 616.92 Studio build (nsd-dch) renames by replacing the trailing flavour letter instead:
      nv_dispi.inf ships as nv_dispsi.inf and nvami.inf as nvamsi.inf, uniformly across all 45.
      Neither starts with "nv_dispi" / "nvami", so the glob matched nothing, and the failure was
      worse than 616.86's: the prune step's own fallback resolves through this function too, so it
      kept zero INFs and deleted all 45 before the whitelist step threw.

      So the lookup runs widest-last, in three tiers:
        1. An exact filename match always wins.
        2. "<stem>*.inf"  - the suffixed case (616.86).
        3. "<stem minus its last character>*.inf" - the substituted-letter case (616.92). Gated on
           a core of at least 4 characters so a short stem can never widen to something like n*.inf.
      Tier 3 only runs when the tighter tiers found nothing, so a release using the ordinary names
      never reaches it. Callers report which file stood in for the requested name rather than
      substituting silently.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DisplayDriverPath,
        [Parameter(Mandatory = $true)][string]$InfName
    )

    $exact = Join-Path $DisplayDriverPath $InfName
    if (Test-Path $exact) {
        return @([PSCustomObject]@{ Path = (Resolve-Path $exact).Path; Name = $InfName; Exact = $true })
    }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($InfName)

    # Tier 2, then tier 3. Not $matches - that is an automatic variable populated by -match.
    $globs = @($stem)
    if ($stem.Length -ge 5) { $globs += $stem.Substring(0, $stem.Length - 1) }

    foreach ($g in $globs) {
        $hits = @(Get-ChildItem -LiteralPath $DisplayDriverPath -Filter ($g + '*.inf') -File -ErrorAction SilentlyContinue |
                  Sort-Object Name)
        if ($hits.Count -eq 0) { continue }
        return @($hits | ForEach-Object {
            [PSCustomObject]@{ Path = $_.FullName; Name = $_.Name; Exact = $false }
        })
    }
    return @()
}

function Get-SigningCerCandidates {
    <#
      The public .cer files to try when working out which certificate to sign with or trust, in
      the one order the pipeline, Sign-DriverPackage.ps1 and Approve-DriverPatchCert.ps1 all use:

        1. The .cer next to an explicitly passed .pfx.
        2. DriverPatchSigning_<thumbprint>.cer files, most recently written first. That is the
           name New-DriverSigningCert.ps1 gives every certificate it mints.
        3. The legacy fixed name DriverPatchSigning.cer, last.

      Paths are returned whether or not they exist; callers skip the missing ones.
    #>
    param(
        [string]$CertificatesDir,
        [string]$PfxPath
    )
    $candidates = @()
    if ($PfxPath) { $candidates += [System.IO.Path]::ChangeExtension($PfxPath, '.cer') }
    if ($CertificatesDir) {
        if (Test-Path -LiteralPath $CertificatesDir) {
            $candidates += @(Get-ChildItem -LiteralPath $CertificatesDir -Filter 'DriverPatchSigning_*.cer' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName })
        }
        $candidates += (Join-Path $CertificatesDir 'DriverPatchSigning.cer')
    }
    return $candidates
}

function Get-CerThumbprint {
    # Thumbprint of a public .cer file, or $null if it is missing or unreadable.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $pub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $Path
        $tp = $pub.Thumbprint
        $pub.Dispose()
        return $tp
    }
    catch { return $null }
}

function Test-DriverPatchSubject {
    param([string]$Subject)
    foreach ($p in $script:DriverPatchSubjectPatterns) {
        if ($Subject -like $p) { return $true }
    }
    return $false
}

function Resolve-SigningCertificate {
    <#
      Works out WHICH certificate this run will sign with, and whether it can be used
      passwordlessly.

      Order of preference:
        1. An explicit thumbprint.
        2. A public .cer whose matching private key is already in Cert:\CurrentUser\My. Reading
           a .cer needs no password at all, so this is what turns a normal re-run into a
           zero-prompt one: New-SelfSignedCertificate always leaves the key in that store, so on
           the machine that generated the cert the .pfx password is simply not needed to sign.
        3. With -SearchStore: a project certificate in Cert:\CurrentUser\My, found by subject,
           with a private key, a code-signing EKU and time left on it. One already trusted in
           LocalMachine\Root wins, then the one that expires last. This is what keeps a deleted
           or emptied Certificates folder from looking like "no certificate at all" - the key is
           non-exportable, so minting a new one and pruning the old would lose it for good.
        4. Nothing - caller falls back to a .pfx + password, or generates a fresh cert.

      Returns $null when no usable store certificate was found.
    #>
    param(
        [string]$Thumbprint,
        [string[]]$CerPathCandidates = @(),
        [switch]$SearchStore
    )

    if ($Thumbprint) {
        $tp = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
        $hit = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $tp -and $_.HasPrivateKey } |
            Select-Object -First 1
        if (-not $hit) {
            throw "No certificate with thumbprint $tp (and an available private key) was found in Cert:\CurrentUser\My. Import its .pfx first (Import-PfxCertificate), or pass -PfxPath with its password instead."
        }
        return $hit
    }

    foreach ($cer in $CerPathCandidates) {
        $tp = Get-CerThumbprint -Path $cer
        if (-not $tp) { continue }
        $hit = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Thumbprint -eq $tp -and
                $_.HasPrivateKey -and
                $_.NotAfter -gt (Get-Date)
            } |
            Select-Object -First 1
        if ($hit) { return $hit }
    }

    if ($SearchStore) {
        $now = Get-Date
        $trusted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($c in @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue)) { [void]$trusted.Add($c.Thumbprint) }

        $usable = @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object {
            $c = $_
            $codeSigning = @($c.Extensions | Where-Object {
                $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] -and
                @($_.EnhancedKeyUsages | ForEach-Object { $_.Value }) -contains '1.3.6.1.5.5.7.3.3'
            }).Count -gt 0
            $c.HasPrivateKey -and $c.NotAfter -gt $now -and $codeSigning -and (Test-DriverPatchSubject $c.Subject)
        })
        if ($usable.Count -gt 0) {
            return ($usable |
                Sort-Object -Property @{ Expression = { $trusted.Contains($_.Thumbprint) }; Descending = $true },
                                      @{ Expression = 'NotAfter'; Descending = $true } |
                Select-Object -First 1)
        }
    }

    return $null
}

function Save-SigningCerIfMissing {
    <#
      Makes sure the public half of a store certificate is on disk as
      DriverPatchSigning_<thumbprint>.cer, so Approve-DriverPatchCert.ps1 and the next run find it
      the ordinary way. Returns the path written, or $null when a matching .cer already existed.
      Exporting the public half needs no password and touches no private key.
    #>
    param(
        [Parameter(Mandatory = $true)]$Certificate,
        [Parameter(Mandatory = $true)][string]$CertificatesDir
    )
    foreach ($p in (Get-SigningCerCandidates -CertificatesDir $CertificatesDir)) {
        if ((Get-CerThumbprint -Path $p) -eq $Certificate.Thumbprint) { return $null }
    }
    if (-not (Test-Path -LiteralPath $CertificatesDir)) {
        New-Item -ItemType Directory -Path $CertificatesDir -Force | Out-Null
    }
    $path = Join-Path $CertificatesDir ("DriverPatchSigning_" + $Certificate.Thumbprint + ".cer")
    [System.IO.File]::WriteAllBytes($path, $Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    return $path
}

function Remove-OldDriverPatchCerts {
    <#
      Removes old driver-patch signing certificates from Cert:\CurrentUser\My, protecting the
      one this run signs with. This is the safe, automatic half of certificate cleanup: it only
      touches the per-user My store, needs no elevation, and withdraws no trust, so it cannot
      break an already-patched package. The destructive half - withdrawing trust from the Root /
      CA / TrustedPublisher stores - stays opt-in via Remove-DriverPatchCert.ps1, because that
      needs elevation and means catalogs signed by the removed certificate stop validating.

      New-DriverSigningCert.ps1 mints a fresh certificate on every run and never removed the
      old ones, so repeated use left a growing pile of self-signed signing keys here. This gets
      that pile back down to the one certificate you actually use.

      Enumeration and removal go through the cert: provider (Get-ChildItem / Remove-Item) rather
      than the X509Store class, because on some machines X509Store.Open('ReadWrite') is refused
      (access denied) even though the provider can remove the certificate just fine.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$KeepThumbprint
    )

    $keep = $KeepThumbprint.ToUpperInvariant()
    $toRemove = @()
    foreach ($c in @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue)) {
        if ($c.Thumbprint.ToUpperInvariant() -eq $keep) { continue }
        if (Test-DriverPatchSubject $c.Subject) { $toRemove += $c }
    }
    if ($toRemove.Count -eq 0) {
        Write-Host "  No old patch certificates to remove from Cert:\CurrentUser\My." -ForegroundColor DarkGray
        return
    }
    $failed = 0
    foreach ($c in $toRemove) {
        try {
            Remove-Item ("Cert:\CurrentUser\My\" + $c.Thumbprint) -ErrorAction Stop
        }
        catch {
            Write-Warning ("  FAILED   " + $c.Thumbprint + " : " + $_.Exception.Message)
            $failed++
        }
    }
    $done = $toRemove.Count - $failed
    Write-Host ("  Removed " + $done + " old patch certificate(s) from Cert:\CurrentUser\My" + $(if ($failed) { ", " + $failed + " failed" } else { "" }) + ":") -ForegroundColor DarkGray
    foreach ($c in $toRemove) {
        Write-Host ("    " + $c.Thumbprint + "  " + $c.Subject) -ForegroundColor DarkGray
    }
}

function Get-InfDeviceLine {
    <#
      Parses one INF models-section line,

          %NVIDIA_DEV.1E90% = Section001, PCI\VEN_10DE&DEV_1E90&SUBSYS_000010DE

      into its %token%, its install section and the NVIDIA PCI hardware IDs it lists (a line may
      list several, comma-separated). Returns $null for anything that is not such a line. A
      trailing "; comment" is ignored, and every qualifier after DEV other than SUBSYS (REV_, CC_,
      ...) is kept in Extra rather than being silently dropped or silently tolerated - what to make
      of it is Test-InfDeviceIdMatch's decision, made the same way for every caller.
    #>
    param([string]$Line)

    if (-not $Line -or $Line.IndexOf('VEN_10DE', [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $null }
    $body = ($Line -split ';', 2)[0]
    if ($body -notmatch '^\s*%([^%]+)%\s*=\s*([^,]+?)\s*,\s*(.+?)\s*$') { return $null }
    $token = $Matches[1].Trim()
    $section = $Matches[2].Trim()
    $rest = $Matches[3]

    $ids = @()
    foreach ($raw in ($rest -split ',')) {
        $hw = $raw.Trim()
        if ($hw -notmatch '^PCI\\VEN_10DE&DEV_([0-9A-Fa-f]{4})((?:&[A-Za-z]+_[0-9A-Fa-f]+)*)$') { continue }
        $dev = $Matches[1].ToUpperInvariant()
        $quals = $Matches[2]
        $sub = $null
        $extra = @()
        foreach ($q in ($quals -split '&')) {
            if (-not $q) { continue }
            if (-not $sub -and $q -match '^SUBSYS_([0-9A-Fa-f]{8})$') { $sub = $Matches[1].ToUpperInvariant() }
            else { $extra += $q.ToUpperInvariant() }
        }
        $ids += [PSCustomObject]@{ Dev = $dev; Subsys = $sub; Extra = $extra; HardwareId = $hw }
    }
    if ($ids.Count -eq 0) { return $null }
    return [PSCustomObject]@{ Token = $token; Section = $section; Ids = $ids }
}

function Test-InfDeviceIdMatch {
    <#
      The single rule for whether a parsed hardware ID (from Get-InfDeviceLine) matches a device.
      Every script that asks this question goes through here, so the patcher, the prune step, the
      optional-components step and the verification gate can no longer disagree about it.

        Entry     Is this exactly the whitelist entry DEV[/SUBSYS]? Same DEV, same SUBSYS (or both
                  absent), and no extra qualifiers. A stock "...&SUBSYS_X&REV_A1" line only matches
                  revision A1, so it does not count as the entry being present - the patcher adds
                  its own line and the gate looks for exactly that.
        Hardware  Could this line install on a device with DEV/SUBSYS? Same DEV, and either no
                  SUBSYS (covers every subsystem) or the same SUBSYS. Extra qualifiers are
                  tolerated: their exact values are not known here, and for the prune step keeping
                  an INF that might match only costs time, while dropping one that does match
                  breaks the install.
        Device    Any line for this DEV at all, whatever its SUBSYS or qualifiers - used to find a
                  stock install section already valid for the chip.
    #>
    param(
        [Parameter(Mandatory = $true)]$Id,
        [Parameter(Mandatory = $true)][string]$Dev,
        [string]$Subsys,
        [Parameter(Mandatory = $true)][ValidateSet('Entry', 'Hardware', 'Device')][string]$Mode
    )
    if ($Id.Dev -ne $Dev) { return $false }
    switch ($Mode) {
        'Entry'    { return (@($Id.Extra).Count -eq 0) -and ([string]$Id.Subsys -eq [string]$Subsys) }
        'Hardware' { return (-not $Id.Subsys) -or ($Subsys -and $Id.Subsys -eq $Subsys) }
        'Device'   { return $true }
    }
}

function Find-InfDeviceLine {
    <#
      First line in Lines[Start..End) that lists a hardware ID matching DEV/SUBSYS under Mode.
      Returns @{ Index; Parsed } or $null. A cheap substring test runs before the regex parse,
      since a large OEM INF has tens of thousands of lines and only a handful mention the device.
    #>
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [int]$Start = 0,
        [int]$End = -1,
        [Parameter(Mandatory = $true)][string]$Dev,
        [string]$Subsys,
        [Parameter(Mandatory = $true)][ValidateSet('Entry', 'Hardware', 'Device')][string]$Mode
    )
    if ($End -lt 0) { $End = $Lines.Count }
    $needle = "DEV_$Dev"
    for ($i = $Start; $i -lt $End; $i++) {
        if ($Lines[$i].IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $p = Get-InfDeviceLine -Line $Lines[$i]
        if (-not $p) { continue }
        foreach ($id in $p.Ids) {
            if (Test-InfDeviceIdMatch -Id $id -Dev $Dev -Subsys $Subsys -Mode $Mode) {
                return [PSCustomObject]@{ Index = $i; Parsed = $p }
            }
        }
    }
    return $null
}

function Get-AnsiEncoding {
    <#
       The system ANSI codepage as an Encoding, resolved the same way on both PowerShell editions.

       [System.Text.Encoding]::Default IS that codepage on Windows PowerShell 5.1 but became UTF-8
       in PowerShell 7, so a writer that used Default would read an ANSI file as different characters
       depending on which powershell the patch happened to run under - and a wrong decode is not an
       error, it is mangled vendor text that then gets written back that way for good. The current
       culture's ANSI codepage is the same number on both editions.
    #>
    $cp = 0
    try { $cp = (Get-Culture).TextInfo.ANSICodePage } catch { $cp = 0 }
    if ($cp -le 0) { $cp = 1252 }
    try   { return [System.Text.Encoding]::GetEncoding($cp) }
    catch { return [System.Text.Encoding]::GetEncoding(1252) }
}

function Get-InfTextFile {
    <#
       Read a text file ONCE, keeping everything its bytes say about how to write it back, so the
       patchers (which edit lines in memory and rewrite the whole file) cannot quietly change the
       encoding, the newline style or the trailing newline of a file that is later hashed by
       Inf2Cat and signed. Three things are tracked because all three are reachable here:

         BOM        NVIDIA's stock INFs and setup.cfg are BOM-less UTF-8, but a .nvi in the same
                    package can carry one. Set-Content -Encoding UTF8 always writes a BOM, and the
                    BOM-less writer this toolkit used before always drops one - either way the
                    package now differs from stock in a place no patch touched.
         Newlines   Get-Content splits on CRLF, LF and CR alike, and the old writer joined with
                    CRLF always, so an INF stored with bare LF came back with EVERY line ending
                    rewritten. Confirmed on a mixed file: 2 CRLF + 1 bare LF in, 3 CRLF out.
         Codepage   A driver package also carries OEM INFs written in the system ANSI codepage.
                    Reading those as UTF-8 does not fail - the invalid bytes silently become U+FFFD
                    and the accented strings are destroyed. So the bytes go through a STRICT UTF-8
                    decoder first, and only when that refuses is the file treated as ANSI (and
                    written back as ANSI, with a warning naming the file). UTF-16 BOMs are handled
                    the same way rather than being decoded as UTF-8 garbage.

       Returns Text (BOM removed), Lines (split on any newline, trailing empty line dropped the way
       Get-Content drops it), HasBom, NewLine, EndsWithNewline and Encoding (the writer's Encoding).
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes  = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $false
    $family = 'utf8'
    $text   = $null

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $hasBom = $true; $family = 'utf16le'
        $text = (New-Object System.Text.UnicodeEncoding($false, $false)).GetString($bytes)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $hasBom = $true; $family = 'utf16be'
        $text = (New-Object System.Text.UnicodeEncoding($true, $false)).GetString($bytes)
    }
    else {
        try {
            # throwOnInvalidBytes is what makes an ANSI file detectable instead of corruptible.
            $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
            # A BOM decodes to U+FEFF; keep it as the flag and strip it from the text below.
            $hasBom = ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF)
        }
        catch {
            $family = 'ansi'
            $ansi   = Get-AnsiEncoding
            $text   = $ansi.GetString($bytes)
            Write-Warning "$(Split-Path $Path -Leaf) is not valid UTF-8 - reading and rewriting it as $($ansi.WebName) so its bytes survive the patch."
        }
    }

    if ($hasBom -and $text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }

    switch ($family) {
        'utf16le'  { $enc = New-Object System.Text.UnicodeEncoding($false, [bool]$hasBom) }
        'utf16be'  { $enc = New-Object System.Text.UnicodeEncoding($true,  [bool]$hasBom) }
        'ansi'     { $enc = Get-AnsiEncoding }
        default    { $enc = New-Object System.Text.UTF8Encoding([bool]$hasBom) }
    }

    # Dominant newline. A file with any CRLF in it is written back with CRLF: mixed endings are
    # already a defect in the input, and normalising the few bare-LF lines is the smaller surprise.
    $crlf = 0; $bareLf = 0
    for ($i = 0; $i -lt $text.Length; $i++) {
        if ($text[$i] -ne "`n") { continue }
        if ($i -gt 0 -and $text[$i - 1] -eq "`r") { $crlf++ } else { $bareLf++ }
    }
    $newline = if ($crlf -eq 0 -and $bareLf -gt 0) { "`n" } else { "`r`n" }

    # Split the way Get-Content does, because that is what every caller's line numbering assumes:
    # the terminator that ENDS the file is not a final empty line ("a\r\n" is one line, while
    # "a\r\n\r\n", which ends with a genuinely blank line, is two). Stripping a single character
    # would leave the CR of that CRLF behind and invent an empty line, so strip CRLF as two and a
    # bare LF as one. A file whose only terminator is a bare CR is normalised to the dominant
    # newline; that ending predates Windows and does not occur in a driver package.
    $endsWithNewline = ($text.Length -gt 0 -and ($text[$text.Length - 1] -eq "`n" -or $text[$text.Length - 1] -eq "`r"))
    $core = $text
    if ($endsWithNewline) {
        $cut = $text.Length - 1
        if ($text[$text.Length - 1] -eq "`n" -and $text.Length -ge 2 -and $text[$text.Length - 2] -eq "`r") {
            $cut = $text.Length - 2
        }
        $core = $text.Substring(0, $cut)
    }
    $lines = @()
    if ($core.Length -gt 0) {
        $lines = @([regex]::Split($core, "`r`n|`n|`r"))
    }
    elseif ($text.Length -gt 0) {
        # The file was exactly one line terminator. Get-Content calls that one empty line, while a
        # truly empty file (text.Length 0) is zero lines - the difference only decides whether a
        # rewritten file keeps its lone blank line, but it decides it every time.
        $lines = @([string]::Empty)
    }

    return [PSCustomObject]@{
        Path            = $Path
        Text            = $text
        Lines           = $lines
        HasBom          = $hasBom
        Encoding        = $enc
        NewLine         = $newline
        EndsWithNewline = $endsWithNewline
    }
}

function Write-InfLines {
    <#
       Rewrite a text file (used for INFs) from a line array, through the state Get-InfTextFile
       captured: same BOM, same codepage, same newline style, same presence of a trailing newline.
       Set-Content -Encoding UTF8 always writes a BOM and WriteAllLines always joins with CRLF, so
       either one leaves a file-wide byte diff in a package whose only intended diffs are the ones
       the patch made on purpose.

       -State is optional. Without it the file is sniffed again from disk, which still preserves
       everything, because the patchers hold the lines in memory and never touch the file until
       this call. Pass it explicitly when the file has already been rewritten once (a rollback).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][array]$Lines,
        $State
    )
    if (-not $State) { $State = Get-InfTextFile -Path $Path }

    $nl = [string]$State.NewLine
    if (-not $nl) { $nl = "`r`n" }

    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($i -gt 0) { [void]$sb.Append($nl) }
        [void]$sb.Append([string]$Lines[$i])
    }
    if ($State.EndsWithNewline -and $Lines.Count -gt 0) { [void]$sb.Append($nl) }

    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $State.Encoding)
}

function Write-InfText {
    <#
       Same fidelity as Write-InfLines, for the callers that edit a whole document with regex
       instead of line by line (setup.cfg and the .nvi install manifest). Newlines INSIDE the text
       are whatever the caller's replacement inserted, so a caller that inserts a line has to join
       it with $State.NewLine rather than with a hard-coded "`r`n".
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)]$State
    )
    [System.IO.File]::WriteAllText($Path, $Text, $State.Encoding)
}
