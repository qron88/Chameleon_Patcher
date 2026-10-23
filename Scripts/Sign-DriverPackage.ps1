<#
.SYNOPSIS
  Regenerates the driver catalog (nv_disp.cat) for a patched Display.Driver folder and signs it
  with your local code-signing certificate.

.DESCRIPTION
  Any edit to the INFs invalidates NVIDIA's original signature on nv_disp.cat (the hashes no longer
  match), so the catalog must be rebuilt from the modified files and re-signed. This uses the
  Windows Driver Kit tools:
    - Inf2Cat.exe  -> rebuilds the .cat from the current INF + binary contents
    - signtool.exe -> Authenticode-signs the rebuilt .cat with your certificate

  TWO WAYS TO SUPPLY THE KEY, in order of preference:

    1. -CertThumbprint  (preferred, and passwordless)
       Signs with `signtool /sha1 <thumbprint>`, taking the private key straight from
       Cert:\CurrentUser\My. New-SelfSignedCertificate always leaves the key in that store, so on
       the machine that generated the cert there is NO password to type and NO .pfx to unlock -
       not on the first run, and not on any future driver release. Nothing sensitive touches a
       command line, an environment variable, or a log line.

    2. -PfxPath + -PfxPassword  (fallback, for a machine that has the .pfx but not the key in its
       store)
       Signs with `signtool /f <pfx> /p <password>`. signtool has no way to read a .pfx password
       from stdin, so this mode unavoidably puts the password on a child process's command line,
       where any process listing can see it. Prefer mode 1, or run
       `Import-PfxCertificate -CertStoreLocation Cert:\CurrentUser\My` once and then use mode 1
       forever after.

  Timestamping is best-effort. It is attempted first, and if the timestamp server is unreachable
  the catalog is signed WITHOUT a timestamp and a warning is printed, rather than failing the run.
  An un-timestamped signature stops validating once the signing certificate itself expires, which
  for a local 3-year test-signing cert is not a practical concern.

  ONE CATALOG PER INF, AND ONLY FOR THE INFs THAT ARE STILL THERE. A driver folder holds one .cat per
  INF, and a folder that has been patched or pruned more than once also holds catalogs whose INF is
  long gone, because Inf2Cat writes catalogs for the INFs it finds and never deletes anything. Those
  leftovers are reported and left unsigned: signing a catalog for files the current INFs no longer
  name is how a package ends up installing things nothing declares. A catalog whose INF is still in
  the folder is signed even if Inf2Cat did not rewrite it, since something in the package wants it,
  but with a warning that Inf2Cat did not confirm what it covers.

  This script does NOT modify any system trust store or enable Windows Test Mode - see README.md
  for the (separate, explicit) steps required for Windows to actually trust the result.

.PARAMETER DisplayDriverPath
  Path to the patched Display.Driver folder (containing nv_dispi.inf, nv_disp.cat, etc.)

.PARAMETER CertThumbprint
  Thumbprint of a code-signing certificate in Cert:\CurrentUser\My. Passwordless - preferred.

.PARAMETER PfxPath
  Fallback: path to the signing certificate's .pfx. Only needed when the private key is not
  already in this machine's certificate store.

.PARAMETER SkipTimestamp
  Don't even attempt to contact the timestamp server. Makes signing fully offline-capable.

.PARAMETER NonInteractive
  Never prompt. If a password would be required and none was supplied, throw a clear error
  instead of blocking on Read-Host (which cannot be answered when there is no attached console,
  e.g. when launched from the GUI).

.PARAMETER OSList
  Comma-separated OS targets for Inf2Cat. Defaults to 64-bit Win10/Win11.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DisplayDriverPath,

    [string]$CertThumbprint,

    [string]$PfxPath,

    [securestring]$PfxPassword,

    [string]$OSList = "10_X64,Server10_X64,10_NI_X64,10_CO_X64,10_RS3_X64",

    [string]$TimestampUrl = "http://timestamp.digicert.com",

    [switch]$SkipTimestamp,

    [switch]$NonInteractive,

    [string]$SignToolPath,

    [string]$Inf2CatPath
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

if (-not (Test-Path $DisplayDriverPath)) { throw "Path not found: $DisplayDriverPath" }

$inf2cat  = Find-WdkTool -ExeName "Inf2Cat.exe"  -ExplicitPath $Inf2CatPath
$signtool = Find-WdkTool -ExeName "signtool.exe" -ExplicitPath $SignToolPath

Write-Host "Using Inf2Cat:  $inf2cat"
Write-Host "Using signtool: $signtool"

# --- Decide how we're going to sign, BEFORE doing any expensive work ---------------------------
# Preference: a key already in Cert:\CurrentUser\My (no password anywhere). If the caller passed
# only a .pfx, still try to find its key in the store first - same certificate, but signing from
# the store means the password isn't needed at all.
# Same candidate order and store search as the pipeline, so running this script standalone with no
# certificate arguments at all signs with the same certificate the pipeline would pick.
$cerCandidates = Get-SigningCerCandidates -CertificatesDir (Join-Path (Split-Path $PSScriptRoot -Parent) "Certificates") -PfxPath $PfxPath
$storeCert = Resolve-SigningCertificate -Thumbprint $CertThumbprint -CerPathCandidates $cerCandidates -SearchStore:(-not $PfxPath)

$plainPwd = $null
$pwdPtr   = [IntPtr]::Zero
$expectedThumbprint = $null

if ($storeCert) {
    $expectedThumbprint = $storeCert.Thumbprint
    Write-Host "Signing from the certificate store - no password needed." -ForegroundColor Green
    Write-Host "  Subject:    $($storeCert.Subject)"
    Write-Host "  Thumbprint: $($storeCert.Thumbprint)"
    Write-Host "  Expires:    $($storeCert.NotAfter)"
}
else {
    if (-not $PfxPath) {
        throw "No signing identity available. Pass -CertThumbprint (a cert in Cert:\CurrentUser\My), or -PfxPath with its password."
    }
    if (-not (Test-Path $PfxPath)) { throw "Pfx not found: $PfxPath" }
    if (-not $PfxPassword) {
        if ($NonInteractive) {
            throw "This certificate's private key isn't in Cert:\CurrentUser\My, so the .pfx password is required, but none was supplied and prompting is disabled. Either import the .pfx into the store once (Import-PfxCertificate -FilePath `"$PfxPath`" -CertStoreLocation Cert:\CurrentUser\My) and re-run, or supply the password."
        }
        $PfxPassword = Read-Host -AsSecureString -Prompt "Password for $PfxPath"
    }
    Write-Warning "Signing from a .pfx file. signtool cannot read a .pfx password from stdin, so the password will be visible on signtool's command line for the duration of the call. Importing this .pfx into Cert:\CurrentUser\My once would avoid that permanently."

    # Load the cert once, up front, purely to learn the thumbprint we expect to see on the
    # finished signature. EphemeralKeySet keeps the private key in memory instead of persisting
    # it into the user's on-disk key container as a side effect of this check.
    try {
        $probe = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $PfxPath, $PfxPassword,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    }
    catch {
        throw "Could not open $PfxPath with the supplied password: $($_.Exception.Message)"
    }
    $expectedThumbprint = $probe.Thumbprint
    $probe.Dispose()

    $pwdPtr   = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($PfxPassword)
    $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($pwdPtr)
}

try {
    # --- Rebuild the catalog ------------------------------------------------------------------
    Write-Host "`nRebuilding catalog from patched INFs..." -ForegroundColor Cyan
    # Snapshot the catalogs that are already in the folder before Inf2Cat runs. Inf2Cat writes one
    # .cat for every INF it certifies and leaves the rest of the folder alone, so once it is done a
    # catalog that is new or whose timestamp moved is one that describes the INFs as they now are,
    # while a catalog whose timestamp did not move describes something Inf2Cat never looked at -
    # usually the leftover of an INF a previous run pruned away, or of an older driver that lived in
    # this folder. Signing those anyway makes a green run out of a package that still carries a
    # catalog for files its INFs no longer name.
    $catBefore = @{}
    foreach ($c in @(Get-ChildItem -Path $DisplayDriverPath -Filter '*.cat')) { $catBefore[$c.Name] = $c.LastWriteTimeUtc }

    $inf2catExit = Invoke-NativeTool -FilePath $inf2cat -Arguments @("/driver:$DisplayDriverPath", "/os:$OSList", "/verbose")
    if ($inf2catExit -ne 0) {
        throw "Inf2Cat failed with exit code $inf2catExit. Check the driver folder for INF errors."
    }

    $catFiles = @(Get-ChildItem -Path $DisplayDriverPath -Filter "*.cat")
    if (-not $catFiles) { throw "No .cat file was produced by Inf2Cat." }

    $refreshed = @($catFiles | Where-Object { (-not $catBefore.ContainsKey($_.Name)) -or ($_.LastWriteTimeUtc -ne $catBefore[$_.Name]) })
    if (-not $refreshed.Count) {
        # Possible when the same package is signed twice without an INF edit in between. Signing them
        # again is idempotent, and refusing to sign anything here would be the louder wrong answer.
        Write-Warning "Inf2Cat reported success but rewrote no .cat file - each catalog already matched its INF. Signing every catalog in the folder again."
        $refreshed = $catFiles
    }
    $untouched = @($catFiles | Where-Object { $refreshed -notcontains $_ })
    $stale = @(); $leftover = @()
    foreach ($cat in $untouched) {
        # An INF of the same name is still in the folder, so something in this package really does
        # want this catalog, even though Inf2Cat did not regenerate it. Leave it in the signing list
        # and say what is odd about it; a catalog that is not signed at all is worse than one whose
        # freshness is doubtful.
        if (Test-Path (Join-Path $DisplayDriverPath ([System.IO.Path]::GetFileNameWithoutExtension($cat.Name) + '.inf'))) { $stale += $cat }
        else { $leftover += $cat }
    }
    if ($stale.Count) {
        Write-Warning ("Inf2Cat did not rewrite these catalogs even though an INF of the same name is in the folder: " + (($stale | ForEach-Object { $_.Name }) -join ', ') + ". They are signed anyway, but a catalog Inf2Cat did not regenerate does not necessarily cover the INF that was just patched.")
    }
    if ($leftover.Count) {
        Write-Warning ("Not signing, because no INF in $DisplayDriverPath names them and Inf2Cat did not touch them: " + (($leftover | ForEach-Object { "$($_.Name) (last written $($_.LastWriteTime))" }) -join ', ') + ". A catalog outlives the INF it was built for when a package is pruned or reused, and signing it would only dress the leftover up as current.")
    }

    # --- Sign each catalog produced -----------------------------------------------------------
    $toSign = @($refreshed + $stale)
    if ($leftover.Count) {
        Write-Host ("Signing $($toSign.Count) of $($catFiles.Count) .cat file(s) in the folder; $($leftover.Count) left unsigned as leftovers of INFs that are no longer here.") -ForegroundColor Yellow
    }
    function Get-SignArguments {
        param([string]$CatPath, [bool]$WithTimestamp)
        $a = @('sign')
        if ($storeCert) {
            $a += @('/sha1', $expectedThumbprint)
        }
        else {
            $a += @('/f', $PfxPath, '/p', $plainPwd)
        }
        $a += @('/fd', 'SHA256')
        if ($WithTimestamp) { $a += @('/tr', $TimestampUrl, '/td', 'SHA256') }
        $a += $CatPath
        return $a
    }

    foreach ($cat in $toSign) {
        Write-Host "`nSigning $($cat.Name)..." -ForegroundColor Cyan

        $timestamped = $false
        $exit = 1

        if (-not $SkipTimestamp) {
            $exit = Invoke-NativeTool -FilePath $signtool -Arguments (Get-SignArguments -CatPath $cat.FullName -WithTimestamp $true)
            if ($exit -eq 0) {
                $timestamped = $true
            }
            else {
                Write-Warning "Signing with a timestamp failed (exit $exit) - most likely the timestamp server is unreachable. Retrying without a timestamp."
            }
        }

        if (-not $timestamped) {
            $exit = Invoke-NativeTool -FilePath $signtool -Arguments (Get-SignArguments -CatPath $cat.FullName -WithTimestamp $false)
            if ($exit -ne 0) {
                throw "signtool failed with exit code $exit on $($cat.Name)."
            }
            if (-not $SkipTimestamp) {
                Write-Warning "$($cat.Name) is signed but NOT timestamped. That is fine for local use - an un-timestamped signature simply stops validating once the signing certificate itself expires."
            }
        }

        Write-Host "Verifying signature is present (chain-of-trust check is expected to fail until you" -ForegroundColor Cyan
        Write-Host "complete the trust step in README.md - that's normal, not an error)..." -ForegroundColor Cyan
        # Informational only. Real success/failure is decided by the thumbprint comparison below;
        # `signtool verify /pa` applies full chain policy and so reports failure for an untrusted
        # self-signed root regardless of whether the catalog itself is correctly signed.
        Invoke-NativeTool -FilePath $signtool -Arguments @('verify', '/pa', '/v', $cat.FullName) | Out-Null

        $sig = Get-AuthenticodeSignature $cat.FullName
        if ($sig.SignerCertificate -and $sig.SignerCertificate.Thumbprint -eq $expectedThumbprint) {
            $tsNote = if ($sig.TimeStamperCertificate) { "timestamped" } else { "no timestamp" }
            Write-Host "Confirmed: $($cat.Name) carries a valid Authenticode signature from your certificate ($tsNote)." -ForegroundColor Green
        }
        else {
            throw "$($cat.Name) was not actually signed with the expected certificate - something went wrong."
        }
    }

    $skippedNote = if ($leftover.Count) { " $($leftover.Count) catalog(s) of INFs no longer in the folder were deliberately left unsigned." } else { "" }
    Write-Host "`nDone. $($toSign.Count) catalog(s) rebuilt and signed.$skippedNote" -ForegroundColor Green
    Write-Host "This signature only validates once the signing certificate is trusted by Windows -" -ForegroundColor Yellow
    Write-Host "see README.md for that step, which you should run yourself." -ForegroundColor Yellow
}
finally {
    # Zero and release the unmanaged plaintext buffer rather than just dropping the reference.
    if ($pwdPtr -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pwdPtr)
        $pwdPtr = [IntPtr]::Zero
    }
    $plainPwd = $null
}
