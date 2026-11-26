# This machine's NVIDIA GPUs, whitelist.json entries, and the lookup that maps a whitelist
# INF name onto the file a driver release actually ships.
#
# Part of the shared helper library. Do not dot-source this file on its own: load
# Scripts\PatchToolDiscovery.ps1, which loads every part in a fixed order.

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

    if (-not (Test-Path -LiteralPath $WhitelistPath)) { throw "whitelist.json not found: $WhitelistPath" }
    $whitelist = Get-Content -LiteralPath $WhitelistPath -Raw | ConvertFrom-Json

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
        [Parameter(Mandatory = $true)][string]$InfName,
        # Return every widened match instead of refusing an ambiguous one. Only for callers that
        # ask "keep anything named like this" (-KeepInf), never for the patchers or the gate.
        [switch]$AllowMany
    )

    $exact = Join-Path $DisplayDriverPath $InfName
    if (Test-Path -LiteralPath $exact) {
        return @([PSCustomObject]@{ Path = (Resolve-Path -LiteralPath $exact).Path; Name = $InfName; Exact = $true })
    }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($InfName)

    # Tier 2, then tier 3. Not $matches - that is an automatic variable populated by -match.
    $globs = @($stem)
    if ($stem.Length -ge 5) { $globs += $stem.Substring(0, $stem.Length - 1) }

    foreach ($g in $globs) {
        $hits = @(Get-ChildItem -LiteralPath $DisplayDriverPath -Filter ($g + '*.inf') -File -ErrorAction SilentlyContinue |
                  Sort-Object Name)
        if ($hits.Count -eq 0) { continue }
        # A widened glob that lands on more than one file is a guess between INFs, and every caller
        # would patch, check or keep ALL of them - including an OEM INF that merely shares the stem.
        # Refuse instead of guessing; -KeepInf / an explicit fix to whitelist.json resolves it.
        if ($hits.Count -gt 1 -and $AllowMany) {
            return @($hits | ForEach-Object { [PSCustomObject]@{ Path = $_.FullName; Name = $_.Name; Exact = $false } })
        }
        if ($hits.Count -gt 1) {
            throw ("This release has no $InfName, and '$g*.inf' matches several INFs ($(($hits | ForEach-Object { $_.Name }) -join ', ')). " +
                   "Refusing to guess which one stands in for it - rename the key in whitelist.json to this release's file name.")
        }
        return @([PSCustomObject]@{ Path = $hits[0].FullName; Name = $hits[0].Name; Exact = $false })
    }
    return @()
}
