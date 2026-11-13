<#
.SYNOPSIS
  Makes PhysX and the NVIDIA App offered-and-tickable for the GPUs this toolkit unlocks, instead
  of being silently dropped by the installer.

.DESCRIPTION
  Whether setup.exe offers "PhysX System Software" and the NVIDIA App is not a fixed property of
  the installer. Both are gated by constraints in setup.cfg that read per-device feature flags out
  of the driver INF:

    Display.PhysX  <property name="Display.Driver!Feature.Physx" level="silent" .../>
    Display.NvApp  a CheckIfInfSupported / CheckIfGPUIsSupported constraint set

  Those flags are the INF's own `NVSupportPhysx = 1` and `NVSupportGFExperienceUDA = 1` lines,
  written per device install section. NVIDIA varies them by GPU family - in stock 616.64's main
  INF only 55 of 105 install sections carry the PhysX flag and only 28 carry the App flag - which
  is exactly why the installer offers these components on some hardware and not others. Because
  the constraints are `level="silent"`, a GPU without the flag makes the component vanish with no
  message at all.

  This script makes the flags consistent for the devices in whitelist.json. It resolves each
  whitelisted device line to the install Section it points at, and ensures that Section carries
  both flags.

  SHARED SECTIONS ARE CLONED, NOT EDITED. Most whitelisted devices get a freshly spliced
  SectionExtraGPU* section, and the captured template already contains both flags. A few entries
  instead REUSE an existing stock section, because Add-ExtraGpuSupport.ps1 prefers a section already
  valid for that chip. When such a section is also used by device lines that are not whitelist
  entries, it is copied as <section>_ChameleonOpt (with its companions) and only the whitelisted
  lines are pointed at the copy, so the flags never reach hardware NVIDIA did not flag.

  It does NOT remove the setup.cfg constraints. Deleting those would force the components on for
  every GPU including ones NVIDIA flagged as unsupported, which is a much broader change than
  making the unlocked GPUs behave like first-class ones.

.PARAMETER PackageRoot
  Root of the patched package. Must contain setup.cfg and Display.Driver.

.PARAMETER WhitelistPath
  Defaults to whitelist.json next to this script.

.PARAMETER Flags
  The INF feature flags to ensure. Defaults to the PhysX and NVIDIA App ones.

.PARAMETER PrunedInf
  Whitelist INF names the prune step removed on purpose; their absence is a note, not a warning.

.PARAMETER SkipInstallerSelectable
  Leave setup.cfg alone. The INF flags are still applied, but the NVIDIA App stays locked on
  rather than becoming a row the user can untick.

.EXAMPLE
  .\Enable-OptionalComponents.ps1 -PackageRoot "610.88_Patched"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$WhitelistPath,

    [string[]]$Flags = @('NVSupportPhysx', 'NVSupportGFExperienceUDA'),

    [switch]$SkipInstallerSelectable,

    [string[]]$PrunedInf = @()
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

if (-not $WhitelistPath) { $WhitelistPath = Join-Path $PSScriptRoot "whitelist.json" }
if (-not (Test-Path $WhitelistPath)) { throw "whitelist.json not found: $WhitelistPath" }

$displayDriver = Join-Path $PackageRoot "Display.Driver"
$setupCfg      = Join-Path $PackageRoot "setup.cfg"
if (-not (Test-Path $displayDriver)) { throw "Display.Driver not found under $PackageRoot" }

$whitelist = Get-Content $WhitelistPath -Raw | ConvertFrom-Json

# --- 1. INF feature flags -----------------------------------------------------------------------
$totalAdded = 0
$sectionsTouched = 0
$infsSeen = 0

foreach ($key in $whitelist.PSObject.Properties.Name) {
    $entries = $whitelist.$key
    $resolved = @(Resolve-WhitelistInf -DisplayDriverPath $displayDriver -InfName $key)
    if ($resolved.Count -eq 0) {
        if ($PrunedInf -contains $key) {
            Write-Host "$key was pruned from this package - its $($entries.Count) entries do not apply." -ForegroundColor DarkGray
        }
        else {
            Write-Warning "Neither $key nor a same-stem variant is present - skipping its $($entries.Count) entries."
        }
        continue
    }

    foreach ($r in $resolved) {
        $infsSeen++
        # Read through the shared reader so the writer below can put the file back with the encoding
        # and line endings it already had: Get-Content -Encoding UTF8 turns a legacy-codepage INF into
        # replacement characters that then get written back as real bytes.
        $state = Get-InfTextFile -Path $r.Path
        $lines = [System.Collections.Generic.List[string]](@($state.Lines))

        # Which lines do the whitelisted devices own? Every line for the entry counts, not just the
        # first: each [NVIDIA_Devices...] block has its own line, and they may point at different
        # sections. Matching is the patcher's own rule (Mode Entry).
        $ownLines = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($e in $entries) {
            $from = 0
            while ($true) {
                $hit = Find-InfDeviceLine -Lines $lines -Start $from -Dev $e.dev -Subsys $e.subsys -Mode Entry
                if (-not $hit) { break }
                [void]$ownLines.Add($hit.Index)
                $from = $hit.Index + 1
            }
        }

        # A stock section that the unlocked GPUs share with devices NVIDIA itself lists gets cloned
        # before it is flagged, and only the whitelisted lines are pointed at the clone. Editing it
        # in place switched PhysX / the NVIDIA App on for every GPU sharing it, which is the broad
        # change this script exists to avoid.
        $cloned = 0
        $bodies = Get-InfSectionBody -Lines $lines
        $sharedBy = @{}
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($ownLines.Contains($i)) { continue }
            $p = Get-InfDeviceLine -Line $lines[$i]
            if ($p) { $sharedBy[$p.Section] = 1 + [int]$sharedBy[$p.Section] }
        }
        $cloneOf = @{}
        foreach ($i in @($ownLines)) {
            $p = Get-InfDeviceLine -Line $lines[$i]
            $s = $p.Section
            if (-not $sharedBy.ContainsKey($s) -or -not $bodies.ContainsKey($s)) { continue }
            if (-not $cloneOf.ContainsKey($s)) {
                $clone = $s + '_ChameleonOpt'
                $n = 1
                while ($bodies.ContainsKey($clone)) { $n++; $clone = $s + '_ChameleonOpt' + $n }
                $cloneOf[$s] = $clone
                [void]$lines.Add('')
                foreach ($name in @($bodies.Keys | Where-Object { $_ -eq $s -or $_.StartsWith($s + '.', [StringComparison]::OrdinalIgnoreCase) })) {
                    $lines.Add('[' + $clone + $name.Substring($s.Length) + ']')
                    foreach ($l in $bodies[$name]) { $lines.Add($l) }
                    $lines.Add('')
                }
                Write-Host ("  [$s] is shared with $($sharedBy[$s]) other device line(s) - cloned as [$clone] for the whitelisted GPUs only")
                $cloned++
            }
            $lines[$i] = [regex]::Replace($lines[$i], '(=\s*)' + [regex]::Escape($s) + '(\s*,)', '${1}' + $cloneOf[$s] + '${2}', 1)
        }

        # Index section bounds (after any clone), through the toolkit's shared header pattern.
        $bounds = @{}
        $current = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $h = $script:InfSectionHeaderRx.Match($lines[$i])
            if ($h.Success) {
                if ($current) { $bounds[$current].End = $i }
                $current = $h.Groups[1].Value.Trim()
                if (-not $bounds.ContainsKey($current)) { $bounds[$current] = [PSCustomObject]@{ Start = $i; End = $lines.Count } }
            }
        }
        if ($current) { $bounds[$current].End = $lines.Count }

        $targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($i in $ownLines) { [void]$targets.Add((Get-InfDeviceLine -Line $lines[$i]).Section) }

        if ($targets.Count -eq 0) {
            Write-Warning "$($r.Name): none of the whitelisted devices are present. Run Add-ExtraGpuSupport.ps1 first."
            continue
        }

        Write-Host "`n=== $($r.Name) ===" -ForegroundColor Cyan
        Write-Host ("  $($targets.Count) install section(s) referenced by whitelisted devices")

        # Insert bottom-up so earlier indices stay valid.
        $ordered = @($targets | Where-Object { $bounds.ContainsKey($_) } |
                     Sort-Object -Property @{Expression = { $bounds[$_].Start }} -Descending)
        foreach ($t in @($targets | Where-Object { -not $bounds.ContainsKey($_) })) {
            Write-Warning "$($r.Name): device line points at [$t] but no such section exists - skipping."
        }

        $addedHere = 0
        foreach ($t in $ordered) {
            $start = $bounds[$t].Start
            $end   = $bounds[$t].End

            $missing = @()
            foreach ($f in $Flags) {
                $have = $false
                for ($j = $start + 1; $j -lt $end; $j++) {
                    $body = ($lines[$j] -split ';', 2)[0]
                    if ($body -match ('^\s*' + [regex]::Escape($f) + '\s*=\s*(\S*)')) {
                        $have = $true
                        # Present but switched off (= 0) is the same as absent for the installer.
                        if ($Matches[1] -ne '1') { $lines[$j] = "$f = 1"; $missing += "$f (was $($Matches[1]))" }
                        break
                    }
                }
                if (-not $have) { $missing += $f }
            }
            if ($missing.Count -eq 0) { continue }

            # Inside the body, ahead of any trailing blank or comment lines - the shared rule.
            $insertAt = Get-InfSectionIndex -Lines $lines -HeaderIndex $start -EndIndex $end
            foreach ($f in @($missing | Where-Object { $_ -notmatch '\(was ' })) { $lines.Insert($insertAt, "$f = 1") }

            Write-Host ("  + [$t] gained " + ($missing -join ', '))
            $addedHere += $missing.Count
            $sectionsTouched++
        }

        if ($addedHere -gt 0 -or $cloned -gt 0) {
            if ($PSCmdlet.ShouldProcess($r.Path, "Write component feature flags")) {
                Write-InfLines -Path $r.Path -Lines $lines -State $state
            }
            $totalAdded += $addedHere
        }
        else {
            Write-Host "  all referenced sections already carry every flag - nothing to do" -ForegroundColor DarkGray
        }
    }
}

if ($infsSeen -eq 0) {
    throw "None of the whitelist's INFs (or same-stem variants) exist under `"$displayDriver`" - check the path, or run Add-ExtraGpuSupport.ps1 first."
}

Write-Host ""
Write-Host "Added $totalAdded flag line(s) across $sectionsTouched section(s)." -ForegroundColor Green

# --- 2. Let the user untick the NVIDIA App ------------------------------------------------------
# Display.NvApp ships disposition="default" userSelectable="false": pre-ticked and locked. PhysX
# is already disposition="default" with no userSelectable restriction, so it needs nothing here -
# once its feature flag is set it appears pre-ticked and can be unticked like any other row.
if (-not $SkipInstallerSelectable) {
    if (-not (Test-Path $setupCfg)) {
        Write-Warning "setup.cfg not found under $PackageRoot - skipping the NVIDIA App selectability change."
    }
    else {
        # Read through the shared reader, and keep the original bytes for the rollback below. setup.cfg
        # is written by NVIDIA's own tooling, and a writer that always drops the BOM or always emits
        # UTF-8 edits bytes no patch intended to touch - which is exactly what the catalog then hashes.
        $cfgState = Get-InfTextFile -Path $setupCfg
        $cfg = $cfgState.Text
        $cfgOriginalBytes = [System.IO.File]::ReadAllBytes($setupCfg)
        $rx = [regex]'(?<open><sub-package\b[^>]*?\bname\s*=\s*"Display\.NvApp"[^>]*?>)'
        $m = $rx.Match($cfg)
        if (-not $m.Success) {
            Write-Warning "Could not find the Display.NvApp sub-package in setup.cfg - leaving it alone. The INF flags above still apply."
        }
        else {
            $open = $m.Groups['open'].Value
            if ($open -match 'userSelectable\s*=\s*"true"') {
                Write-Host "NVIDIA App is already user-selectable in setup.cfg - nothing to do." -ForegroundColor DarkGray
            }
            else {
                if ($open -match 'userSelectable\s*=\s*"[^"]*"') {
                    $newOpen = [regex]::Replace($open, 'userSelectable\s*=\s*"[^"]*"', 'userSelectable="true"')
                }
                else {
                    # No such attribute: add it just before the closing bracket.
                    $newOpen = $open -replace '\s*>$', ' userSelectable="true">'
                }
                if ($PSCmdlet.ShouldProcess($setupCfg, "Make Display.NvApp user-selectable")) {
                    Write-InfText -Path $setupCfg -Text $cfg.Remove($m.Index, $open.Length).Insert($m.Index, $newOpen) -State $cfgState

                    # Verify structurally rather than trusting the replace, and put the file back if the
                    # edit did not come out as intended - the rollback writes the bytes it read, so a
                    # file that was untouched by a successful patch is byte-for-byte what it was.
                    try {
                        try { $xml = [xml]((Get-InfTextFile -Path $setupCfg).Text) }
                        catch { throw "setup.cfg is no longer valid XML after the edit. $_" }
                        $node = @($xml.GetElementsByTagName('sub-package')) | Where-Object { $_.name -eq 'Display.NvApp' } | Select-Object -First 1
                        if (-not $node) { throw "setup.cfg parses but Display.NvApp is gone." }
                        if ($node.userSelectable -ne 'true') { throw "Display.NvApp userSelectable is '$($node.userSelectable)', expected 'true'." }
                    }
                    catch {
                        try {
                            [System.IO.File]::WriteAllBytes($setupCfg, $cfgOriginalBytes)
                            Write-Warning "setup.cfg restored to its previous contents."
                        }
                        catch { Write-Warning "COULD NOT restore setup.cfg - re-copy it from the source package." }
                        throw
                    }
                    Write-Host "NVIDIA App is now a row the user can untick (disposition stays 'default', so it starts ticked)." -ForegroundColor Green
                }
            }
        }
    }
}

Write-Host ""
Write-Host "PhysX and the NVIDIA App will now be offered for the whitelisted GPUs, both ticked by" -ForegroundColor Green
Write-Host "default and both possible to untick under Custom Installation Options." -ForegroundColor Green
Write-Host "Not verified through a real install - confirm on your own hardware." -ForegroundColor Yellow
