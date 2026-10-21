# Unit tests for the shared INF/discovery helpers in Scripts\PatchToolDiscovery.ps1, plus the
# version guard that lives in Scripts\Unpack-DriverExe.ps1.
#
# Pester 3.4.0 syntax (the version shipped with PowerShell 5.1, so the same file runs on 5.1 and 7):
# "Should Be" rather than "Should -Be", and no BeforeEach/AfterAll dependency - each test creates and
# removes its own scratch directory, so tests stay order-independent.
#
# Run:  Invoke-Pester Tests\PatchToolDiscovery.Tests.ps1
#       (from the repository root, or point Invoke-Pester at this file's full path)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:ScriptsDir = Join-Path $RepoRoot 'Scripts'

# PatchToolDiscovery.ps1 is a function library with no side effects at load time, which is exactly
# why every other script in Scripts\ dot-sources it. Do the same here.
. (Join-Path $ScriptsDir 'PatchToolDiscovery.ps1')

# Load one function out of a script that DOES run top-level code when dot-sourced, so the pure logic
# in it can be tested without executing the script.
# Loaded as a scriptblock and DOT-SOURCED at the call below, not called as a function: Invoke-Expression
# defines the function in whichever scope runs it, and a function body runs in its own scope, so the
# imported function would vanish the moment a normal call returned.
$ImportFunctionFromScript = {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw "parse errors in ${Path}: $((@($parseErrors) | ForEach-Object { $_.Message }) -join '; ')" }
    $found = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    if (@($found).Count -eq 0) { throw "no function named $Name in $Path" }
    # Define it in this file's script scope: a function created by Invoke-Expression inside a
    # helper function vanishes when that helper returns, and the It blocks below would then hit
    # CommandNotFound - or, worse, pass vacuously inside a "Should Not Throw" wrapper.
    Invoke-Expression (@($found)[0].Extent.Text)
}

function New-ScratchDir {
    param([string]$Hint = 'scratch')
    $root = Join-Path ([System.IO.Path]::GetTempPath()) 'chameleon-patcher-tests'
    $dir = Join-Path $root ($Hint + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Remove-ScratchDir {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
}

. $ImportFunctionFromScript -Path (Join-Path $ScriptsDir 'Unpack-DriverExe.ps1') -Name 'Assert-ExpandedVersionMatchesRequest'

Describe 'Get-InfSectionIndex' {
    # EndIndex from the section scanners is an UPPER BOUND (end of file for the last section), so the
    # insert point has to be walked back over the blank/comment tail of the body.
    It 'walks back over a blank tail so the line stays inside the section that ends the file' {
        $lines = @('[Strings]', 'Foo = "bar"', '', '')
        Get-InfSectionIndex -Lines $lines -HeaderIndex 0 -EndIndex $lines.Count | Should Be 2
    }
    It 'walks back over a comment tail as well' {
        $lines = @('[nv_miscBase_addreg__01]', 'HKR,,A,,1', '; captured from the stock INF', '')
        Get-InfSectionIndex -Lines $lines -HeaderIndex 0 -EndIndex $lines.Count | Should Be 2
    }
    It 'stops at the first real body line, so a blank line in the middle of a section is not skipped over' {
        $lines = @('[Strings]', 'A = "a"', '', 'B = "b"')
        Get-InfSectionIndex -Lines $lines -HeaderIndex 0 -EndIndex $lines.Count | Should Be 4
    }
    It 'inserts straight after the header when the section is empty' {
        $lines = @('[nv_miscBase_addreg__01]', '[Strings]')
        Get-InfSectionIndex -Lines $lines -HeaderIndex 0 -EndIndex 1 | Should Be 1
    }
    It 'binds the List[string] buffer a patcher really passes, and arrays that contain blank lines' {
        # Not hypothetical: a Mandatory [string[]] parameter refused to bind here on both 5.1 and 7.6,
        # which would have thrown inside every real INF, since INF bodies are full of empty lines.
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($l in @('[Strings]', 'Foo = "bar"', '')) { $list.Add($l) }
        Get-InfSectionIndex -Lines $list -HeaderIndex 0 -EndIndex 3 | Should Be 2
    }
    It 'treats a missing or out-of-range EndIndex as end of file' {
        $lines = @('[Strings]', 'A = "a"', '')
        Get-InfSectionIndex -Lines $lines -HeaderIndex 0 -EndIndex 99 | Should Be 2
        Get-InfSectionIndex -Lines $lines -HeaderIndex 0 | Should Be 2
    }
}

Describe 'Test-InfLineContinuations' {
    It 'flags a device entry split across physical lines' {
        $lines = @('[NVIDIA_Devices.NTamd64.10.0]',
                   '%NVIDIA_DEV.1E90% = Section001, \',
                   '    PCI\VEN_10DE&DEV_1E90&SUBSYS_112210DE')
        Test-InfLineContinuations -Path 'nv_dispi.inf' -Lines $lines | Should Be 1
    }
    It 'flags [Strings] and nv_miscBase_addreg__ sections' {
        $lines = @('[Strings.NTamd64.10.0]', 'Foo = \', '"a long name"', '[nv_miscBase_addreg__07]', 'HKR,,RM1457588, \', '%REG_DWORD%,1')
        Test-InfLineContinuations -Path 'nv_dispi.inf' -Lines $lines | Should Be 2
    }
    It 'stays quiet about continuations in sections the toolkit never patches' {
        $lines = @('[CopyFiles]', 'nvapi64.dll, nvapi64.dll \', '    nvapi_nt.dll', '[Section001]', 'CopyFiles = NVWMI_InstallDir \', '    nv_ngx_copyfiles__01')
        Test-InfLineContinuations -Path 'nv_dispi.inf' -Lines $lines | Should Be 0
    }
    It 'returns 0 for a plain INF' {
        $lines = @('[Version]', 'Class=Display', '[NVIDIA_Devices.NTamd64.10.0]', '%X% = Section001, PCI\VEN_10DE&DEV_1234')
        Test-InfLineContinuations -Path 'nv_dispi.inf' -Lines $lines | Should Be 0
    }
}

Describe 'driver version helpers' {
    It 'reads the version NVIDIA writes into the download file name' {
        Get-DriverVersionTextFromPath -Path 'C:\Users\you\Downloads\616.86-desktop-win10-win11-64bit-international-dch-whql.exe' | Should Be '616.86'
    }
    It 'reads the version NVIDIA writes into its expansion folder' {
        Get-DriverVersionTextFromPath -Path 'C:\NVIDIA\DisplayDriver\617.42\Win10_64\Current' | Should Be '617.42'
    }
    It 'takes the deepest version segment when asked, because a user-picked folder may carry one higher up' {
        Get-DriverVersionTextFromPath -Path 'D:\616.86_Patched\Downloads\617.142\Current' -Deepest | Should Be '617.142'
        Get-DriverVersionTextFromPath -Path 'D:\616.86_Patched\Downloads\617.142\Current' | Should Be '616.86'
    }
    It 'handles three-part build numbers, which NVIDIA publishes now' {
        Get-DriverVersionTextFromPath -Path 'C:\NVIDIA\DisplayDriver\552.22.0.4\Win10_64' | Should Be '552.22.0.4'
    }
    It 'returns nothing for a path that names no version, rather than guessing' {
        ([bool](Get-DriverVersionTextFromPath -Path 'C:\NVIDIA\DisplayDriver\Win10_64\Current')) | Should Be $false
        ([bool](Get-DriverVersionTextFromPath -Path '')) | Should Be $false
    }
    It 'orders 617.142 above 617.42, which sorting the paths as text does not' {
        $paths = @('C:\NVIDIA\DisplayDriver\617.42\Win10_64\Current\setup.exe',
                   'C:\NVIDIA\DisplayDriver\617.142\Win10_64\Current\setup.exe',
                   'C:\NVIDIA\DisplayDriver\595.79\Win10_64\Current\setup.exe')
        $byVersion = @($paths | Sort-Object @{Expression = { Get-PathVersionForSort -Path $_ }; Descending = $true })
        $byVersion[0] | Should Be 'C:\NVIDIA\DisplayDriver\617.142\Win10_64\Current\setup.exe'
        $byVersion[1] | Should Be 'C:\NVIDIA\DisplayDriver\617.42\Win10_64\Current\setup.exe'
        # The regression this replaced: a plain text sort puts 617.42 first, because "4" > "1".
        (@($paths | Sort-Object -Descending)[0]) | Should Not Be $byVersion[0]
    }
    It 'sorts paths with no version in them last, never above a real version' {
        Get-PathVersionForSort -Path 'C:\NVIDIA\DisplayDriver\Win10_64\Current\setup.exe' | Should Be ([version]'0.0')
    }
}

Describe 'Get-InfDeviceLine and Test-InfDeviceIdMatch' {
    It 'parses the real INF line shape: %token% = <Section>, <hardware id>' {
        $p = Get-InfDeviceLine -Line '%NVIDIA_DEV.1E90% = Section001, PCI\VEN_10DE&DEV_1E90&SUBSYS_000010DE'
        $p.Token | Should Be 'NVIDIA_DEV.1E90'
        $p.Section | Should Be 'Section001'
        @($p.Ids).Count | Should Be 1
        $p.Ids[0].Dev | Should Be '1E90'
        $p.Ids[0].Subsys | Should Be '000010DE'
        @($p.Ids[0].Extra).Count | Should Be 0
    }
    It 'ignores a trailing comment and keeps several hardware IDs from one line' {
        $p = Get-InfDeviceLine -Line '%NVIDIA_DEV.1E90% = Section001, PCI\VEN_10DE&DEV_1E90, PCI\VEN_10DE&DEV_1F12 ; added by hand'
        @($p.Ids).Count | Should Be 2
        $p.Ids[1].Dev | Should Be '1F12'
        ([bool]($p.Ids[1].Subsys)) | Should Be $false
    }
    It 'returns nothing for a line that is not a device entry' {
        ([bool](Get-InfDeviceLine -Line 'HKR,,RM1457588,%REG_DWORD%,1')) | Should Be $false
        ([bool](Get-InfDeviceLine -Line '[NVIDIA_Devices.NTamd64.10.0]')) | Should Be $false
        ([bool](Get-InfDeviceLine -Line '')) | Should Be $false
    }
    It 'keeps qualifiers other than SUBSYS in Extra instead of silently dropping them' {
        $p = Get-InfDeviceLine -Line '%NVIDIA_DEV.1E90% = Section001, PCI\VEN_10DE&DEV_1E90&SUBSYS_000010DE&REV_A1'
        @($p.Ids[0].Extra).Count | Should Be 1
        $p.Ids[0].Extra[0] | Should Be 'REV_A1'
    }
    It 'treats a stock line carrying &REV_A1 as NOT the whitelist entry, but still usable hardware' {
        $p = Get-InfDeviceLine -Line '%X% = Section001, PCI\VEN_10DE&DEV_1E90&SUBSYS_000010DE&REV_A1'
        Test-InfDeviceIdMatch -Id $p.Ids[0] -Dev '1E90' -Subsys '000010DE' -Mode 'Entry' | Should Be $false
        Test-InfDeviceIdMatch -Id $p.Ids[0] -Dev '1E90' -Subsys '000010DE' -Mode 'Hardware' | Should Be $true
        Test-InfDeviceIdMatch -Id $p.Ids[0] -Dev '1E90' -Mode 'Device' | Should Be $true
    }
    It 'matches an entry exactly, including the both-absent SUBSYS case' {
        $bare = Get-InfDeviceLine -Line '%X% = Section001, PCI\VEN_10DE&DEV_1E90'
        Test-InfDeviceIdMatch -Id $bare.Ids[0] -Dev '1E90' -Mode 'Entry' | Should Be $true
        Test-InfDeviceIdMatch -Id $bare.Ids[0] -Dev '1E90' -Subsys '000010DE' -Mode 'Entry' | Should Be $false
        Test-InfDeviceIdMatch -Id $bare.Ids[0] -Dev '1E91' -Mode 'Device' | Should Be $false
    }
    It 'treats a SUBSYS-less stock line as covering every subsystem' {
        $bare = Get-InfDeviceLine -Line '%X% = Section001, PCI\VEN_10DE&DEV_1E90'
        Test-InfDeviceIdMatch -Id $bare.Ids[0] -Dev '1E90' -Subsys '000010DE' -Mode 'Hardware' | Should Be $true
    }
}

Describe 'Resolve-WhitelistInf' {
    # NVIDIA renames INFs between builds: 616.86 appends a letter, 616.92 substitutes one.
    It 'prefers an exact filename match' {
        $dir = New-ScratchDir 'infexact'
        try {
            Set-Content -LiteralPath (Join-Path $dir 'nv_dispi.inf') -Value 'x'
            Set-Content -LiteralPath (Join-Path $dir 'nv_dispig.inf') -Value 'x'
            $hit = @(Resolve-WhitelistInf -DisplayDriverPath $dir -InfName 'nv_dispi.inf')
            $hit.Count | Should Be 1
            $hit[0].Name | Should Be 'nv_dispi.inf'
            $hit[0].Exact | Should Be $true
        } finally { Remove-ScratchDir $dir }
    }
    It 'finds the 616.86 case, where every stem carries an extra letter' {
        $dir = New-ScratchDir 'infg'
        try {
            Set-Content -LiteralPath (Join-Path $dir 'nv_dispig.inf') -Value 'x'
            $hit = @(Resolve-WhitelistInf -DisplayDriverPath $dir -InfName 'nv_dispi.inf')
            $hit.Count | Should Be 1
            $hit[0].Name | Should Be 'nv_dispig.inf'
            $hit[0].Exact | Should Be $false
        } finally { Remove-ScratchDir $dir }
    }
    It 'finds the 616.92 case, where the trailing flavour letter is substituted rather than appended' {
        $dir = New-ScratchDir 'infsi'
        try {
            Set-Content -LiteralPath (Join-Path $dir 'nv_dispsi.inf') -Value 'x'
            $hit = @(Resolve-WhitelistInf -DisplayDriverPath $dir -InfName 'nv_dispi.inf')
            $hit.Count | Should Be 1
            $hit[0].Name | Should Be 'nv_dispsi.inf'
        } finally { Remove-ScratchDir $dir }
    }
    It 'reports nothing when the INF is genuinely absent, so the caller can say so out loud' {
        $dir = New-ScratchDir 'infmiss'
        try {
            Set-Content -LiteralPath (Join-Path $dir 'nvapi.inf') -Value 'x'
            (@(Resolve-WhitelistInf -DisplayDriverPath $dir -InfName 'nv_dispi.inf')).Count | Should Be 0
        } finally { Remove-ScratchDir $dir }
    }
    It 'does not widen a short stem into something meaningless' {
        $dir = New-ScratchDir 'infshort'
        try {
            Set-Content -LiteralPath (Join-Path $dir 'n.ini') -Value 'x'
            (@(Resolve-WhitelistInf -DisplayDriverPath $dir -InfName 'nv.inf')).Count | Should Be 0
        } finally { Remove-ScratchDir $dir }
    }
}

Describe 'Get-CerThumbprint' {
    It 'returns nothing for a file that holds no certificate, instead of throwing' {
        $dir = New-ScratchDir 'cer'
        try {
            $bogus = Join-Path $dir 'not-a-cert.cer'
            Set-Content -LiteralPath $bogus -Value 'this is not a certificate'
            ([bool](Get-CerThumbprint -Path $bogus)) | Should Be $false
            ([bool](Get-CerThumbprint -Path (Join-Path $dir 'absent.cer'))) | Should Be $false
        } finally { Remove-ScratchDir $dir }
    }
}

Describe 'Assert-ExpandedVersionMatchesRequest' {
    # The installer unpack route picks an expansion by timestamp; this is what stops a cached
    # C:\NVIDIA folder of a DIFFERENT driver version from being patched, signed and installed.
    It 'accepts an expansion whose folder names the version that was asked for' {
        # No "Should Not Throw" wrapper: that would also pass when the command itself is missing.
        # What the happy path has to show is silence - a warning here means a version it could not read.
        $warnings = @(& { Assert-ExpandedVersionMatchesRequest -ExpandedRoot 'C:\NVIDIA\DisplayDriver\617.42\Win10_64\Current' -RequestedExePath 'C:\Downloads\617.42-desktop-win10-win11-64bit-international-dch-whql.exe' } 3>&1)
        (@($warnings).Count) | Should Be 0
    }
    It 'throws instead of patching the wrong driver version' {
        { Assert-ExpandedVersionMatchesRequest -ExpandedRoot 'C:\NVIDIA\DisplayDriver\617.42\Win10_64\Current' `
            -RequestedExePath 'C:\Downloads\616.86-desktop-win10-win11-64bit-international-dch-whql.exe' } | Should Throw '617.42'
    }
    It 'says which version it found and which one was asked for' {
        { Assert-ExpandedVersionMatchesRequest -ExpandedRoot 'C:\NVIDIA\DisplayDriver\616.86\Win10_64\Current' `
            -RequestedExePath 'C:\Downloads\617.42-desktop.exe' } | Should Throw '617.42'
    }
    It 'warns, rather than inventing a version, when the expansion folder does not name one' {
        $warnings = @(& { Assert-ExpandedVersionMatchesRequest -ExpandedRoot 'C:\NVIDIA\DisplayDriver\Win10_64\Current' `
            -RequestedExePath 'C:\Downloads\617.42-desktop.exe' } 3>&1)
        (@($warnings).Count) | Should Be 1
        "$(@($warnings)[0])" | Should Match 'does not name a driver version'
    }
    It 'warns when the requested file name does not name a version either' {
        $warnings = @(& { Assert-ExpandedVersionMatchesRequest -ExpandedRoot 'C:\NVIDIA\DisplayDriver\617.42\Win10_64\Current' `
            -RequestedExePath 'C:\Downloads\driver-latest.exe' } 3>&1)
        (@($warnings).Count) | Should Be 1
        "$(@($warnings)[0])" | Should Match 'does not name a driver version'
    }
}
