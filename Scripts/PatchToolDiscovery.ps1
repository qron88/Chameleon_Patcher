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
    Write-TextFileAtomic      - temp file + File.Replace, so a killed run never leaves half a file
    Get-SystemToolPath        - full System32 path of certutil/bcdedit, never a PATH lookup
    Test-ProjectSigningCertificate - is a certificate one this toolkit mints (self-signed, Code
                                Signing, not a CA, project subject); gates cleanup and trust
    Import-SigningPfx         - bring a .pfx into Cert:\CurrentUser\My so signing never needs /p
    Get-CatalogNonMember / Get-InfDeclaredCatalog - catalog membership (wintrust) and the INF to
                                catalog pairing the INFs themselves declare
    Test-DriverSource         - is the input NVIDIA's: signed .exe, or a folder its catalog covers
    Get-InfSectionBody / Merge-InfTemplateWithDonor - bring a captured section template up to date
                                with the closest stock install section of the release being patched
    Test-InfRmOverrideLine    - the RM1457588 directive, as patcher and gate both test for it

  The functions live in Scripts\Lib\, one file per subject (Tools, Package, Inf, Hardware,
  Certificates, Source). This file is the single entry point and only loads them, in a fixed,
  explicit order - not by wildcard, so a stray .ps1 dropped into Lib\ is never executed.

  Resolution is memoized for the lifetime of the dot-sourcing script and re-validated with
  Test-Path on each hit, so an SDK that is updated or removed mid-run cannot leave a stale
  path behind. Paths are deliberately NOT persisted between runs for that same reason.
#>

# $PSScriptRoot here is this file's own folder even when it is dot-sourced, so the parts are found
# wherever Scripts\ was unpacked. Dot-sourcing from a dot-sourced file adds no scope: every function
# and every $script: variable lands in the caller's script scope, exactly as when this was one file.
foreach ($part in @('Tools', 'Package', 'Inf', 'Hardware', 'Certificates', 'Source')) {
    . (Join-Path (Join-Path $PSScriptRoot 'Lib') ($part + '.ps1'))
}
