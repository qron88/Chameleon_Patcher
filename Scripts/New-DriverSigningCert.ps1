<#
.SYNOPSIS
  Creates a self-signed code-signing certificate for signing the patched NVIDIA driver catalog.

.DESCRIPTION
  This does NOT touch your system trust stores. It only creates a cert+key in your personal
  certificate store (Cert:\CurrentUser\My) and exports the public .cer so you can review/trust it
  deliberately. Trusting it is a separate, explicit step you run yourself - see the README.

  The private key is created NON-EXPORTABLE by default. Signing reads the key straight out of your
  certificate store, so nothing in this toolkit needs a .pfx, and a key that cannot be exported
  cannot be copied off this machine by anything that later gets hold of your user account. It also
  means there is no .pfx password to invent, protect, or type - not here, and not on any later
  driver release.

  Pass -Exportable if you specifically want a portable .pfx backup, e.g. to sign on a second
  machine. That re-introduces a password and a file holding your private key, so only do it if you
  actually need it.

.PARAMETER Subject
  Certificate subject/common name. This is the name Windows shows in its certificate UI, in
  signtool output, and as the publisher on the "Would you like to install this device software?"
  prompt, so it should read as an obviously local, self-issued certificate. The default names the
  project and describes what it is; it deliberately does not pass itself off as NVIDIA, and does
  not reuse the old "FrankenDriver" name either.

  Changing this only affects certificates created from now on. A certificate's subject is bound
  into the signed structure and cannot be edited afterwards, so an existing certificate keeps the
  name it was born with - see the README section on renaming.

.PARAMETER OutputDir
  Where to write the exported .cer (and .pfx, if -Exportable). Defaults to the "Certificates"
  folder next to "Scripts" (created automatically if it doesn't exist yet).

.PARAMETER ValidityYears
  How long the certificate stays valid. Defaults to 3 years rather than 10: this certificate
  becomes a machine-wide trusted root once you trust it, and that is a long time to leave a
  self-signed signing authority in place. Catalogs already signed and timestamped keep validating
  after the certificate expires, so a shorter life costs you nothing except re-running this and
  the trust step every few years.

.PARAMETER Exportable
  Also export a password-protected .pfx, and allow the private key to be exported. Off by default.

.PARAMETER PfxPassword
  Only used with -Exportable. Prompted for if omitted.

.PARAMETER Force
  Mint the certificate even though a valid one with exactly this subject is already in
  Cert:\CurrentUser\My. Normally a duplicate subject means the same thing was run twice by mistake,
  and the two certificates are impossible to tell apart in every UI that shows them, so the run
  stops and says so instead. An expired namesake does not need this switch - minting the next
  certificate is the right answer there, and the script says so. See the note about duplicates below.
#>
[CmdletBinding()]
param(
    [string]$Subject = "CN=Chameleon Project - Customised driver for Nvidia GPU",
    [string]$OutputDir,
    [int]$ValidityYears = 3,
    [switch]$Exportable,
    [securestring]$PfxPassword,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Dot-sourced for one thing: Test-DriverPatchSubject, which answers with the patterns the pipeline
# itself uses to recognise a project certificate. That is the only way this script can tell whether
# a certificate it is about to create will be findable afterwards.
. (Join-Path $PSScriptRoot 'PatchToolDiscovery.ps1')

# $PSScriptRoot is unreliable inside a param() default value when this script is launched as a
# fresh process (powershell.exe -File ..., e.g. double-clicked or run via "Run with PowerShell")
# - confirmed empty there even though it's reliably set by this point in the script body.
if (-not $OutputDir) {
    $OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) "Certificates"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$keyPolicy = if ($Exportable) { 'Exportable' } else { 'NonExportable' }

# A certificate's subject is the only part of it a person ever sees. Minting a second one under the
# same subject puts two entries in Cert:\CurrentUser\My that no UI can tell apart, and from then on
# "the certificate" means whichever one each step happens to pick: signing, trusting and
# Remove-OldDriverPatchCerts all choose between them by thumbprint, so it is entirely possible to
# trust one and sign with the other and then never see why the driver is refused. Starting over is a
# legitimate thing to want, so this stops with instructions instead of deciding for you.
#
# Only a certificate that is still VALID counts as a duplicate. The pipeline reaches this script
# precisely because Resolve-SigningCertificate found no usable key, and the everyday reason nothing
# was usable is that the certificate it found had expired. Refusing to mint in that case would turn
# "the certificate aged out, make the next one" into an error telling you to go delete things, so an
# expired namesake is reported as clutter instead of treated as a conflict.
$now = Get-Date
$duplicates = @(Get-ChildItem "Cert:\CurrentUser\My" | Where-Object { $_.Subject -eq $Subject })
$liveDuplicates = @($duplicates | Where-Object { $_.NotAfter -gt $now })
$expiredDuplicates = @($duplicates | Where-Object { $_.NotAfter -le $now })
if ($expiredDuplicates.Count) {
    $stale = ($expiredDuplicates | ForEach-Object { $_.Thumbprint + " (expired " + $_.NotAfter + ")" }) -join '; '
    Write-Warning "Certificates with this subject are in Cert:\CurrentUser\My but are no longer valid, so a new one is being created: $stale. Remove-DriverPatchCert.ps1 inventories them."
}
if ($liveDuplicates.Count -and -not $Force) {
    $seen = ($liveDuplicates | ForEach-Object { $_.Thumbprint + " (expires " + $_.NotAfter + ")" }) -join '; '
    throw "A valid certificate with this subject is already in Cert:\CurrentUser\My: $seen. Nothing needs to be created to sign with it - Sign-DriverPackage.ps1 -CertThumbprint <thumbprint> uses it as it is. Remove that certificate first if you want a clean start, or re-run with -Force to have a second one under the same name."
}

if (-not (Test-DriverPatchSubject -Subject $Subject)) {
    # The pipeline recognises a project certificate by its subject, and so does the certificate
    # cleanup, both through the same patterns. A subject outside them is invisible to both: the next
    # run will not find this certificate, will mint a fresh one under the default name, and the
    # certificate you trusted and the certificate that signs the catalog will be different ones.
    # Worth saying now; not worth refusing a deliberately custom subject over.
    Write-Warning "The subject ""$Subject"" matches none of the patterns this toolkit recognises a project certificate by ($($script:DriverPatchSubjectPatterns -join ', ')). A pipeline run will not pick this certificate up on its own - pass its thumbprint to Sign-DriverPackage.ps1 explicitly, or use the default subject."
}

$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $Subject `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyUsage DigitalSignature `
    -KeyExportPolicy $keyPolicy `
    -NotAfter (Get-Date).AddYears($ValidityYears) `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")   # Extended Key Usage: Code Signing

# Named with the thumbprint so every minted certificate has its own unambiguous public file.
# The legacy fixed name DriverPatchSigning.cer is no longer written here: overwriting it on
# every run meant minting a new certificate silently re-pointed the file away from the one you
# had trusted. An existing DriverPatchSigning.cer from an older version keeps working - the
# pipeline and Approve-DriverPatchCert.ps1 both check the thumbprint-named files first and fall
# back to the legacy name.
$cerPath = Join-Path $OutputDir ("DriverPatchSigning_" + $cert.Thumbprint + ".cer")
if (Test-Path -LiteralPath $cerPath) {
    # Two different certificates cannot share a thumbprint, so this file can only be the export of
    # this exact certificate from an earlier run - one that may already be trusted machine-wide.
    throw "$cerPath already exists, which means a certificate with this thumbprint was exported before. Refusing to rewrite a public certificate you may already have trusted; delete the file if you mean to write it again."
}
Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

Write-Host "Created certificate: $($cert.Subject)" -ForegroundColor Green
Write-Host "  Thumbprint: $($cert.Thumbprint)"
Write-Host "  Expires:    $($cert.NotAfter)"
Write-Host "  Private key: in Cert:\CurrentUser\My, $keyPolicy"
Write-Host "  Public cert exported to: $cerPath"

if ($Exportable) {
    if (-not $PfxPassword) {
        $PfxPassword = Read-Host -AsSecureString -Prompt "Set a password to protect the exported .pfx private key"
    }
    # Thumbprint-named for the same reason as the .cer, and here it matters more: this file holds the
    # private key, and one fixed name meant that a second run replaced the key behind every catalog
    # already signed with the first certificate, without telling anyone. An existing
    # DriverPatchSigning.pfx left over from an older version still signs fine - signing uses whichever
    # .pfx it is pointed at - it is simply no longer written to.
    $pfxPath = Join-Path $OutputDir ("DriverPatchSigning_" + $cert.Thumbprint + ".pfx")
    if (Test-Path -LiteralPath $pfxPath) {
        throw "$pfxPath already exists; not overwriting a file that holds a private key. Delete it yourself if you mean to replace it."
    }
    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $PfxPassword | Out-Null
    Write-Host "  Private key (.pfx) exported to: $pfxPath" -ForegroundColor Yellow
    Write-Host "  Keep that file private - anyone holding it can sign drivers your machine trusts." -ForegroundColor Yellow
}
else {
    Write-Host "  No .pfx written - the key is non-exportable and signing reads it from the store." -ForegroundColor DarkGray
    Write-Host "  (Re-run with -Exportable if you need a portable backup for another machine.)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "This certificate is NOT trusted by Windows yet. To make a driver signed with it" -ForegroundColor Yellow
Write-Host "installable, YOU must explicitly add it to the trust stores yourself (see README.md)." -ForegroundColor Yellow
Write-Host ""
Write-Host "Signing needs no password on this machine:" -ForegroundColor DarkGray
Write-Host "  Sign-DriverPackage.ps1 -CertThumbprint $($cert.Thumbprint)" -ForegroundColor DarkGray

# Sole pipeline output: the thumbprint. Invoke-DriverPatchPipeline.ps1 captures this so it can
# sign from the certificate store. Everything above is Write-Host (host stream) precisely so this
# stays the only thing on the success output stream.
Write-Output $cert.Thumbprint
