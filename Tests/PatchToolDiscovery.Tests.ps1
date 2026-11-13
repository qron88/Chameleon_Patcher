# Unit tests for the shared helpers in Scripts\PatchToolDiscovery.ps1: INF parsing and writing, the
# rename lookup, the template/donor merge, catalog membership, source and certificate identity.
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
    It 'flags a continuation whose backslash is followed by spaces, which real INFs do use' {
        # Get-Content keeps those trailing spaces, so testing the raw line with EndsWith let exactly
        # the kind of split this check exists to find through.
        $lines = @('[NVIDIA_Devices.NTamd64.10.0]',
                   '%NVIDIA_DEV.1E90% = Section001, \   ',
                   '    PCI\VEN_10DE&DEV_1E90&SUBSYS_112210DE')
        Test-InfLineContinuations -Path 'nv_dispi.inf' -Lines $lines | Should Be 1
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

Describe 'Resolve-WhitelistInf when the widened lookup is ambiguous' {
    It 'refuses to guess between two INFs that both share the stem' {
        $dir = New-ScratchDir 'infambig'
        try {
            Set-Content -LiteralPath (Join-Path $dir 'nv_dispsi.inf') -Value 'x'
            Set-Content -LiteralPath (Join-Path $dir 'nv_dispwi.inf') -Value 'x'
            { Resolve-WhitelistInf -DisplayDriverPath $dir -InfName 'nv_dispi.inf' } | Should Throw 'Refusing to guess'
        } finally { Remove-ScratchDir $dir }
    }
    It 'returns all of them with -AllowMany, which is what -KeepInf asks for' {
        $dir = New-ScratchDir 'infmany'
        try {
            Set-Content -LiteralPath (Join-Path $dir 'nvamsi.inf') -Value 'x'
            Set-Content -LiteralPath (Join-Path $dir 'nvamwi.inf') -Value 'x'
            (@(Resolve-WhitelistInf -DisplayDriverPath $dir -InfName 'nvami.inf' -AllowMany)).Count | Should Be 2
        } finally { Remove-ScratchDir $dir }
    }
    It 'still prefers an exact name even when same-stem siblings exist' {
        $dir = New-ScratchDir 'infexact2'
        try {
            foreach ($n in 'nv_dispi.inf', 'nv_dispig.inf', 'nv_dispwi.inf') { Set-Content -LiteralPath (Join-Path $dir $n) -Value 'x' }
            $hit = @(Resolve-WhitelistInf -DisplayDriverPath $dir -InfName 'nv_dispi.inf')
            $hit.Count | Should Be 1
            $hit[0].Exact | Should Be $true
        } finally { Remove-ScratchDir $dir }
    }
}

Describe 'Write-TextFileAtomic and the INF writers' {
    It 'replaces a file in place and leaves no temporary file behind' {
        $dir = New-ScratchDir 'atomic'
        try {
            $p = Join-Path $dir 'x.inf'
            [System.IO.File]::WriteAllText($p, "old`r`n")
            Write-TextFileAtomic -Path $p -Text "new`r`n" -Encoding (New-Object System.Text.UTF8Encoding($false))
            [System.IO.File]::ReadAllText($p) | Should Be "new`r`n"
            (@(Get-ChildItem -LiteralPath $dir -File)).Count | Should Be 1
        } finally { Remove-ScratchDir $dir }
    }
    It 'creates a file that does not exist yet' {
        $dir = New-ScratchDir 'atomicnew'
        try {
            $p = Join-Path $dir 'fresh.txt'
            Write-TextFileAtomic -Path $p -Text 'hello' -Encoding (New-Object System.Text.UTF8Encoding($false))
            [System.IO.File]::ReadAllText($p) | Should Be 'hello'
        } finally { Remove-ScratchDir $dir }
    }
    It 'round-trips an LF-only file with a BOM byte for byte through Get-InfTextFile / Write-InfLines' {
        $dir = New-ScratchDir 'roundtrip'
        try {
            $p = Join-Path $dir 'lf.inf'
            $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes("[Version]`nA = 1`n"))
            [System.IO.File]::WriteAllBytes($p, $bytes)
            $state = Get-InfTextFile -Path $p
            Write-InfLines -Path $p -Lines $state.Lines -State $state
            ([System.IO.File]::ReadAllBytes($p) -join ',') | Should Be ($bytes -join ',')
        } finally { Remove-ScratchDir $dir }
    }
    It 'keeps an ANSI-codepage file in its codepage instead of turning accents into U+FFFD' {
        $dir = New-ScratchDir 'ansi'
        try {
            $p = Join-Path $dir 'oem.inf'
            $ansi = Get-AnsiEncoding
            $bytes = $ansi.GetBytes("[Strings]`r`nVendor = `"Caf" + [char]0x00E9 + "`"`r`n")
            [System.IO.File]::WriteAllBytes($p, $bytes)
            $state = Get-InfTextFile -Path $p -WarningAction SilentlyContinue
            Write-InfLines -Path $p -Lines $state.Lines -State $state
            ([System.IO.File]::ReadAllBytes($p) -join ',') | Should Be ($bytes -join ',')
        } finally { Remove-ScratchDir $dir }
    }
}

Describe 'Test-InfRmOverrideLine' {
    It 'accepts the directive the patcher writes, with or without spaces and a trailing comment' {
        Test-InfRmOverrideLine 'HKR,,RM1457588,%REG_DWORD%,1' | Should Be $true
        Test-InfRmOverrideLine '  HKR , , RM1457588 , %REG_DWORD%, 1 ; added' | Should Be $true
    }
    It 'does not count a comment that only mentions the value' {
        Test-InfRmOverrideLine '; RM1457588 is added by the patcher' | Should Be $false
        Test-InfRmOverrideLine 'HKR,,Other,%REG_DWORD%,1 ; see RM1457588' | Should Be $false
    }
    It 'does not count a different value name that merely contains the digits' {
        Test-InfRmOverrideLine 'HKR,,RM14575880,%REG_DWORD%,1' | Should Be $false
    }
}

Describe 'Get-InfDirectiveKey' {
    It 'strips the per-release __NN numbering, so two numberings of one job compare equal' {
        Get-InfDirectiveKey 'CopyFiles = nv_ngx_builtins_copyfiles__01' | Should Be 'copyfiles|nv_ngx_builtins_copyfiles'
        Get-InfDirectiveKey 'CopyFiles = nv_ngx_builtins_copyfiles__07' | Should Be 'copyfiles|nv_ngx_builtins_copyfiles'
        Get-InfDirectiveKey 'AddReg = nv_miscBase_addreg__16' | Should Be 'addreg|nv_miscbase_addreg'
    }
    It 'returns nothing for a feature flag, which is a per-GPU decision and never merged' {
        ([bool](Get-InfDirectiveKey 'NVSupportPhysx = 1')) | Should Be $false
        ([bool](Get-InfDirectiveKey 'FeatureScore = CF')) | Should Be $false
    }
}

Describe 'Merge-InfTemplateWithDonor' {
    # A stock section from "this release" that does one job more than the captured template, and
    # differs from it in a flag.
    function New-Sections {
        $s = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' ([StringComparer]::OrdinalIgnoreCase)
        $s['Section001'] = New-Object System.Collections.Generic.List[string]
        foreach ($l in 'AddReg = nv_commonBase_addreg__01', 'AddReg = nv_miscBase_addreg__01', 'CopyFiles = nv_system32_copyfiles__01',
                       'AddReg = nv_global_addreg', 'AddReg = nv_opengl_addreg', 'CopyFiles = nv_openCL_copyfiles', 'DelReg = nv_dch_delreg',
                       'CopyFiles = nv_sysDrivers_copyfiles', 'CopyFiles = nv_ngx_copyfiles__01', 'CopyFiles = nv_ngx_builtins_copyfiles__01',
                       'NVSupportPhysx = 1', 'SupportNvCpl = 0') { $s['Section001'].Add($l) }
        $s['Section001.Services'] = New-Object System.Collections.Generic.List[string]
        $s['Section001.Services'].Add('AddService = nvlddmkm, 0x00000002, nvlddmkm_Service_Inst')
        $s['Section001.HW'] = New-Object System.Collections.Generic.List[string]
        $s['Section001.HW'].Add('AddReg = nv_hw_addreg')
        $s['Section999'] = New-Object System.Collections.Generic.List[string]
        $s['Section999'].Add('AddReg = unrelated_addreg')
        return $s
    }
    $template = [ordered]@{
        '_base'    = @('AddReg = nv_commonBase_addreg__01', 'AddReg = nv_miscBase_addreg__01', 'CopyFiles = nv_system32_copyfiles__01',
                       'AddReg = nv_global_addreg', 'AddReg = nv_opengl_addreg', 'CopyFiles = nv_openCL_copyfiles', 'DelReg = nv_dch_delreg',
                       'CopyFiles = nv_sysDrivers_copyfiles', 'CopyFiles = nv_ngx_copyfiles__01', 'NVSupportPhysx = 1')
        'Services' = @('AddService = nvlddmkm, 0x00000002, nvlddmkm_Service_Inst')
    }

    It 'picks the closest stock install section as donor and adds the job the template lacks' {
        $m = Merge-InfTemplateWithDonor -TemplateFamily $template -Sections (New-Sections) -InstallSections @('Section001', 'Section999')
        $m.Donor | Should Be 'Section001'
        (@($m.Family['_base']) -contains 'CopyFiles = nv_ngx_builtins_copyfiles__01') | Should Be $true
    }
    It 'never copies a feature flag from the donor' {
        $m = Merge-InfTemplateWithDonor -TemplateFamily $template -Sections (New-Sections) -InstallSections @('Section001')
        (@($m.Family['_base']) -contains 'SupportNvCpl = 0') | Should Be $false
    }
    It 'takes a companion section the template has never had, whole' {
        $m = Merge-InfTemplateWithDonor -TemplateFamily $template -Sections (New-Sections) -InstallSections @('Section001')
        (@($m.Family['HW']) -contains 'AddReg = nv_hw_addreg') | Should Be $true
    }
    It 'does not add a second numbering of a job the template already does' {
        $s = New-Sections
        $s['Section001'][1] = 'AddReg = nv_miscBase_addreg__05'
        $m = Merge-InfTemplateWithDonor -TemplateFamily $template -Sections $s -InstallSections @('Section001') -MinSimilarity 0.5
        (@($m.Family['_base'] | Where-Object { $_ -like 'AddReg = nv_miscBase_addreg__*' })).Count | Should Be 1
    }
    It 'leaves the template alone when no stock section is close enough' {
        $m = Merge-InfTemplateWithDonor -TemplateFamily $template -Sections (New-Sections) -InstallSections @('Section999')
        $m.Donor | Should BeNullOrEmpty
        @($m.Added).Count | Should Be 0
        (@($m.Family['_base'])).Count | Should Be 10
    }
}

Describe 'Test-ProjectSigningCertificate' {
    # Built in memory with CertificateRequest - nothing touches a certificate store.
    function New-TestCert {
        param([string]$Subject = 'CN=Chameleon Project - Test', [switch]$NoEku, [switch]$Ca, $Issuer)
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest($Subject, $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        if (-not $NoEku) {
            $oids = New-Object System.Security.Cryptography.OidCollection
            [void]$oids.Add((New-Object System.Security.Cryptography.Oid '1.3.6.1.5.5.7.3.3'))
            $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($oids, $false)))
        }
        $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension([bool]$Ca, $false, 0, $true)))
        if ($Issuer) {
            $serial = [byte[]](1, 2, 3, 4)
            return $req.Create($Issuer, (Get-Date).AddDays(-1), (Get-Date).AddDays(1), $serial)
        }
        return $req.CreateSelfSigned((Get-Date).AddDays(-1), (Get-Date).AddDays(1))
    }

    It 'accepts a self-signed code-signing non-CA certificate with a project subject' {
        Test-ProjectSigningCertificate -Certificate (New-TestCert) | Should BeNullOrEmpty
    }
    It 'rejects a certificate whose subject matches none of the project patterns' {
        Test-ProjectSigningCertificate -Certificate (New-TestCert -Subject 'CN=Someone Else') | Should Match 'subject'
    }
    It 'rejects a CA that merely has "Chameleon" in its name' {
        Test-ProjectSigningCertificate -Certificate (New-TestCert -Subject 'CN=Chameleon Corp Root CA' -Ca) | Should Match 'certificate authority'
    }
    It 'rejects a certificate without the Code Signing EKU' {
        Test-ProjectSigningCertificate -Certificate (New-TestCert -NoEku) | Should Match 'Code Signing'
    }
    It 'rejects a certificate issued by someone else' {
        $ca = New-TestCert -Subject 'CN=Driver Patch Issuing CA' -Ca
        Test-ProjectSigningCertificate -Certificate (New-TestCert -Issuer $ca) | Should Match 'not self-signed'
    }
}

Describe 'Catalog membership and declared catalogs' {
    It 'finds the files a catalog does not list' {
        $dir = New-ScratchDir 'catalog'
        try {
            $payload = Join-Path $dir 'payload'
            New-Item -ItemType Directory -Path $payload | Out-Null
            Set-Content -LiteralPath (Join-Path $payload 'a.inf') -Value 'in the catalog'
            $cat = Join-Path $dir 'test.cat'
            New-FileCatalog -Path $payload -CatalogFilePath $cat -CatalogVersion 2.0 | Out-Null
            Set-Content -LiteralPath (Join-Path $payload 'late.inf') -Value 'added afterwards'
            $miss = @(Get-CatalogNonMember -CatalogPath $cat -Path @((Join-Path $payload 'a.inf'), (Join-Path $payload 'late.inf')))
            $miss.Count | Should Be 1
            (Split-Path $miss[0] -Leaf) | Should Be 'late.inf'
        } finally { Remove-ScratchDir $dir }
    }
    It 'notices a member whose content changed after cataloguing' {
        $dir = New-ScratchDir 'catalogedit'
        try {
            $payload = Join-Path $dir 'payload'
            New-Item -ItemType Directory -Path $payload | Out-Null
            $inf = Join-Path $payload 'a.inf'
            Set-Content -LiteralPath $inf -Value 'original'
            $cat = Join-Path $dir 'test.cat'
            New-FileCatalog -Path $payload -CatalogFilePath $cat -CatalogVersion 2.0 | Out-Null
            Set-Content -LiteralPath $inf -Value 'patched'
            (@(Get-CatalogNonMember -CatalogPath $cat -Path @($inf))).Count | Should Be 1
        } finally { Remove-ScratchDir $dir }
    }
    It 'pairs INFs with the catalog they declare, including decorated CatalogFile forms' {
        $dir = New-ScratchDir 'declared'
        try {
            Set-Content -LiteralPath (Join-Path $dir 'a.inf') -Value @('[Version]', 'CatalogFile = NV_DISP.CAT ; shared')
            Set-Content -LiteralPath (Join-Path $dir 'b.inf') -Value @('[Version]', 'CatalogFile.NTamd64 = NV_DISP.CAT')
            Set-Content -LiteralPath (Join-Path $dir 'c.inf') -Value @('[Version]', 'CatalogFile=other.cat')
            $map = Get-InfDeclaredCatalog -Folder $dir
            @($map['NV_DISP.CAT']).Count | Should Be 2
            @($map['other.cat']).Count | Should Be 1
        } finally { Remove-ScratchDir $dir }
    }
}

Describe 'Test-DriverSource' {
    It 'refuses an unsigned .exe' {
        $dir = New-ScratchDir 'src'
        try {
            $exe = Join-Path $dir 'fake-driver.exe'
            Set-Content -LiteralPath $exe -Value 'not signed'
            (Test-DriverSource -ExePath $exe).Ok | Should Be $false
        } finally { Remove-ScratchDir $dir }
    }
    It 'refuses a validly signed .exe that NVIDIA did not sign' {
        # cmd.exe is Microsoft-signed. Microsoft is accepted for WHQL catalogs, never for a download.
        $r = Test-DriverSource -ExePath (Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe')
        $r.Ok | Should Be $false
        ($r.Problems -join ' ') | Should Match 'not by NVIDIA'
    }
    It 'refuses a folder whose INFs declare no catalog' {
        $dir = New-ScratchDir 'srcdir'
        try {
            $dd = Join-Path $dir 'Display.Driver'
            New-Item -ItemType Directory -Path $dd | Out-Null
            Set-Content -LiteralPath (Join-Path $dd 'nv_dispi.inf') -Value '[Version]'
            (Test-DriverSource -PackagePath $dir).Ok | Should Be $false
        } finally { Remove-ScratchDir $dir }
    }
    It 'refuses a folder whose catalog is not signed by NVIDIA or Microsoft' {
        $dir = New-ScratchDir 'srcunsigned'
        try {
            $dd = Join-Path $dir 'Display.Driver'
            New-Item -ItemType Directory -Path $dd | Out-Null
            Set-Content -LiteralPath (Join-Path $dd 'nv_dispi.inf') -Value @('[Version]', 'CatalogFile = NV_DISP.CAT')
            # New-FileCatalog only writes a FILE for a lower-case ".cat" name; build it outside, then move it in.
            New-FileCatalog -Path $dd -CatalogFilePath (Join-Path $dir 'self.cat') -CatalogVersion 2.0 | Out-Null
            Move-Item -LiteralPath (Join-Path $dir 'self.cat') -Destination (Join-Path $dd 'NV_DISP.CAT')
            $r = Test-DriverSource -PackagePath $dir
            $r.Ok | Should Be $false
            ($r.Problems -join ' ') | Should Match 'NV_DISP.CAT'
        } finally { Remove-ScratchDir $dir }
    }
}

Describe 'Get-SystemToolPath' {
    It 'returns the System32 copy of a tool, never a PATH lookup' {
        Get-SystemToolPath 'certutil.exe' | Should Be (Join-Path ([Environment]::GetFolderPath('System')) 'certutil.exe')
    }
    It 'throws for a tool that is not in System32' {
        { Get-SystemToolPath 'definitely-not-a-tool.exe' } | Should Throw
    }
}
