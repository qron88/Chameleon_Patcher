<#
.SYNOPSIS
  Regenerates the driver catalog (NV_DISP.CAT) for a patched Display.Driver folder and signs it
  with your local code-signing certificate.

.DESCRIPTION
  Any edit to the INFs invalidates NVIDIA's original signature on the catalog (the hashes no longer
  match), so it must be rebuilt from the modified files and re-signed:
    - Inf2Cat.exe  -> rebuilds the catalog(s) from the current INF + binary contents
    - signtool.exe -> Authenticode-signs them with your certificate, always from the store
                      (`signtool /sha1 <thumbprint>`), so no password ever reaches a command line

  THE KEY. -CertThumbprint names a certificate in Cert:\CurrentUser\My. Without it the same
  resolution as the pipeline runs (a .cer whose key is in the store, then a store search by
  subject). -PfxPath + -PfxPassword imports the .pfx into Cert:\CurrentUser\My once (key
  non-exportable) and then signs from the store like everything else - signtool's own /f /p route
  is not used, because it puts the password on signtool's command line.

  WHICH CATALOGS. The catalogs signed are the ones the INFs in the folder declare (CatalogFile=),
  which is the real INF-to-catalog pairing. A .cat that no INF declares - a leftover of a pruned OEM
  INF - is reported and left alone. After signing, every INF is checked to be a member of the
  catalog it declares, and every declared catalog to carry your signature.

  Timestamping is best-effort: if the timestamp server is unreachable the catalog is signed WITHOUT
  a timestamp and a warning is printed, rather than failing the run.

  This script does NOT modify any system trust store or enable Windows Test Mode.

.PARAMETER DisplayDriverPath
  Path to the patched Display.Driver folder.

.PARAMETER CertThumbprint
  Thumbprint of a code-signing certificate in Cert:\CurrentUser\My.

.PARAMETER PfxPath
  A .pfx to import into Cert:\CurrentUser\My and sign with (needs -PfxPassword, or a prompt).

.PARAMETER SkipTimestamp
  Don't contact the timestamp server at all. Makes signing fully offline-capable.

.PARAMETER NonInteractive
  Never prompt. A .pfx without a password then fails with a clear message instead of blocking on
  Read-Host (which cannot be answered when there is no attached console, e.g. from the GUI).

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

if (-not (Test-Path -LiteralPath $DisplayDriverPath)) { throw "Path not found: $DisplayDriverPath" }
$DisplayDriverPath = (Resolve-Path -LiteralPath $DisplayDriverPath).Path

$inf2cat  = Find-WdkTool -ExeName "Inf2Cat.exe"  -ExplicitPath $Inf2CatPath
$signtool = Find-WdkTool -ExeName "signtool.exe" -ExplicitPath $SignToolPath

Write-Host "Using Inf2Cat:  $inf2cat"
Write-Host "Using signtool: $signtool"

# --- Decide which certificate signs, BEFORE doing any expensive work ----------------------------
$storeCert = $null
if ($PfxPath -and -not $CertThumbprint) {
    if (-not (Test-Path -LiteralPath $PfxPath)) { throw "Pfx not found: $PfxPath" }
    if (-not $PfxPassword) {
        if ($NonInteractive) {
            throw "A .pfx was given, so its password is required to import it - but none was supplied and prompting is disabled. Supply the password, or import the .pfx once yourself (Import-PfxCertificate -FilePath `"$PfxPath`" -CertStoreLocation Cert:\CurrentUser\My) and re-run without -PfxPath."
        }
        $PfxPassword = Read-Host -AsSecureString -Prompt "Password for $PfxPath"
    }
    $storeCert = Import-SigningPfx -PfxPath $PfxPath -Password $PfxPassword
}
else {
    $cerCandidates = Get-SigningCerCandidates -CertificatesDir (Join-Path (Split-Path $PSScriptRoot -Parent) "Certificates")
    $storeCert = Resolve-SigningCertificate -Thumbprint $CertThumbprint -CerPathCandidates $cerCandidates -SearchStore
}
if (-not $storeCert) {
    throw "No signing identity available. Pass -CertThumbprint (a cert in Cert:\CurrentUser\My), or -PfxPath with its password."
}
$expectedThumbprint = $storeCert.Thumbprint
Write-Host "Signing from the certificate store - no password on any command line." -ForegroundColor Green
Write-Host "  Subject:    $($storeCert.Subject)"
Write-Host "  Thumbprint: $($storeCert.Thumbprint)"
Write-Host "  Expires:    $($storeCert.NotAfter)"

# --- Rebuild the catalog ----------------------------------------------------------------------
$declared = Get-InfDeclaredCatalog -Folder $DisplayDriverPath
if ($declared.Count -eq 0) { throw "No INF in $DisplayDriverPath declares a catalog (CatalogFile=) - nothing to sign." }

Write-Host "`nRebuilding catalog from patched INFs..." -ForegroundColor Cyan
$inf2catExit = Invoke-NativeTool -FilePath $inf2cat -Arguments @("/driver:$DisplayDriverPath", "/os:$OSList", "/verbose")
if ($inf2catExit -ne 0) {
    throw "Inf2Cat failed with exit code $inf2catExit. Check the driver folder for INF errors."
}

$toSign = @()
foreach ($name in @($declared.Keys | Sort-Object)) {
    $p = Join-Path $DisplayDriverPath $name
    if (-not (Test-Path -LiteralPath $p)) {
        throw "$name is declared by $($declared[$name].Count) INF(s) ($(@($declared[$name])[0..2] -join ', ')...) but Inf2Cat did not produce it."
    }
    $toSign += Get-Item -LiteralPath $p
}
$undeclared = @(Get-ChildItem -LiteralPath $DisplayDriverPath -Filter *.cat -File | Where-Object { -not $declared.ContainsKey($_.Name) })
if ($undeclared.Count) {
    Write-Warning ("Not signing, because no INF in the folder declares them: " + (($undeclared | ForEach-Object { $_.Name }) -join ', ') + ". Usually the catalog of an OEM INF a pruned build removed; nothing installs from it.")
}

# --- Sign each declared catalog ---------------------------------------------------------------
function Get-SignArguments {
    param([string]$CatPath, [bool]$WithTimestamp)
    $a = @('sign', '/sha1', $expectedThumbprint, '/fd', 'SHA256')
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
        if ($exit -eq 0) { $timestamped = $true }
        else { Write-Warning "Signing with a timestamp failed (exit $exit) - most likely the timestamp server is unreachable. Retrying without a timestamp." }
    }
    if (-not $timestamped) {
        $exit = Invoke-NativeTool -FilePath $signtool -Arguments (Get-SignArguments -CatPath $cat.FullName -WithTimestamp $false)
        if ($exit -ne 0) { throw "signtool failed with exit code $exit on $($cat.Name)." }
        if (-not $SkipTimestamp) {
            Write-Warning "$($cat.Name) is signed but NOT timestamped. That is fine for local use - an un-timestamped signature simply stops validating once the signing certificate itself expires."
        }
    }

    $sig = Get-AuthenticodeSignature -LiteralPath $cat.FullName
    if (-not ($sig.SignerCertificate -and $sig.SignerCertificate.Thumbprint -eq $expectedThumbprint)) {
        throw "$($cat.Name) was not actually signed with the expected certificate - something went wrong."
    }
    $tsNote = if ($sig.TimeStamperCertificate) { "timestamped" } else { "no timestamp" }
    Write-Host "Confirmed: $($cat.Name) carries your signature ($tsNote). Windows trusts it only once the certificate is trusted - see README.md." -ForegroundColor Green
}

# --- Coverage: every INF is in the catalog it declares ----------------------------------------
# The signature check above says WHO signed; this says WHAT was signed. Inf2Cat exits 0 in cases
# where it did not hash every INF (a filtered /os list, an INF with no decoration for these OS
# targets), and a patched INF outside the catalog is refused at install time.
$notCovered = @()
foreach ($name in $declared.Keys) {
    $infs = @($declared[$name] | ForEach-Object { Join-Path $DisplayDriverPath $_ })
    foreach ($m in @(Get-CatalogNonMember -CatalogPath (Join-Path $DisplayDriverPath $name) -Path $infs)) {
        $notCovered += "$(Split-Path $m -Leaf) (declares $name)"
    }
}
if ($notCovered.Count) {
    throw "These INFs are not members of the catalog they declare, so Windows would refuse them: $($notCovered -join ', ')."
}
$infCount = @($declared.Values | ForEach-Object { $_ }).Count
Write-Host "`nDone. $($toSign.Count) catalog(s) rebuilt and signed; all $infCount INF(s) are members of the catalog they declare." -ForegroundColor Green
