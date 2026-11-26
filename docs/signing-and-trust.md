# Signing and trust

How the patched catalog is signed, how the certificate becomes trusted, and how to take that trust away again. Part of the [Chameleon Patcher](../README.md) documentation.

## Signing

Signing always runs `signtool sign /sha1 <thumbprint> /fd SHA256 nv_disp.cat` against a key in
`Cert:\CurrentUser\My`. `New-SelfSignedCertificate` puts the private key there, not only in an exported
`.pfx`, so on the machine that minted the certificate there is **no password to type and no `.pfx` to
unlock** - on the first run and on every later driver release. That is the only route, and there is a
security reason for it, not only convenience: `signtool` cannot read a `.pfx` password from stdin, so
the `/f` + `/p` form would have to put it on a child process's command line, where any process listing
can read it. That route no longer exists; signing from the store means no password is on any command
line.

The certificate is resolved in this order:

1. `-CertThumbprint`, if you passed one.
2. The **public** `.cer` files in `Certificates\` - `DriverPatchSigning_<thumbprint>.cer` newest
   first, then the legacy fixed name - taking the first whose private key is in your store and has not
   expired. Reading a `.cer` needs no password.
3. A search of `Cert:\CurrentUser\My` for a project signing certificate with a private key and time left
   on it, preferring one already trusted in `LocalMachine\Root`, then the one expiring last. The missing
   `.cer` is re-exported. This is what stops a deleted `Certificates\` folder from costing you the key:
   without it the run would mint a new certificate, and the cleanup of old keys would delete the
   existing one - which cannot be recovered, because the key is non-exportable.
4. Only then a `.pfx` (with its password) or a newly minted certificate.

A certificate counts as a **project certificate** only if it is self-signed, has a Code Signing EKU, is
not a CA, and carries a project subject (`Test-ProjectSigningCertificate`). Passing `-PfxPath` skips
step 3, since you have said which key to use.

**On a machine that has only the `.pfx`**, the pipeline imports it once (`Import-SigningPfx`, key
non-exportable) and signs from the store from then on. You can do the same by hand:

```powershell
Import-PfxCertificate -FilePath "Certificates\DriverPatchSigning_<thumbprint>.pfx" -CertStoreLocation Cert:\CurrentUser\My
```

Exports are named after the certificate, so a folder can hold several `.pfx` files; the newest is what
the GUI offers when a run stops for lack of a key. A run that signed with an imported `.pfx` skips the
old-key cleanup, so a foreign key can never cost this PC its own key.

To check which certificate signed a package:

```powershell
Get-AuthenticodeSignature "<pkg>\Display.Driver\nv_disp.cat" | Select-Object -ExpandProperty SignerCertificate | Select-Object Thumbprint, Subject
```

`Add-SetupCertOption.ps1` enforces the match: its `-ExpectThumbprint` defaults to the certificate that
actually signed the package's `nv_disp*.cat`, and it throws on a mismatch.

**Timestamping is best-effort.** A timestamp is attempted first; an unreachable timestamp server
leaves the catalog signed with a warning instead of failing the run, and `-SkipTimestamp` skips the
attempt entirely (RFC 3161 over `http://` is normal - the response is itself signed). An un-timestamped
signature only loses validity past the signing certificate's own expiry, counted from when you **minted**
it. For a 3-year test-signing certificate used on the machine that made it, that is rarely a concern; it
becomes one when an older key is reused for a later release, or when `-ValidityYears` was raised.

**Catalogs are paired by `CatalogFile=`.** All display INFs declare `NV_DISP.CAT`; file names do not
carry the pairing. Only declared catalogs are signed, and after signing every INF must be a member of
its declared catalog. Catalogs of pruned OEM INFs stay on disk with NVIDIA's (now invalid) signature;
nothing declares them.

### The certificate itself

`New-DriverSigningCert.ps1` mints a **non-exportable** key (unless `-Exportable`), with a critical
Basic Constraints `CA=false`, Code Signing EKU only, and 3-year validity, so a certificate sitting in
`Root` cannot vouch for other certificates. It never overwrites a certificate you already trusted: the
`.cer` and `.pfx` are named after the thumbprint and neither is rewritten if it exists. Minting a second
**valid** certificate under a subject already in the store is refused - two certificates under one
subject are indistinguishable in every UI that shows them, and trusting one while signing with the
other gives a driver install Windows refuses for no visible reason - and the message names the
thumbprint to use instead, with `-Force` if a second one is really wanted. An expired namesake does not
block. A `-Subject` outside the patterns this toolkit uses to recognise a project certificate gets a
warning, because that certificate is invisible to the next run's resolution and to the cleanup alike.

The name Windows shows for the key is its subject, set at creation:

```
CN=Chameleon Project - Customised driver for Nvidia GPU
```

It appears in the certificate manager, in `signtool` output, and as the publisher on the
"Would you like to install this device software?" prompt. `-Subject` overrides it. A subject **cannot
be edited afterwards** - it is bound into the signed structure - so a new name means a new
certificate, with a new thumbprint, no trust yet (run `Approve-DriverPatchCert.ps1` again), and no
`.pfx` backup unless you pass `-Exportable`; packages signed earlier keep the old certificate and work
only while it stays trusted. Renaming is worth doing when you are minting anyway, and rarely worth
doing on its own. If you do rename, the subject patterns of `Remove-DriverPatchCert.ps1`
(`-SubjectPattern`, which already cover the current name plus two legacy names) must only ever
**grow**: **add** to that list, do not replace it, or a renamed certificate becomes invisible to the
tool meant to clean it up and quietly accumulates as an untracked trusted root.

## Trusting the certificate

Signing alone is not enough: Windows trusts kernel driver signatures that chain to a
**Microsoft-anchored** certificate (WHQL, or an EV cert cross-signed via the Hardware Dev Center)
*unless the machine is in Test Signing mode*, in which case it accepts any certificate you have
explicitly trusted locally. There is no "driver-only" trust store and `pnputil` does not establish
trust, so adding the certificate to `Root` is the cost of the goal, not a flaw to avoid - what this
toolkit does is keep that trust narrow, explicit and removable. The pipeline itself **never** adds
trust. Three ways to get there:

**1. `Scripts\Approve-DriverPatchCert.ps1`** (recommended), from an elevated prompt, separately from
the installer:

```powershell
.\Scripts\Approve-DriverPatchCert.ps1
```

It prints what it is about to trust and asks for confirmation before running `certutil`. It refuses
anything that is not a self-signed, code-signing, non-CA project certificate, and warns if Test Signing
is off on this boot or Secure Boot is on (both read from the registry, so the warning does not depend
on the display language the way matching `bcdedit`'s output did). Prefer this path: you watch it happen, and it is the one verified end to end. With no `-CerPath`
it takes the `.cer` whose private key is on this machine, or the newest `.cer` in `Certificates\` on a
machine without the key (a target PC has only the copied `.cer`). It does not check that the `.cer`
actually signed your package, so pass the file you minted - `Add-SetupCertOption.ps1` is the stricter
route, refusing a `.cer` whose thumbprint did not sign the package.

**2. Manually**, if you want the raw commands:

```powershell
certutil -addstore Root             "Certificates\DriverPatchSigning_<thumbprint>.cer"
certutil -addstore TrustedPublisher "Certificates\DriverPatchSigning_<thumbprint>.cer"
```

`Root` is what makes a self-signed signature chain at all and is the only one strictly required.
`TrustedPublisher` stops the "Would you like to install this device software?" prompt. There is
deliberately **no `CA` entry**: a self-signed certificate is its own root, so there is no intermediate
to chain through, and `Remove-DriverPatchCert.ps1` removes any `CA` entry it finds for a patch
certificate.

**3. The installer checkbox** - *not fully verified, see below*. `Custom Installation Options` in
`setup.exe` shows a **"Chameleon GPU cert."** row alongside the Graphics/Audio Driver, **ticked by
default**. Left ticked, `setup.exe` runs `certutil -addstore` itself, elevated, before installing the
driver, into the same two stores as option 1; unticked, nothing about your trust settings changes.
What has been confirmed is that the row renders with the intended title, description and disposition
(`disposition="default"`, so it starts ticked and stays user-selectable; `-Unchecked` starts it
unticked). What has **not** been confirmed is the checked-through-a-full-install case: that `certutil`
fires cleanly in the installer's elevated context and the driver then installs without further
prompts. The row has no uninstall phase - trust outlives the driver. Until you verify that yourself,
prefer option 1. Check the result with `certutil -store Root <thumbprint>`.

Whichever route, you also need:

```powershell
bcdedit /set testsigning on     # requires Secure Boot disabled in firmware, and a reboot
```

Test Mode weakens driver signature enforcement globally - turn it back off
(`bcdedit /set testsigning off`) when you are done. **Alternative:** disable driver signature
enforcement for a single boot (Shift+Restart -> Troubleshoot -> Startup Settings -> Disable driver
signature enforcement) - no trust-store or BCD changes, but it has to be redone after every reboot.

## Cleaning up trusted certificates

After the catalog is signed, the pipeline prunes old signing **keys** from `Cert:\CurrentUser\My`,
keeping only the one that run signed with (`-KeepAllOldCerts` opts out). That is the safe half:
per-user, no elevation, withdraws no trust, so it cannot break an already-patched package. It does not
run if signing failed, it is skipped on a run that had to mint a new certificate, and it is skipped on
a run that used an imported `.pfx` - keys are never deleted in the same run that replaced them.

Withdrawing **trust** is the destructive half, and it is yours to decide. Every trusted entry is a
self-signed authority your machine will accept code from, kernel drivers included, until you take it
back out, and a trust entry outlives the key it belongs to. Inventory first - the bare run is
read-only:

```powershell
.\Scripts\Remove-DriverPatchCert.ps1                                   # list: expiry, stores
.\Scripts\Remove-DriverPatchCert.ps1 -Thumbprint <tp>                  # remove one, by name
.\Scripts\Remove-DriverPatchCert.ps1 -AllPatchCerts -KeepThumbprint <the one you use>
```

Removing trust means catalogs that key signed stop validating, so a patched package signed with it can
no longer be installed (an already-installed driver keeps running). Work out which key signed which
package first, with the `Get-AuthenticodeSignature` line in [Signing](#signing).

Notes on what gets selected:

- Subject patterns (`*Chameleon*`, `*Driver Patch*`, `*FrankenDriver*`) only find **candidates**. Every
  automatic or bulk action (`-AllPatchCerts`, the pipeline's own cleanup) additionally requires the
  identity check - self-signed, Code Signing EKU, not a CA - so a third-party certificate that merely
  contains one of those words is neither deleted nor trusted.
- `-Thumbprint` bypasses the identity check on purpose: naming a thumbprint is the explicit request.
- A `CurrentUser` trust store is a **merged view**: entries inherited from the matching `LocalMachine`
  store cannot be deleted through the user view - access-denied even when elevated - and the script
  detects that, skips those entries, and prints the elevated `-Scope LocalMachine -Thumbprint ...`
  command to finish the job.
- `-IncludePrivateKeys` also drops leftover cert+key pairs, and under the default `-Scope Both` that
  includes `LocalMachine\My` - broader than the per-user cleanup its help text describes, so inventory
  first, and note that removing a non-exportable key is irreversible.
