# Tests for the parts of the toolkit that decide what is trusted, what is deleted and what a
# finished run looks like:
#   * tool lookup order (a user-writable 7z must not outrank an admin-installed one),
#   * boot state (Test Signing / Secure Boot) read without bcdedit's localized text,
#   * the default output folder, including the NVIDIA App staged-package exception,
#   * whole-package source verification (installer binaries outside Display.Driver),
#   * the -Json answers the GUI reads,
#   * the ".partial" work folder: a failed run must not leave the final output name behind,
#   * Remove-ForeignOemInfs.ps1, the one script that deletes files from a package.
#
# Pester 3.4.0 syntax, like the other suites. Nothing here touches a certificate store, a trust
# store or the network; the pipeline runs below stop long before signing.
#
# Run:  Invoke-Pester Tests\PipelineSafety.Tests.ps1

$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:ScriptsDir = Join-Path $RepoRoot 'Scripts'
. (Join-Path $script:ScriptsDir 'PatchToolDiscovery.ps1')

$script:PowerShellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:PipelinePs1 = Join-Path $script:ScriptsDir 'Invoke-DriverPatchPipeline.ps1'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function New-ScratchDir {
    param([string]$Hint = 'safety')
    $root = Join-Path ([System.IO.Path]::GetTempPath()) 'chameleon-patcher-tests'
    $dir = Join-Path $root ($Hint + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Remove-ScratchDir {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
}

# One pipeline query as the GUI makes it: a fresh powershell.exe, -Json, the answer being the last
# stdout line that starts with "{".
function Invoke-PipelineQuery {
    param([string[]]$Arguments)
    $out = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:PipelinePs1 @Arguments -Json 2>$null
    $line = @($out | Where-Object { ([string]$_).TrimStart().StartsWith('{') }) | Select-Object -Last 1
    if (-not $line) { return $null }
    return ($line | ConvertFrom-Json)
}

# A package root (setup.exe, setup.cfg, Display.Driver) with display INFs for the prune tests:
#   nv_dispi.inf  generic desktop INF, the one whitelist.json patches
#   oema.inf      an OEM INF for a device this "machine" does not have
#   oemb.inf      an OEM INF listing the machine's DEV under someone else's SUBSYS
# plus oema.cat (a companion that pruning must leave alone) and the .nvi manifest naming them all.
function New-PrunePackage {
    param([string]$Hint = 'prune', [string]$WhitelistInf = 'nv_dispi.inf')
    $dir = New-ScratchDir -Hint $Hint
    $dd = Join-Path $dir 'Display.Driver'
    New-Item -ItemType Directory -Path $dd -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'setup.exe'), 'stub', $script:Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $dir 'setup.cfg'), '<setup title="x" version="999.99"></setup>', $script:Utf8NoBom)

    $infs = @{
        'nv_dispi.inf' = '%NVIDIA_DEV.2704% = Section001, PCI\VEN_10DE&DEV_2704'
        'oema.inf'     = '%NVIDIA_DEV.1111% = Section001, PCI\VEN_10DE&DEV_1111&SUBSYS_AAAA1028'
        'oemb.inf'     = '%NVIDIA_DEV.2E46% = Section001, PCI\VEN_10DE&DEV_2E46&SUBSYS_99991043'
    }
    foreach ($name in $infs.Keys) {
        $lines = @(
            '[Version]', 'Signature = "$WINDOWS NT$"', 'CatalogFile = NV_DISP.CAT', '',
            '[Manufacturer]', '%NVIDIA% = NVIDIA, NTamd64.10', '',
            '[NVIDIA_Devices.NTamd64.10]', $infs[$name], '',
            '[Section001]', 'AddReg = nv_miscBase_addreg__01', '',
            '[Strings]', 'NVIDIA = "NVIDIA Corporation"', '')
        [System.IO.File]::WriteAllLines((Join-Path $dd $name), [string[]]$lines, $script:Utf8NoBom)
    }
    [System.IO.File]::WriteAllText((Join-Path $dd 'oema.cat'), 'companion', $script:Utf8NoBom)
    $nvi = @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<nvi name="Display.Driver" version="999.99">',
        '  <manifest>',
        '    <file name="nv_dispi.inf"/><file name="oema.inf"/>',
        '    <file name="oemb.inf" />',
        '    <file name="oema.cat"/>',
        '  </manifest>',
        '</nvi>')
    [System.IO.File]::WriteAllLines((Join-Path $dd 'DisplayDriver.nvi'), [string[]]$nvi, $script:Utf8NoBom)

    $wl = Join-Path $dir 'whitelist.json'
    $json = @(
        '{', ('  "' + $WhitelistInf + '": ['), '    {',
        '      "dev": "2E46",', '      "subsys": "14581558",', '      "key": "NVIDIA_DEV.2E46",',
        '      "description": "NVIDIA Fixture Laptop GPU",',
        '      "template_section_family": { "_base": [ "AddReg = nv_miscBase_addreg__01" ] }',
        '    }', '  ]', '}')
    [System.IO.File]::WriteAllLines($wl, [string[]]$json, $script:Utf8NoBom)
    return [PSCustomObject]@{ Root = $dir; Driver = $dd; Whitelist = $wl; Nvi = (Join-Path $dd 'DisplayDriver.nvi') }
}

function Invoke-Prune {
    param([string]$Root, [string]$Whitelist, [hashtable]$Extra = @{})
    & (Join-Path $script:ScriptsDir 'Remove-ForeignOemInfs.ps1') -PackageRoot $Root -WhitelistPath $Whitelist `
        -IgnoreLocalHardware @Extra 6>$null 3>$null | Out-Null
}

Describe '7z lookup order' {
    It 'tries the admin-installed copies under Program Files before the per-user WindowsApps alias' {
        $list = @(Get-SevenZipCandidatePaths)
        $alias = -1; $lastProgramFiles = -1
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($list[$i] -like '*\Microsoft\WindowsApps\7z.exe') { $alias = $i } else { $lastProgramFiles = $i }
        }
        $alias | Should Not Be -1
        $lastProgramFiles | Should Not Be -1
        ($alias -gt $lastProgramFiles) | Should Be $true
    }
    It 'lists both 7-Zip and NanaZip' {
        $list = @(Get-SevenZipCandidatePaths) -join '|'
        $list | Should Match '7-Zip\\7z\.exe'
        $list | Should Match 'NanaZip\\7z\.exe'
    }
}

Describe 'Boot state without bcdedit' {
    It 'reads Test Signing from the boot options token, in any display language' {
        Test-StartOptionsTestSigning -StartOptions ' NOEXECUTE=OPTIN  TESTSIGNING' | Should Be $true
        Test-StartOptionsTestSigning -StartOptions 'TESTSIGNING  NOEXECUTE=OPTIN' | Should Be $true
    }
    It 'does not read it from a neighbouring token or an empty value' {
        Test-StartOptionsTestSigning -StartOptions ' NOEXECUTE=OPTIN  FVEBOOT=2666496  NOVGA' | Should Be $false
        Test-StartOptionsTestSigning -StartOptions ' NOTESTSIGNINGHERE' | Should Be $false
        Test-StartOptionsTestSigning -StartOptions '' | Should Be $false
    }
    It 'answers on this machine without elevation' {
        $state = Get-BootSigningState
        ($state.TestSigning -is [bool]) | Should Be $true
    }
    It 'warns about Secure Boot and about Test Signing being off, and stays quiet when both are fine' {
        $both = @(Get-BootSigningAdvice -State ([PSCustomObject]@{ TestSigning = $false; SecureBoot = $true }))
        $both.Count | Should Be 2
        ($both -join ' ') | Should Match 'Secure Boot is ON'
        ($both -join ' ') | Should Match 'Test Signing mode is OFF'
        @(Get-BootSigningAdvice -State ([PSCustomObject]@{ TestSigning = $true; SecureBoot = $false })).Count | Should Be 0
    }
    It 'says nothing about a state it could not read' {
        @(Get-BootSigningAdvice -State ([PSCustomObject]@{ TestSigning = $null; SecureBoot = $null })).Count | Should Be 0
    }
}

Describe 'Get-DefaultOutputPath' {
    It 'puts the result beside a downloaded .exe' {
        Get-DefaultOutputPath -SourcePath 'D:\Drivers\621.40-desktop.exe' -IsExe | Should Be 'D:\Drivers\621.40-desktop_Patched'
    }
    It 'puts the result beside an ordinary unpacked folder, with the given suffix' {
        Get-DefaultOutputPath -SourcePath 'D:\Drivers\621.40' -Suffix '_Patched_A2000' -NvAppRoot 'C:\nvapp' |
            Should Be 'D:\Drivers\621.40_Patched_A2000'
    }
    It 'never writes into the folder NVIDIA App stages its downloads in' {
        $root = New-ScratchDir 'nvout'
        try {
            $staged = Join-Path $root 'staging'
            $pkg = Join-Path $staged '8f0c84c58e34d238dec75f86b3bce32c'
            New-Item -ItemType Directory -Path $pkg -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $pkg 'setup.cfg') -Value '<setup title="x" version="621.40">'
            $userDir = Join-Path $root 'Downloads'
            $out = Get-DefaultOutputPath -SourcePath $pkg -NvAppRoot $staged -UserOutputParent $userDir
            $out | Should Be (Join-Path $userDir 'NVIDIA-621.40-8f0c84c5_Patched')
        } finally { Remove-ScratchDir $root }
    }
    It 'still names the folder when the staged package declares no version' {
        $root = New-ScratchDir 'nvout'
        try {
            $staged = Join-Path $root 'staging'
            $pkg = Join-Path $staged 'abc'
            New-Item -ItemType Directory -Path $pkg -Force | Out-Null
            $out = Get-DefaultOutputPath -SourcePath $pkg -NvAppRoot ($staged + '\') -UserOutputParent 'X:\out'
            $out | Should Be 'X:\out\NVIDIA-abc_Patched'
        } finally { Remove-ScratchDir $root }
    }
}

Describe 'Test-DriverSource looks at the whole package' {
    It 'refuses a folder whose setup.exe is not signed by NVIDIA or Microsoft' {
        $dir = New-ScratchDir 'srcpkg'
        try {
            New-Item -ItemType Directory -Path (Join-Path $dir 'Display.Driver') | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Display.Driver\nv_dispi.inf') -Value '[Version]'
            Set-Content -LiteralPath (Join-Path $dir 'setup.exe') -Value 'not a signed installer'
            $r = Test-DriverSource -PackagePath $dir
            $r.Ok | Should Be $false
            ($r.Problems -join "`n") | Should Match 'setup\.exe is an installer file outside Display\.Driver'
        } finally { Remove-ScratchDir $dir }
    }
    It 'refuses a foreign binary in a component folder beside Display.Driver' {
        $dir = New-ScratchDir 'srcpkg'
        try {
            New-Item -ItemType Directory -Path (Join-Path $dir 'Display.Driver') | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $dir 'NVI2') | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Display.Driver\nv_dispi.inf') -Value '[Version]'
            Set-Content -LiteralPath (Join-Path $dir 'NVI2\NVI2.dll') -Value 'planted'
            ((Test-DriverSource -PackagePath $dir).Problems -join "`n") | Should Match 'NVI2\\NVI2\.dll is an installer file outside Display\.Driver'
        } finally { Remove-ScratchDir $dir }
    }
    It 'accepts a validly signed installer binary and says the manifests cannot be verified' {
        $dir = New-ScratchDir 'srcpkg'
        try {
            New-Item -ItemType Directory -Path (Join-Path $dir 'Display.Driver') | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Display.Driver\nv_dispi.inf') -Value '[Version]'
            Set-Content -LiteralPath (Join-Path $dir 'Display.Driver\DisplayDriver.nvi') -Value '<nvi/>'
            Set-Content -LiteralPath (Join-Path $dir 'setup.cfg') -Value '<setup/>'
            # A Microsoft-signed PE stands in for NVIDIA's setup.exe: what is under test is that a
            # valid NVIDIA/Microsoft signature passes this check, not who the signer is. Embedded
            # signatures survive a copy; catalog-signed system files would not, so pick one that is.
            $signed = Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('System')) -Filter *.exe -File |
                Where-Object { $_.Length -lt 2MB } |
                Where-Object { $s = Get-AuthenticodeSignature -LiteralPath $_.FullName; $s.Status -eq 'Valid' -and $s.SignatureType -eq 'Authenticode' -and $s.SignerCertificate.Subject -match 'O=Microsoft Corporation' } |
                Select-Object -First 1
            if (-not $signed) { Set-TestInconclusive 'No embedded-signed Microsoft .exe found in System32 to stand in for a signed installer.' }
            Copy-Item -LiteralPath $signed.FullName -Destination (Join-Path $dir 'setup.exe')
            $r = Test-DriverSource -PackagePath $dir
            ($r.Problems -join "`n") | Should Not Match 'installer file outside Display\.Driver'
            ($r.Notes -join "`n") | Should Match '1 installer binaries outside Display\.Driver'
            ($r.Notes -join "`n") | Should Match 'NOT verifiable: 2 installer manifest'
        } finally { Remove-ScratchDir $dir }
    }
}

Describe 'Pipeline queries with -Json' {
    It 'answers -CheckNvAppStaged with one JSON object carrying a verdict' {
        $a = Invoke-PipelineQuery -Arguments @('-CheckNvAppStaged')
        $a.query | Should Be 'nvAppStaged'
        (@('NVAPP_STAGED', 'NVAPP_NONE') -contains $a.verdict) | Should Be $true
    }
    It 'answers -CheckPatchTools for a folder source without asking for 7z' {
        $a = Invoke-PipelineQuery -Arguments @('-CheckPatchTools', '-SourcePackagePath', 'C:\anything')
        $a.query | Should Be 'patchTools'
        $a.sevenZipNeeded | Should Be $false
        (@($a.missing) -contains '7z') | Should Be $false
        (@('TOOLS_OK', 'TOOLS_MISSING') -contains $a.verdict) | Should Be $true
    }
    It 'answers -ShowOutputPath with the path as a property, wildcard characters intact' {
        $dir = New-ScratchDir 'json[1]'
        try {
            $exe = Join-Path $dir 'driver [1].exe'
            Set-Content -LiteralPath $exe -Value 'x'
            $a = Invoke-PipelineQuery -Arguments @('-ShowOutputPath', '-SourceExePath', $exe)
            $a.outputPath | Should Be (Join-Path $dir 'driver [1]_Patched')
        } finally { Remove-ScratchDir $dir }
    }
    It 'answers -CheckSource with problems as a list even when there is only one' {
        $dir = New-ScratchDir 'jsonsrc'
        try {
            $exe = Join-Path $dir 'fake-driver.exe'
            Set-Content -LiteralPath $exe -Value 'not signed'
            $raw = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:PipelinePs1 -CheckSource -SourceExePath $exe -Json 2>$null
            $line = [string](@($raw | Where-Object { ([string]$_).TrimStart().StartsWith('{') }) | Select-Object -Last 1)
            $line | Should Match '"verdict":"SOURCE_UNTRUSTED"'
            $line | Should Match '"problems":\['
        } finally { Remove-ScratchDir $dir }
    }
    It 'keeps the text report as the default for a person at a console' {
        $out = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:PipelinePs1 -CheckNvAppStaged 2>$null
        ([string]@($out)[0]) | Should Match '^NVAPP_(STAGED|NONE)$'
    }
}

Describe 'A failed run never leaves the final output name behind' {
    It 'builds in <output>.partial and creates <output> only on success' {
        # A package the whitelist patcher cannot patch: Display.Driver has no INF the shipped
        # whitelist names, so the run fails before signing. Tool paths are given explicitly (any
        # existing file passes the preflight; neither tool is reached), so this needs no WDK.
        $dir = New-ScratchDir 'partial'
        try {
            $pkg = Join-Path $dir 'pkg'
            New-Item -ItemType Directory -Path (Join-Path $pkg 'Display.Driver') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $pkg 'setup.exe') -Value 'stub'
            Set-Content -LiteralPath (Join-Path $pkg 'setup.cfg') -Value '<setup title="x" version="1.0"></setup>'
            Set-Content -LiteralPath (Join-Path $pkg 'Display.Driver\unrelated.inf') -Value @('[Version]', 'CatalogFile = NV_DISP.CAT')
            $out = Join-Path $dir 'pkg_Patched'
            $stub = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
            # The child's error text arrives on stderr; under 'Stop' Windows PowerShell 5.1 would turn
            # its first line into a terminating error here. Only the exit code is under test.
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:PipelinePs1 `
                    -SourcePackagePath $pkg -OutputPath $out -SkipSourceVerification -SkipSetupCertOption `
                    -NonInteractive -KeepAllOldCerts -Inf2CatPath $stub -SignToolPath $stub 2>&1 | Out-Null
                $exit = $LASTEXITCODE
            } finally { $ErrorActionPreference = $prevEap }
            $exit | Should Not Be 0
            (Test-Path -LiteralPath $out) | Should Be $false
            (Test-Path -LiteralPath ($out + '.partial')) | Should Be $true
            # The source is never touched.
            (Test-Path -LiteralPath (Join-Path $pkg 'Display.Driver\unrelated.inf')) | Should Be $true
        } finally { Remove-ScratchDir $dir }
    }
}

Describe 'Remove-ForeignOemInfs.ps1' {
    It 'removes only the INFs that cannot match the given hardware, and their manifest entries' {
        $p = New-PrunePackage
        try {
            Invoke-Prune -Root $p.Root -Whitelist $p.Whitelist -Extra @{ HardwareId = @('PCI\VEN_10DE&DEV_2E46&SUBSYS_14581558') }
            (Test-Path -LiteralPath (Join-Path $p.Driver 'nv_dispi.inf')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $p.Driver 'oema.inf')) | Should Be $false
            # Same DEV, someone else's SUBSYS: Windows could never pick it for this GPU.
            (Test-Path -LiteralPath (Join-Path $p.Driver 'oemb.inf')) | Should Be $false
            $nvi = [System.IO.File]::ReadAllText($p.Nvi)
            $nvi | Should Match 'name="nv_dispi\.inf"'
            $nvi | Should Not Match 'oema\.inf'
            $nvi | Should Not Match 'oemb\.inf'
            { [xml]$nvi } | Should Not Throw
        } finally { Remove-ScratchDir $p.Root }
    }
    It 'leaves the companions of a pruned INF, file and manifest entry both' {
        $p = New-PrunePackage
        try {
            Invoke-Prune -Root $p.Root -Whitelist $p.Whitelist -Extra @{ HardwareId = @('PCI\VEN_10DE&DEV_2E46&SUBSYS_14581558') }
            (Test-Path -LiteralPath (Join-Path $p.Driver 'oema.cat')) | Should Be $true
            [System.IO.File]::ReadAllText($p.Nvi) | Should Match 'name="oema\.cat"'
        } finally { Remove-ScratchDir $p.Root }
    }
    It 'leaves no staging folder behind' {
        $p = New-PrunePackage
        try {
            Invoke-Prune -Root $p.Root -Whitelist $p.Whitelist -Extra @{ HardwareId = @('PCI\VEN_10DE&DEV_2E46&SUBSYS_14581558') }
            @(Get-ChildItem -LiteralPath $p.Root -Directory -Force | Where-Object { $_.Name -like '.prune-staging-*' }).Count | Should Be 0
        } finally { Remove-ScratchDir $p.Root }
    }
    It 'keeps an OEM INF that matches the hardware exactly' {
        $p = New-PrunePackage
        try {
            Invoke-Prune -Root $p.Root -Whitelist $p.Whitelist -Extra @{ HardwareId = @('PCI\VEN_10DE&DEV_2E46&SUBSYS_99991043') }
            (Test-Path -LiteralPath (Join-Path $p.Driver 'oemb.inf')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $p.Driver 'oema.inf')) | Should Be $false
        } finally { Remove-ScratchDir $p.Root }
    }
    It 'keeps an INF named with -KeepInf, by bare stem' {
        $p = New-PrunePackage
        try {
            Invoke-Prune -Root $p.Root -Whitelist $p.Whitelist -Extra @{ HardwareId = @('PCI\VEN_10DE&DEV_2E46&SUBSYS_14581558'); KeepInf = @('oema') }
            (Test-Path -LiteralPath (Join-Path $p.Driver 'oema.inf')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $p.Driver 'oemb.inf')) | Should Be $false
        } finally { Remove-ScratchDir $p.Root }
    }
    It 'changes nothing under -WhatIf' {
        $p = New-PrunePackage
        try {
            $before = [System.IO.File]::ReadAllBytes($p.Nvi)
            Invoke-Prune -Root $p.Root -Whitelist $p.Whitelist -Extra @{ HardwareId = @('PCI\VEN_10DE&DEV_2E46&SUBSYS_14581558'); WhatIf = $true }
            @(Get-ChildItem -LiteralPath $p.Driver -Filter *.inf -File).Count | Should Be 3
            ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($p.Nvi))) | Should Be ([System.Convert]::ToBase64String($before))
        } finally { Remove-ScratchDir $p.Root }
    }
    It 'refuses to prune a package down to no INF at all' {
        # The whitelist names an INF this package does not have and the hardware matches nothing,
        # so every INF would go. That once left a 3.6 GB package with no INF in it (616.92).
        $p = New-PrunePackage -WhitelistInf 'zz_absent.inf'
        try {
            { Invoke-Prune -Root $p.Root -Whitelist $p.Whitelist -Extra @{ HardwareId = @('PCI\VEN_10DE&DEV_FFFF&SUBSYS_00000000') } } | Should Throw
            @(Get-ChildItem -LiteralPath $p.Driver -Filter *.inf -File).Count | Should Be 3
        } finally { Remove-ScratchDir $p.Root }
    }
}
