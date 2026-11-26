# INF text: byte-faithful reading and writing, section and device-line parsing, the
# template/donor merge and the RM override directive.
#
# Part of the shared helper library. Do not dot-source this file on its own: load
# Scripts\PatchToolDiscovery.ps1, which loads every part in a fixed order.

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

    Write-TextFileAtomic -Path $Path -Text $sb.ToString() -Encoding $State.Encoding
}

function Write-TextFileAtomic {
    <#
       Write a whole file so that a reader - or a crash - never sees it half-written: the text goes
       to a temporary file in the same folder, which then replaces the original in one rename.
       WriteAllText straight onto an INF truncates it first, and a run killed at that moment left a
       cut-off INF that the next step happily patched further.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    $tmp = $full + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($tmp, $Text, $Encoding)
        # [NullString]::Value, not $null: PowerShell would pass $null to a string parameter as "",
        # which File.Replace rejects as a backup path.
        if ([System.IO.File]::Exists($full)) { [System.IO.File]::Replace($tmp, $full, [NullString]::Value) }
        else { [System.IO.File]::Move($tmp, $full) }
    }
    finally {
        if ([System.IO.File]::Exists($tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
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
    Write-TextFileAtomic -Path $Path -Text $Text -Encoding $State.Encoding
}

# --- INF section model for the template/donor merge ------------------------------------------------
function Get-InfSectionBody {
    <#
       Section name (case-insensitive) -> the section's non-empty lines with comments stripped and
       whitespace trimmed. Duplicate headers are merged, as Windows merges them.
    #>
    param([Parameter(Mandatory = $true)]$Lines)
    $map = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' ([StringComparer]::OrdinalIgnoreCase)
    $cur = $null
    foreach ($raw in $Lines) {
        $h = $script:InfSectionHeaderRx.Match([string]$raw)
        if ($h.Success) {
            $cur = $h.Groups[1].Value.Trim()
            if (-not $map.ContainsKey($cur)) { $map[$cur] = New-Object System.Collections.Generic.List[string] }
            continue
        }
        if (-not $cur) { continue }
        $t = (([string]$raw) -split ';', 2)[0].Trim()
        if ($t) { $map[$cur].Add($t) }
    }
    return $map
}

function Get-InfDirectiveKey {
    <#
       What a directive line is FOR, independent of NVIDIA's per-release section numbering:
       "CopyFiles = nv_ngx_builtins_copyfiles__01" -> "copyfiles|nv_ngx_builtins_copyfiles". Two lines
       with the same key do the same job for different chip families; a key one side lacks is a job
       that side does not do at all. Returns $null for a line that is not a section-referencing directive.
    #>
    param([string]$Line)
    if ($Line -notmatch '^(AddReg|DelReg|CopyFiles|DelFiles|RenFiles|AddService|DelService|Include|Needs|CopyINF|AddProperty|AddSoftware)\s*=\s*(.+)$') { return $null }
    $d = $Matches[1].ToLowerInvariant()
    $first = (($Matches[2] -split ',')[0]).Trim()
    return $d + '|' + ($first -replace '__\d+$', '').ToLowerInvariant()
}

function Merge-InfTemplateWithDonor {
    <#
       Bring a section family captured in whitelist.json (from an older driver) up to date with the
       driver it is being spliced into.

       The captured bodies name sections by NVIDIA's numbering at capture time and, worse, only the
       jobs that existed then: a stock 621.24 install section copies nv_ngx_builtins_copyfiles__01,
       which the captured 595.79 body has never heard of, so a spliced device installed without those
       files. The donor is the stock install section of THIS INF whose lines are closest to the
       template (Jaccard over the trimmed lines, at least -MinSimilarity). Every section-referencing
       directive the donor carries for a job the template does not do is appended to the matching
       member of the family; a companion section (.Services, .HW, ...) the donor has and the template
       lacks is taken whole. Feature flags (NVSupport* = ...) are never taken from the donor - those
       are per-GPU decisions, and Enable-OptionalComponents.ps1 owns them.

       Returns @{ Family (ordered suffix -> string[]); Donor; Similarity; Added (string[]) }. With no
       donor close enough, the template is returned unchanged and Donor is $null.
    #>
    param(
        [Parameter(Mandatory = $true)]$TemplateFamily,
        [Parameter(Mandatory = $true)]$Sections,
        [string[]]$InstallSections = @(),
        [double]$MinSimilarity = 0.8
    )
    $family = [ordered]@{}
    if ($TemplateFamily -is [System.Collections.IDictionary]) {
        foreach ($k in $TemplateFamily.Keys) { $family[$k] = @($TemplateFamily[$k] | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
    }
    else {
        foreach ($p in $TemplateFamily.PSObject.Properties) { $family[$p.Name] = @($p.Value | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
    }
    $base = @($family['_base'])

    $donor = $null; $best = -1.0
    $baseSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($l in $base) { [void]$baseSet.Add($l) }
    foreach ($s in $InstallSections) {
        if (-not $Sections.ContainsKey($s)) { continue }
        $other = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($l in $Sections[$s]) { [void]$other.Add($l) }
        $inter = 0
        foreach ($l in $other) { if ($baseSet.Contains($l)) { $inter++ } }
        $union = $baseSet.Count + $other.Count - $inter
        $j = if ($union -gt 0) { $inter / $union } else { 0 }
        if ($j -gt $best) { $best = $j; $donor = $s }
    }
    $added = New-Object System.Collections.Generic.List[string]
    if (-not $donor -or $best -lt $MinSimilarity) {
        return [PSCustomObject]@{ Family = $family; Donor = $null; Similarity = [math]::Max($best, 0); Added = @() }
    }

    # Every member of the donor's family: the base section plus "<donor>.<suffix>" companions.
    $donorFamily = [ordered]@{ '_base' = @($Sections[$donor]) }
    foreach ($name in $Sections.Keys) {
        if ($name.StartsWith($donor + '.', [StringComparison]::OrdinalIgnoreCase)) {
            $donorFamily[$name.Substring($donor.Length + 1)] = @($Sections[$name])
        }
    }
    foreach ($suffix in @($donorFamily.Keys)) {
        $dBody = @($donorFamily[$suffix])
        $tKey = @($family.Keys | Where-Object { $_ -eq $suffix })
        if ($tKey.Count -eq 0) {
            $family[$suffix] = $dBody
            foreach ($l in $dBody) { $added.Add("[.$suffix] $l") }
            continue
        }
        $tBody = @($family[$tKey[0]])
        $have = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($l in $tBody) { $k = Get-InfDirectiveKey $l; if ($k) { [void]$have.Add($k) } }
        $extra = @()
        foreach ($l in $dBody) {
            $k = Get-InfDirectiveKey $l
            if ($k -and -not $have.Contains($k)) { $extra += $l; [void]$have.Add($k) }
        }
        if ($extra.Count) {
            $family[$tKey[0]] = @($tBody + $extra)
            $label = if ($suffix -eq '_base') { '' } else { "[.$suffix] " }
            foreach ($l in $extra) { $added.Add($label + $l) }
        }
    }
    return [PSCustomObject]@{ Family = $family; Donor = $donor; Similarity = $best; Added = @($added) }
}

function Test-InfRmOverrideLine {
    <#
       Does this INF line actually write the RM1457588 override - an HKR AddReg entry on the non-comment
       part of the line, rather than the bare text anywhere (a comment mentioning it used to count)?
    #>
    param([string]$Line)
    $body = (([string]$Line) -split ';', 2)[0]
    return ($body -match '^\s*HKR\s*,\s*,\s*RM1457588\s*,')
}
