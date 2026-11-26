# Is the input NVIDIA's: catalog membership through wintrust, the INF-to-catalog pairing,
# and source verification for an .exe or a folder.
#
# Part of the shared helper library. Do not dot-source this file on its own: load
# Scripts\PatchToolDiscovery.ps1, which loads every part in a fixed order.

# --- Catalog membership ----------------------------------------------------------------------------
# A driver catalog lists its members by hash: the Authenticode hash for a PE file, a flat hash for
# anything else, written as a hex "member tag". wintrust computes that hash for us, so "is this file
# covered by that catalog" is one lookup per file, with no signtool process and no trust policy - the
# question is membership, not whether the catalog's signer is trusted yet.
if (-not ('ChameleonCatalog' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
public static class ChameleonCatalog {
    [DllImport("wintrust.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptCATAdminAcquireContext2(out IntPtr phCatAdmin, IntPtr pgSubsystem, string pwszHashAlgorithm, IntPtr pStrongHashPolicy, uint dwFlags);
    [DllImport("wintrust.dll", SetLastError = true)]
    static extern bool CryptCATAdminReleaseContext(IntPtr hCatAdmin, uint dwFlags);
    [DllImport("wintrust.dll", SetLastError = true)]
    static extern bool CryptCATAdminCalcHashFromFileHandle2(IntPtr hCatAdmin, IntPtr hFile, ref uint pcbHash, byte[] pbHash, uint dwFlags);
    [DllImport("wintrust.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CryptCATOpen(string pwszFileName, uint fdwOpenFlags, IntPtr hProv, uint dwPublicVersion, uint dwEncodingType);
    [DllImport("wintrust.dll", SetLastError = true)]
    static extern bool CryptCATClose(IntPtr hCatalog);
    [DllImport("wintrust.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CryptCATGetMemberInfo(IntPtr hCatalog, string pwszReferenceTag);

    static string Tag(string algorithm, string file) {
        IntPtr ctx;
        if (!CryptCATAdminAcquireContext2(out ctx, IntPtr.Zero, algorithm, IntPtr.Zero, 0)) return null;
        try {
            using (FileStream fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                uint size = 64;
                byte[] hash = new byte[size];
                if (!CryptCATAdminCalcHashFromFileHandle2(ctx, fs.SafeFileHandle.DangerousGetHandle(), ref size, hash, 0)) return null;
                return BitConverter.ToString(hash, 0, (int)size).Replace("-", "");
            }
        } finally { CryptCATAdminReleaseContext(ctx, 0); }
    }

    // The files (full paths) the catalog does NOT list, under a SHA256 or a SHA1 member tag.
    public static string[] FindNonMembers(string catalogPath, string[] files) {
        IntPtr cat = CryptCATOpen(catalogPath, 4 /* CRYPTCAT_OPEN_EXISTING */, IntPtr.Zero, 0, 0x00010001);
        if (cat == new IntPtr(-1) || cat == IntPtr.Zero)
            throw new IOException("Cannot open catalog " + catalogPath + " (error " + Marshal.GetLastWin32Error() + ")");
        List<string> missing = new List<string>();
        try {
            foreach (string f in files) {
                bool found = false;
                foreach (string alg in new string[] { "SHA256", "SHA1" }) {
                    string t = Tag(alg, f);
                    if (t != null && CryptCATGetMemberInfo(cat, t) != IntPtr.Zero) { found = true; break; }
                }
                if (!found) missing.Add(f);
            }
        } finally { CryptCATClose(cat); }
        return missing.ToArray();
    }
}

'@
}

function Get-CatalogNonMember {
    <# The subset of -Path (full file paths) that the catalog at -CatalogPath does not list. #>
    param(
        [Parameter(Mandatory = $true)][string]$CatalogPath,
        [string[]]$Path = @()
    )
    if ($Path.Count -eq 0) { return @() }
    return @([ChameleonCatalog]::FindNonMembers((Resolve-Path -LiteralPath $CatalogPath).Path, $Path))
}

function Get-InfDeclaredCatalog {
    <#
       The catalog files the INFs in a folder declare (CatalogFile= and its decorated forms such as
       CatalogFile.NTamd64=), as a hashtable catalog-name -> list of INF names. This is the real
       INF-to-catalog pairing; file names do not carry it (all of NVIDIA's display INFs declare
       NV_DISP.CAT, and no INF is called NV_DISP.inf).
    #>
    param([Parameter(Mandatory = $true)][string]$Folder)
    $map = @{}
    foreach ($inf in @(Get-ChildItem -LiteralPath $Folder -Filter *.inf -File)) {
        foreach ($l in @((Get-InfTextFile -Path $inf.FullName).Lines)) {
            $body = ($l -split ';', 2)[0]
            if ($body -match '^\s*CatalogFile(\.[A-Za-z0-9_.]+)?\s*=\s*(\S+)\s*$') {
                $cat = $Matches[2].Trim()
                if (-not $map.ContainsKey($cat)) { $map[$cat] = New-Object System.Collections.Generic.List[string] }
                if (-not $map[$cat].Contains($inf.Name)) { $map[$cat].Add($inf.Name) }
            }
        }
    }
    return $map
}

function Test-NvidiaSignature {
    <#
       $null when the file carries a valid Authenticode signature from NVIDIA - or, unless -NvidiaOnly,
       from Microsoft - else the reason it does not. Microsoft is accepted for what WHQL signs: a
       driver catalog is countersigned by "Microsoft Windows Hardware Compatibility Publisher". A driver
       DOWNLOAD must be NVIDIA's own: without -NvidiaOnly, any Microsoft-signed .exe (cmd.exe, say)
       would pass as a driver source.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$NvidiaOnly
    )
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') {
        $who = if ($sig.SignerCertificate) { " (signer: $($sig.SignerCertificate.Subject))" } else { "" }
        return "signature status is $($sig.Status)$who"
    }
    $subject = $sig.SignerCertificate.Subject
    $isNvidia = $subject -match '(^|,\s*)O=NVIDIA Corporation(,|$)'
    $isMicrosoft = $subject -match '(^|,\s*)O=Microsoft Corporation(,|$)'
    if ($NvidiaOnly -and -not $isNvidia) { return "it is validly signed, but by $subject, not by NVIDIA" }
    if (-not $isNvidia -and -not $isMicrosoft) { return "it is validly signed, but by $subject, not by NVIDIA or Microsoft" }
    return $null
}

function Test-DriverSource {
    <#
       Is the input to a run genuinely NVIDIA's? This toolkit re-signs whatever it is given with a
       certificate the machine trusts as a root, so an unverified input is the one thing that turns
       it into a way of blessing someone else's binaries.

         .exe     The download's own Authenticode signature, which covers the appended 7z archive,
                  must be valid and NVIDIA's.
         folder   Every catalog the display INFs declare must carry a valid NVIDIA/WHQL signature,
                  and every INF and every driver binary (.sys .dll .exe .bin) in Display.Driver must
                  be a member of one of them - or, for a PE file outside the catalog (installer
                  plugins), carry a valid NVIDIA/Microsoft signature of its own. A folder that was
                  already patched fails here by design: its INFs no longer match NVIDIA's catalog.
                  Outside Display.Driver, every PE file (setup.exe, NVI2, other components) must
                  carry a valid NVIDIA/Microsoft signature too. setup.cfg and the .nvi manifests
                  cannot be verified at all (NVIDIA does not sign them); that is reported as a note.

       Returns @{ Ok; Problems; Notes }. Never throws for a verdict; callers decide.
    #>
    param(
        [string]$ExePath,
        [string]$PackagePath
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]

    if ($ExePath) {
        $why = Test-NvidiaSignature -Path $ExePath -NvidiaOnly
        if ($why) { $problems.Add("$(Split-Path $ExePath -Leaf): $why") }
        else { $notes.Add("$(Split-Path $ExePath -Leaf): valid NVIDIA signature") }
    }
    else {
        $dd = Join-Path $PackagePath 'Display.Driver'
        $catalogs = Get-InfDeclaredCatalog -Folder $dd
        if ($catalogs.Count -eq 0) { $problems.Add("No INF in $dd declares a catalog (CatalogFile=).") }
        $signedCats = @()
        foreach ($name in $catalogs.Keys) {
            $cp = Join-Path $dd $name
            if (-not (Test-Path -LiteralPath $cp -PathType Leaf)) { $problems.Add("$name is declared by $($catalogs[$name].Count) INF(s) but is not a file in the folder."); continue }
            $why = Test-NvidiaSignature -Path $cp
            if ($why) { $problems.Add("${name}: $why"); continue }
            $signedCats += (Resolve-Path -LiteralPath $cp).Path
        }
        if ($signedCats.Count -gt 0) {
            $files = @(Get-ChildItem -LiteralPath $dd -File -Recurse | Where-Object { $_.Extension -notmatch '^\.(cat|nvi)$' } | ForEach-Object { $_.FullName })
            $left = $files
            foreach ($c in $signedCats) { $left = @(Get-CatalogNonMember -CatalogPath $c -Path $left) }
            $unverified = @()
            foreach ($f in $left) {
                if ($f -match '\.(inf|sys)$') { $problems.Add("$($f.Substring($dd.Length + 1)) is not covered by NVIDIA's catalog - modified or foreign."); continue }
                if ($f -match '\.(dll|exe|bin)$') {
                    $why = Test-NvidiaSignature -Path $f
                    if ($why) { $problems.Add("$($f.Substring($dd.Length + 1)) is outside NVIDIA's catalog and $why.") }
                    continue
                }
                $unverified += $f.Substring($dd.Length + 1)
            }
            $notes.Add("$($files.Count - $left.Count) of $($files.Count) Display.Driver files covered by NVIDIA's signed catalog.")
            if ($unverified.Count) { $notes.Add("Data files no signature covers (installer metadata): $($unverified -join ', ')") }
        }

        # The rest of the package. Display.Driver is what this toolkit re-signs, but it is not what
        # the user RUNS: setup.exe, the NVI2 installer core and the other components (HDAudio,
        # NVPCF, ...) are started elevated by the person installing the output, and the GUI offers
        # to launch setup.exe itself. A folder source - above all the one NVIDIA App stages under
        # ProgramData, which ordinary users can write to - is therefore checked as a whole: every
        # PE file outside Display.Driver must carry its own valid NVIDIA/Microsoft signature.
        # Measured on a real staged 621.x package: 14 such files, all valid, about one second.
        $root = (Resolve-Path -LiteralPath $PackagePath).Path.TrimEnd('\')
        $ddPrefix = (Join-Path $root 'Display.Driver') + '\'
        $all = @(Get-ChildItem -LiteralPath $root -File -Recurse)
        $outside = @($all | Where-Object { -not $_.FullName.StartsWith($ddPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
        $installerPe = @($outside | Where-Object { $_.Extension -match '^\.(exe|dll|sys)$' })
        $badPe = 0
        foreach ($f in $installerPe) {
            $why = Test-NvidiaSignature -Path $f.FullName
            if ($why) {
                $badPe++
                $problems.Add("$($f.FullName.Substring($root.Length + 1)) is an installer file outside Display.Driver and $why.")
            }
        }
        if ($installerPe.Count -gt 0 -and $badPe -eq 0) {
            $notes.Add("$($installerPe.Count) installer binaries outside Display.Driver (setup.exe, NVI2, other components) carry a valid NVIDIA/Microsoft signature.")
        }
        # What NO signature covers, said plainly rather than implied away: the installer manifests.
        # NVIDIA does not sign setup.cfg or the .nvi files, and they tell setup.exe what to run. In a
        # download they are covered by the .exe's own signature; in a folder nothing vouches for them.
        $manifests = @($all | Where-Object { $_.Extension -eq '.nvi' -or $_.Name -eq 'setup.cfg' })
        if ($manifests.Count -gt 0) {
            $notes.Add("NOT verifiable: $($manifests.Count) installer manifest(s) (setup.cfg, *.nvi). NVIDIA does not sign them and they direct what setup.exe runs - a folder source is only as trustworthy as where it came from. The original .exe download is covered end to end.")
        }
    }
    return [PSCustomObject]@{ Ok = ($problems.Count -eq 0); Problems = $problems; Notes = $notes }
}
