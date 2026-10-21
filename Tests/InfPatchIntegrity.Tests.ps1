# Integration tests for the patch pipeline, run against a synthetic Display.Driver package that is
# small but structurally faithful to a real one:
#   * two [NVIDIA_Devices...] blocks - the whitelist patcher has to write into EVERY one of them,
#   * two [nv_miscBase_addreg__NN] sections whose bodies end in a comment line and a blank line,
#   * [Strings] last, ending in blank lines.
# Those tails exist on purpose: every insertion in this pipeline goes through Get-InfSectionIndex,
# whose whole job is to land the new line with the section body rather than in the blank gap before
# the next header, so a fixture without tails would not test the thing that broke between releases.
#
# The gate runs before the patch (it must refuse) and after it (it must pass), which is what makes
# this end-to-end rather than four unit tests that individually miss the wiring between them.
#
# Pester 3.4.0 syntax (the version shipped with PowerShell 5.1, so the same file runs on 5.1 and 7).
#
# Run:  Invoke-Pester Tests\InfPatchIntegrity.Tests.ps1

$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:ScriptsDir = Join-Path $RepoRoot 'Scripts'
. (Join-Path $script:ScriptsDir 'PatchToolDiscovery.ps1')

# The fixture is data, not a here-string, so its content is not subject to any quoting rules.
$script:FixtureInf = @(
'[Version]'
'Signature = "$WINDOWS NT$"'
'Class = Display'
'ClassGuid = {4d36e968-e325-11ce-bfc1-08002be10318}'
'Provider = %NVIDIA%'
'CatalogFile = nv_dispi.cat'
'DriverVer = 10/01/2026,617.42.0.0'
''
'[Manufacturer]'
'%NVIDIA% = NVIDIA, NTamd64.10'
''
'[NVIDIA_Devices.NTamd64.10]'
'%NVIDIA_DEV.2704% = Section001, PCI\VEN_10DE&DEV_2704'
'%NVIDIA_DEV.2705% = Section001, PCI\VEN_10DE&DEV_2705&SUBSYS_123410DE'
''
'[NVIDIA_Devices.NTamd64.10.NTamd64]'
'%NVIDIA_DEV.2704% = Section001, PCI\VEN_10DE&DEV_2704'
''
'[Section001]'
'CopyFiles = Section001.CopyFiles'
'AddReg = nv_miscBase_addreg__01'
''
'[nv_miscBase_addreg__01]'
'HKR,,TestValue,0x00010001,1'
'; keep this comment at the end of the section'
''
'[nv_miscBase_addreg__02]'
'HKR,,OtherValue,%REG_DWORD%,0'
''
'[Strings]'
'NVIDIA = "NVIDIA Corporation"'
'REG_DWORD = 0x00010001'
'NVIDIA_DEV.2704 = "NVIDIA Fixture GPU A"'
'NVIDIA_DEV.2705 = "NVIDIA Fixture GPU B"'
''
''
)

# The GPU this fixture unlocks appears nowhere in the fixture, so the patcher has to build the whole
# section family from the captured template instead of reusing a section it found in the file.
$script:FixtureWhitelist = @(
'{'
'  "nv_dispi.inf": ['
'    {'
'      "dev": "2E46",'
'      "subsys": "14581558",'
'      "key": "NVIDIA_DEV.2E46",'
'      "description": "NVIDIA GeForce RTX 4060 Laptop GPU",'
'      "template_section_family": {'
'        "_base": ['
'          "AddReg = nv_miscBase_addreg__01",'
'          "FeatureScore = CF"'
'        ]'
'      }'
'    }'
'  ]'
'}'
)

$script:MatchLine = '%NVIDIA_DEV.2E46% = SectionExtraGPU2E46_1, PCI\VEN_10DE&DEV_2E46&SUBSYS_14581558'
$script:StringsLine = 'NVIDIA_DEV.2E46 = "NVIDIA GeForce RTX 4060 Laptop GPU"'

function New-ScratchDir {
    param([string]$Hint = 'integrity')
    $root = Join-Path ([System.IO.Path]::GetTempPath()) 'chameleon-patcher-tests'
    $dir = Join-Path $root ($Hint + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Remove-ScratchDir {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
}

# Writes a stock-looking package, BOM-less UTF-8 like NVIDIA's own INFs, and returns its paths.
# -SplitDeviceLine reproduces an entry continued with a trailing backslash, which every per-line
# matcher in this toolkit reads as an unrelated fragment - see the last Describe.
function New-FixturePackage {
    param([switch]$SplitDeviceLine, [string]$Hint = 'integrity')
    $dir = New-ScratchDir -Hint $Hint
    $driver = Join-Path $dir 'Display.Driver'
    New-Item -ItemType Directory -Path $driver -Force | Out-Null
    $broken = New-Object System.Collections.Generic.List[string]
    foreach ($l in $script:FixtureInf) {
        if ($SplitDeviceLine -and $l -eq '%NVIDIA_DEV.2704% = Section001, PCI\VEN_10DE&DEV_2704') {
            $broken.Add('%NVIDIA_DEV.2704% = Section001, PCI\VEN_10DE&DEV_2704&SUBSYS_14581558, \')
            $broken.Add('    DEV_2704')
        }
        else { $broken.Add($l) }
    }
    $inf = Join-Path $driver 'nv_dispi.inf'
    [System.IO.File]::WriteAllLines($inf, [string[]]$broken.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    $wl = Join-Path $dir 'whitelist.json'
    [System.IO.File]::WriteAllLines($wl, [string[]]$script:FixtureWhitelist, (New-Object System.Text.UTF8Encoding($false)))
    return [PSCustomObject]@{ Root = $dir; Driver = $driver; Inf = $inf; Whitelist = $wl }
}

# Header-index ranges for the sections under test, using the toolkit's own header pattern so the
# test cannot disagree with the code about where a section ends. End is exclusive.
function Get-SectionRanges {
    param([string[]]$Lines, [string]$HeaderRegex)
    $headers = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($script:InfSectionHeaderRx.IsMatch($Lines[$i])) { $headers.Add($i) }
    }
    $ranges = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $HeaderRegex) {
            $end = $Lines.Count
            foreach ($h in $headers) { if ($h -gt $i) { $end = $h; break } }
            $ranges += [PSCustomObject]@{ Start = $i; End = $end }
        }
    }
    return $ranges
}

function Invoke-Gate {
    # One verification-gate run, returning the exception message (or $null) plus the Write-Host
    # report text, which is where the findings are actually listed.
    param([string]$Driver, [string]$Whitelist, [switch]$ReportOnly)
    $collected = New-Object System.Collections.Generic.List[string]
    $threw = $null
    $scriptPath = Join-Path $script:ScriptsDir 'Test-DriverPatch.ps1'
    # Collected line by line rather than assigned from the whole pipeline: the gate throws at the end
    # of a failed run, and an assignment interrupted by that throw loses the findings the caller,
    # with -ReportOnly, still wants to read.
    try {
        if ($ReportOnly) {
            & $scriptPath -DisplayDriverPath $Driver -WhitelistPath $Whitelist -ReportOnly 6>&1 |
                ForEach-Object { $collected.Add([string]$_) }
        }
        else {
            & $scriptPath -DisplayDriverPath $Driver -WhitelistPath $Whitelist 6>&1 |
                ForEach-Object { $collected.Add([string]$_) }
        }
    }
    catch { $threw = $_.Exception.Message }
    $text = $collected -join [Environment]::NewLine
    return [PSCustomObject]@{ Threw = $threw; Text = $text }
}

Describe 'Verification gate against an unpatched package' {
    $fx = New-FixturePackage -Hint 'gate-before'
    try {
        It 'names both real problems: the missing entry and the missing RM override' {
            $run = Invoke-Gate -Driver $fx.Driver -Whitelist $fx.Whitelist -ReportOnly
            $run.Threw | Should BeNullOrEmpty
            $run.Text | Should Match 'verification FAILED'
            $run.Text | Should Match 'DEV_2E46&SUBSYS_14581558'
            $run.Text | Should Match 'missing RM1457588'
        }
        It 'throws rather than letting an unpatched package reach the signing step' {
            $run = Invoke-Gate -Driver $fx.Driver -Whitelist $fx.Whitelist
            $run.Threw | Should Not BeNullOrEmpty
            $run.Threw | Should Match 'NOT correctly patched'
        }
    }
    finally { Remove-ScratchDir -Path $fx.Root }
}

Describe 'Whitelist patcher on the fixture package' {
    $fx = New-FixturePackage -Hint 'whitelist'
    try {
        & (Join-Path $script:ScriptsDir 'Add-ExtraGpuSupport.ps1') -DisplayDriverPath $fx.Driver -WhitelistPath $fx.Whitelist | Out-Null

        It 'adds the entry to every [NVIDIA_Devices...] block, not just the first one' {
            $lines = [System.IO.File]::ReadAllLines($fx.Inf)
            $blocks = @(Get-SectionRanges -Lines $lines -HeaderRegex '^\[NVIDIA_Devices')
            $blocks.Count | Should Be 2
            foreach ($b in $blocks) {
                $hits = @($lines[($b.Start + 1)..($b.End - 1)] | Where-Object { $_ -eq $script:MatchLine })
                $hits.Count | Should Be 1
            }
        }

        It 'splices the template family with its body intact' {
            $lines = [System.IO.File]::ReadAllLines($fx.Inf)
            $new = @(Get-SectionRanges -Lines $lines -HeaderRegex '^\[SectionExtraGPU2E46_1\]$')
            $new.Count | Should Be 1
            $body = $lines[($new[0].Start + 1)..($new[0].End - 1)]
            (@($body | Where-Object { $_ -eq 'AddReg = nv_miscBase_addreg__01' }).Count) | Should Be 1
            (@($body | Where-Object { $_ -eq 'FeatureScore = CF' }).Count) | Should Be 1
        }

        It 'defines the %token% in [Strings] with the body, above the blank tail' {
            $lines = [System.IO.File]::ReadAllLines($fx.Inf)
            $strings = @(Get-SectionRanges -Lines $lines -HeaderRegex '^\[Strings\]$')
            $strings.Count | Should Be 1
            $added = [array]::IndexOf($lines, $script:StringsLine)
            $added | Should BeGreaterThan $strings[0].Start
            $added | Should BeLessThan $strings[0].End
            # An insert at the section EndIndex would leave the definition below the blank lines, and
            # the line above it would be blank instead of the last real definition.
            $lines[$added - 1] | Should Be 'NVIDIA_DEV.2705 = "NVIDIA Fixture GPU B"'
            $tail = @($lines[($added + 1)..($strings[0].End - 1)] | Where-Object { $_.Trim() -ne '' })
            $tail.Count | Should Be 0
        }

        It 'leaves the gate failing only on the RM override, which is not its job' {
            $run = Invoke-Gate -Driver $fx.Driver -Whitelist $fx.Whitelist -ReportOnly
            $run.Threw | Should BeNullOrEmpty
            $run.Text | Should Match 'missing RM1457588'
            $run.Text | Should Not Match 'not present: DEV_2E46'
            # Without -ReportOnly the same findings stop the pipeline dead: a whitelist splice with no
            # RM override is not a shippable package, and this is the assertion that says so.
            $strict = Invoke-Gate -Driver $fx.Driver -Whitelist $fx.Whitelist
            $strict.Threw | Should Not BeNullOrEmpty
        }
    }
    finally { Remove-ScratchDir -Path $fx.Root }
}

Describe 'RM override and the full pipeline on the fixture package' {
    $fx = New-FixturePackage -Hint 'full'
    try {
        & (Join-Path $script:ScriptsDir 'Add-ExtraGpuSupport.ps1') -DisplayDriverPath $fx.Driver -WhitelistPath $fx.Whitelist | Out-Null
        & (Join-Path $script:ScriptsDir 'Add-RmCapabilityOverride.ps1') -DisplayDriverPath $fx.Driver | Out-Null

        It 'adds the override to every nv_miscBase_addreg section exactly once' {
            $lines = [System.IO.File]::ReadAllLines($fx.Inf)
            $misc = @(Get-SectionRanges -Lines $lines -HeaderRegex '^\[nv_miscBase_addreg__\d+\]$')
            $misc.Count | Should Be 2
            foreach ($m in $misc) {
                $hits = @($lines[($m.Start + 1)..($m.End - 1)] | Where-Object { $_ -match 'RM1457588' })
                $hits.Count | Should Be 1
            }
        }

        It 'puts the override with the section body, before the trailing comment' {
            $lines = [System.IO.File]::ReadAllLines($fx.Inf)
            $misc = @(Get-SectionRanges -Lines $lines -HeaderRegex '^\[nv_miscBase_addreg__01\]$')
            $rm = [array]::IndexOf($lines, 'HKR,,RM1457588,%REG_DWORD%,1')
            $rm | Should BeGreaterThan $misc[0].Start
            $rm | Should BeLessThan $misc[0].End
            $lines[$rm - 1] | Should Be 'HKR,,TestValue,0x00010001,1'
            $lines[$rm + 1] | Should Be '; keep this comment at the end of the section'
        }

        It 'certifies the fully patched package' {
            $run = Invoke-Gate -Driver $fx.Driver -Whitelist $fx.Whitelist
            $run.Threw | Should BeNullOrEmpty
            $run.Text | Should Match 'PASSED'
            $run.Text | Should Not Match 'problem'
        }

        It 'is idempotent - a second pass changes nothing' {
            $before = [System.IO.File]::ReadAllText($fx.Inf)
            & (Join-Path $script:ScriptsDir 'Add-ExtraGpuSupport.ps1') -DisplayDriverPath $fx.Driver -WhitelistPath $fx.Whitelist | Out-Null
            & (Join-Path $script:ScriptsDir 'Add-RmCapabilityOverride.ps1') -DisplayDriverPath $fx.Driver | Out-Null
            $after = [System.IO.File]::ReadAllText($fx.Inf)
            $after | Should Be $before
        }

        It 'keeps the INF BOM-less UTF-8 with CRLF line endings' {
            $bytes = [System.IO.File]::ReadAllBytes($fx.Inf)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            ($text -split "`r`n").Count | Should BeGreaterThan 1
            # A lone LF not preceded by CR would mean something rewrote the file with Unix endings.
            $lone = @([regex]::Matches($text, '(?<!\r)\n'))
            $lone.Count | Should Be 0
        }
    }
    finally { Remove-ScratchDir -Path $fx.Root }
}

Describe 'Package whose device entry is split across two physical lines' {
    $fx = New-FixturePackage -Hint 'continued' -SplitDeviceLine
    try {
        It 'warns that it could only read one physical line at a time' {
            $gateWarnings = @()
            & (Join-Path $script:ScriptsDir 'Test-DriverPatch.ps1') -DisplayDriverPath $fx.Driver -WhitelistPath $fx.Whitelist -ReportOnly -WarningVariable gateWarnings -WarningAction SilentlyContinue | Out-Null
            $joined = ($gateWarnings -join ' | ')
            $joined | Should Match 'continued line'
            $joined | Should Match 'nv_dispi.inf'
        }
    }
    finally { Remove-ScratchDir -Path $fx.Root }
}
