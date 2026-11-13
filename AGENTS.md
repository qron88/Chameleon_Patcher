# Notes for agents reviewing or changing this repository

Read this before you report weaknesses or propose redesigns. Most mechanisms here look odd in
isolation and were made that way on purpose, usually after a real failure on a real driver
package. Reviews by language models have repeatedly flagged documented, deliberate trade-offs as
"critical" and proposed fixes that cannot work on Windows. This file says why each mechanism exists,
what a real defect in it would look like, and how to check a claim before making it.

## What the project is - and the threat model that follows from it

Chameleon Patcher edits the INFs of an NVIDIA driver package so that it installs on mobile GPU cores
mounted on desktop cards, then re-signs the catalog with a self-signed certificate minted on the
user's machine. It is used by the owner of the hardware, on their own machines.

Three facts are fixed by Windows, not by this code:

1. **An edited INF invalidates NVIDIA's catalog.** The package must be re-signed; nothing else makes
   Windows accept it.
2. **A self-signed kernel-driver catalog loads only under Test Signing** (or with signature
   enforcement disabled for one boot), and only if the certificate chains to `LocalMachine\Root`.
   There is no "driver-only" trust store and `pnputil` does not establish trust. Adding the
   certificate to `Root` is therefore not a design flaw to be removed; it is the cost of the goal.
   What the code can do - and does - is keep that trust narrow, explicit and removable.
3. **The re-signed output is trusted by the machine.** That makes the INPUT the security boundary:
   whatever the pipeline is given, it blesses. Source verification exists for that reason.

So the real threats are: blessing something that is not NVIDIA's; trusting a certificate other than
the one that signed; leaking or multiplying trusted keys; and shipping a package that looks finished
but is not (no unlock, wrong files). Most mechanisms below serve one of these.

## How to check a claim before you make it

- `.\Tests\Run.ps1` - 76 Pester tests, ~5 s, Pester 3.4 (built into Windows PowerShell 5.1). They
  build tiny packages, certificates and catalogs in `%TEMP%`; nothing touches a store.
- A real run: `.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath Drivers\<x>.exe
  -PruneForeignOemInfs -NonInteractive` takes ~2.5 min on a machine with a whitelisted GPU (the
  universal build takes ~1 h). `Drivers\` is git-ignored and holds downloads; some are deliberately
  NOT NVIDIA-signed (`CN=FrankenDriver`) and must be refused.
- `CHANGELOG.md` -> "Reference notes" holds measurements and design notes; each release entry says
  what failed before the change. Quote it rather than guessing.
- Do not install drivers, change trust stores, toggle Test Signing or delete certificates while
  analysing. None of that is needed to verify a claim about this code.

## Mechanisms that look like weaknesses - and why they are not

### Certificate in `Root` and `TrustedPublisher`
Required for a self-signed driver to load (see above). `TrustedPublisher` only suppresses the
"install this device software?" prompt. Mitigations already in place: trust is never added by the
pipeline itself (only by `Approve-DriverPatchCert.ps1`, run elevated and confirmed, or by the opt-in
installer row); `Add-SetupCertOption.ps1` refuses a `.cer` that did not sign the package's catalog;
`Approve-DriverPatchCert.ps1` refuses anything that is not a self-signed, code-signing, non-CA
project certificate and warns if Test Signing is off; minted certificates are non-exportable, carry
critical `BasicConstraints CA=false`, Code Signing EKU only, 3-year validity; no `CA` store entry is
ever written; `Remove-DriverPatchCert.ps1` inventories and withdraws trust.
**A real defect would be:** trust added without an explicit user action, a certificate trusted that
did not sign the package, a CA-capable certificate, or an entry in the `CA` store.
**Do not propose:** "use a driver-specific store", "inject trust via pnputil", "avoid Root".

### Passwords
Signing always runs `signtool /sha1 <thumbprint>` from `Cert:\CurrentUser\My`. A `.pfx` is imported
there once (`Import-SigningPfx`, key non-exportable), so no password ever reaches a command line.
The GUI passes a password only in the child's environment (`DRIVER_PATCH_PFX_PASSWORD`); the
pipeline reads and removes it before doing anything else. A run that used an imported `.pfx` skips
old-key cleanup so it cannot delete the machine's own key.
**Do not propose:** writing the password to a temp file for signtool (signtool cannot read one),
"one-time passwords" for a `.pfx`, or reintroducing `/f /p`.

### Certificate cleanup by subject pattern
Patterns (`*Chameleon*`, `*Driver Patch*`, `*FrankenDriver*`) find candidates; every automatic or
bulk action additionally requires `Test-ProjectSigningCertificate` (self-signed, Code Signing EKU,
not a CA). `-Thumbprint` bypasses the identity check on purpose: naming a thumbprint is the explicit
request. The pattern list must only ever GROW - removing a pattern makes older certificates
invisible to resolution and cleanup, leaving untracked trusted roots.

### Source verification and `-SkipSourceVerification`
An `.exe` must carry a valid NVIDIA signature (it covers the appended 7z archive). A folder must have
a WHQL/NVIDIA-signed catalog covering every INF and driver binary (wintrust membership, ~20 s for
2.7 GB). The override exists because the author has hand-patched "Franken" packages; the GUI asks
before using it. Microsoft signatures are accepted for catalogs (WHQL countersigns them) but never
for an `.exe` source.

### `RM1457588` in every `nv_miscBase_addreg__NN` section of every INF
Deliberate. NVIDIA ships the same value in its MSI OEM INF; the key is read by `nvlddmkm.sys`.
Without it a whitelisted GPU installs but misreports VRAM and has no compute. Applying it only to
sections reachable from whitelisted devices was judged more fragile across renumbering, and the key
has had no observed effect on hardware that passes the check anyway. Narrowing it is a valid future
change ONLY with an install test on hardware; it is listed as open in the changelog. The presence test
is a directive match (`Test-InfRmOverrideLine`), not a substring.

### INF rename lookup (exact, `<stem>*`, `<stem minus one>*`)
NVIDIA renames INFs per build with no stable rule (616.86 appends `g`, 616.92 replaces a letter with
`si`, 581.94 renames nothing). A literal lookup once produced a signed package with no unlock at all.
The tiers are a heuristic with hard edges: every substitution is reported, a widened match that hits
more than one file throws, a rename beyond the tiers throws, and the gate fails if any whitelist INF
is missing. A per-version table ("driver profiles") was considered and is not used: it fails silently
on the first release nobody has entered, which is exactly the failure the heuristic plus the gate
prevent. If NVIDIA ever renames beyond the tiers, the error says so and an alias is the fix.

### Captured section templates merged with a stock "donor"
`whitelist.json` holds install-section bodies captured from 595.79. They name sections by NVIDIA's
numbering at capture time and only do the jobs that existed then (621.x added
`nv_ngx_builtins_copyfiles`). `Merge-InfTemplateWithDonor` picks the closest stock install section
of THIS INF (Jaccard >= 0.8) and adds every section-referencing directive it has for a job the
template lacks, keyed on directive + section family without `__NN`. Feature flags are never copied
(per-GPU decisions). The gate asks the same question in reverse and fails on a stale section.
**Do not propose** dropping the templates: some whitelisted chips have no stock line at all, so
there is nothing else to point them at.

### Shared stock sections are cloned, not edited
When a whitelisted device reuses a stock install section that other devices also use,
`Enable-OptionalComponents.ps1` clones it as `<section>_ChameleonOpt` and repoints only the
whitelisted lines. Editing in place switched PhysX/App on for unrelated GPUs (seen on 621.24:
`Section017`, `Section139`, `Section141`).

### The verification gate and its one-line limit
`Test-DriverPatch.ps1` runs before signing and fails on: a missing whitelist INF, a missing entry in
any `[NVIDIA_Devices*]` block, a dangling install section, an undefined `%token%`, unresolved
references in spliced sections and in stock sections whitelisted lines use, a stale spliced
section, a misc section without the RM directive. All matchers read one physical line at a time;
backslash continuations in the patched sections are REPORTED (with line numbers), not folded,
because folding would rewrite bytes of an already-patched package. No NVIDIA release so far splits
those lines. Folding belongs in a future single INF model, not in each matcher.

### Byte-faithful reading and writing
`Get-InfTextFile` / `Write-InfLines` preserve BOM, codepage (strict UTF-8, else ANSI) and newline
style; writes are atomic (temp + `File.Replace`). OEM INFs in the same folder can be ANSI, and every
byte ends up in a catalog hash; a "simpler" `Get-Content`/`Set-Content` round trip corrupted accents
and rewrote line endings in earlier versions. `setup.cfg` and the `.nvi` manifest are edited as text
with tolerant regexes and then verified as XML, with byte-exact rollback - re-serialising the XML
would rewrite NVIDIA's whole file.

### Catalogs paired by `CatalogFile=`
All display INFs declare `NV_DISP.CAT`; file names do not carry the pairing. Only declared
catalogs are signed; after signing, every INF must be a member of its declared catalog. Catalogs of
pruned OEM INFs stay on disk with NVIDIA's (now invalid) signature; nothing declares them.

### The GUI asks the pipeline instead of reimplementing rules
`-ShowOutputPath`, `-CheckLocalGpuSupport`, `-CheckPatchTools`, `-CheckSource` keep each rule in one
place. The price is a text protocol: the first stdout line is a verdict word, and the GUI recognises
the `.pfx` failure by the phrase `none was supplied and prompting is disabled`. Keep that phrase in
`Invoke-DriverPatchPipeline.ps1` and `Sign-DriverPackage.ps1`. The pipeline forces UTF-8 stdout
because a windowless child otherwise writes in the OEM codepage. A structured (JSON) protocol would
be an improvement; until then, change both sides together.

### Other deliberate choices
- Windows PowerShell 5.1 is the target; PowerShell 7 is not required. Scripts are ASCII-only (a
  BOM-less non-ASCII `.ps1` is parsed as ANSI by 5.1) and CRLF. Tests use Pester 3.4 syntax.
- `$PSScriptRoot` is resolved in the script body, not in `param()` defaults - it is empty there
  under `powershell -File`.
- The pipeline never overwrites an output folder and has no resume: a partial package must never be
  mistaken for a finished one.
- RFC 3161 timestamping over `http://` is normal (the response is signed); it is best-effort.
- `Chameleon-Patcher.exe` is committed because users double-click it; it is rebuilt from
  `Source\` with the Framework's `csc.exe` and committed with the scripts it runs.
- Long comments explain past failures. Do not strip them as noise; move history to the changelog
  if a comment no longer explains current code.

## Known open items (real, documented, not yet done)

- Narrowing `RM1457588` to reachable sections - needs a hardware install test.
- The installer's certificate row has no uninstall phase; trust outlives the driver.
- One-physical-line matchers (see the gate) - waiting for a single shared INF model.
- No CI; `Tests\Run.ps1` is run by hand.
- GUI <-> pipeline text protocol.

## When you change something

1. `.\Tests\Run.ps1` must stay green; add a test for the behaviour you change.
2. Anything that touches INF logic: one pruned real run on a driver in `Drivers\` (and a universal
   run on a renamed release such as 616.92 if the rename or gate logic changed).
3. Keep scripts ASCII and CRLF; keep the GUI phrase contract; only add to subject patterns.
4. Add a `CHANGELOG.md` entry that says what failed before and how the change was verified.
