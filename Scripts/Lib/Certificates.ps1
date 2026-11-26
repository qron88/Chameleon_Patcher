# The signing certificate: finding it, importing a .pfx, recognising a project
# certificate, and pruning old keys from Cert:\CurrentUser\My.
#
# Part of the shared helper library. Do not dot-source this file on its own: load
# Scripts\PatchToolDiscovery.ps1, which loads every part in a fixed order.

# Every subject name this project has ever issued signing certificates under: '*Chameleon*' is the
# current name, '*Driver Patch*' the previous one, '*FrankenDriver*' the hand-patched package this
# was reverse-engineered from. Shared by the store search in Resolve-SigningCertificate and by
# Remove-OldDriverPatchCerts, and must match Remove-DriverPatchCert.ps1's -SubjectPattern default.
# Add to this list rather than replacing it, or an old certificate becomes invisible to both.
$script:DriverPatchSubjectPatterns = @('*Chameleon*', '*Driver Patch*', '*FrankenDriver*')

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

function Import-SigningPfx {
    <#
       Put a .pfx's certificate and key into Cert:\CurrentUser\My (non-exportable) and return the store
       certificate, so signing can always use `signtool /sha1` from the store.

       signtool has no way to read a .pfx password except from its own command line (/p), where every
       process listing can read it for the length of the call. Importing once removes that route
       entirely: the password is used here, in-process, and never again. If the key is already in the
       store, nothing is imported.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PfxPath,
        [Parameter(Mandatory = $true)][securestring]$Password
    )
    try {
        $probe = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $PfxPath, $Password,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    }
    catch {
        throw "Could not open $PfxPath with the supplied password - check the password and try again. ($($_.Exception.Message))"
    }
    $tp = $probe.Thumbprint
    $probe.Dispose()

    $inStore = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $tp -and $_.HasPrivateKey } | Select-Object -First 1
    if ($inStore) { return $inStore }

    Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation Cert:\CurrentUser\My -Password $Password | Out-Null
    $imported = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $tp -and $_.HasPrivateKey } | Select-Object -First 1
    if (-not $imported) { throw "Imported $PfxPath, but its key is not usable from Cert:\CurrentUser\My." }
    Write-Host "  Imported $(Split-Path $PfxPath -Leaf) into Cert:\CurrentUser\My ($tp, key non-exportable) - later runs need no password." -ForegroundColor Yellow
    return $imported
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
        # Not a subject substring alone: this runs unattended on every pipeline run, so it only ever
        # touches a self-signed code-signing certificate shaped like the ones this toolkit mints. An
        # unrelated certificate that merely has "Chameleon" in its name is left alone and reported.
        if (-not (Test-DriverPatchSubject $c.Subject)) { continue }
        $why = Test-ProjectSigningCertificate -Certificate $c
        if ($why) {
            Write-Host ("  Left alone: " + $c.Thumbprint + " (" + $c.Subject + ") - " + $why + ".") -ForegroundColor DarkGray
            continue
        }
        $toRemove += $c
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

# --- Certificate identity --------------------------------------------------------------------------
function Test-ProjectSigningCertificate {
    <#
       Is this certificate one this toolkit could have minted: self-signed (subject = issuer), a
       Code Signing EKU, not a CA, and a subject in the project's patterns. Anything that fails this
       is not ours to delete from a store or to trust as a driver-patch certificate - a subject
       substring alone also matches an unrelated certificate that merely contains "Chameleon".
       Returns $null when it qualifies, otherwise the reason it does not.
    #>
    param([Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    if (-not (Test-DriverPatchSubject $Certificate.Subject)) { return "its subject matches none of $($script:DriverPatchSubjectPatterns -join ', ')" }
    if ($Certificate.Subject -ne $Certificate.Issuer) { return "it is not self-signed (issued by $($Certificate.Issuer))" }
    $eku = @($Certificate.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
        ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
    if ($eku -notcontains '1.3.6.1.5.5.7.3.3') { return "it has no Code Signing EKU" }
    $bc = @($Certificate.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] })
    if ($bc.Count -gt 0 -and $bc[0].CertificateAuthority) { return "it is a certificate authority (Basic Constraints CA=true)" }
    return $null
}
