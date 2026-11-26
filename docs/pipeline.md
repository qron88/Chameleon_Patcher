# How the patch pipeline works

What each step of a run does and why: source verification, coverage and limits, the verification gate, pruned builds, optional components and the RM override. Part of the [Chameleon Patcher](../README.md) documentation.

## What the pipeline does

`Scripts\Invoke-DriverPatchPipeline.ps1` is the orchestrator, and the only script the GUI invokes.
Each step prints a `=== N/M: name ===` banner. The numbering below is a default run from a `.exe`:
`-PruneForeignOemInfs` inserts a step after the unpack and shifts the rest by one, and each `-Skip...`
switch removes one.

Before the first step the run does preflight: it resolves the tools, the signing identity and the
source (see [Source verification](#source-verification)).

1. **Unpacking installer** (or *Copying package*) - a 7z-compatible CLI expands the download into
   the work folder `<name>_Patched.partial`. The source `.exe` is never modified.
2. **Pruning OEM INFs that cannot match this machine** - only with `-PruneForeignOemInfs`; see
   [Making a run finish in minutes](#making-a-run-finish-in-minutes).
3. **Patching device/subsystem whitelist** - applies `whitelist.json` to the resolved INFs.
4. **Adding RM capability override (VRAM size / compute fix)**.
5. **Enabling PhysX / NVIDIA App for the unlocked GPUs** - `-SkipOptionalComponents` skips it.
6. **Verifying the patch actually applied** - the gate, run **before** signing.
   `-SkipPatchVerification` bypasses it; there is rarely a good reason to.
7. **Signing certificate** - reuses the key in your store, mints one only if there is none.
8. **Rebuilding + signing catalog** - `Inf2Cat` then `signtool`, then a check that every INF is a
   member of the catalog it declares.
9. **Adding opt-in cert-trust option to installer** - the `GpuUnlockCert` checkbox row.

Every step works in `<name>_Patched.partial`; the folder is renamed to `<name>_Patched` only after
the last step has passed. A run that fails - at the gate, in `Inf2Cat`, in `signtool` - therefore
never leaves a folder under the final name: what it leaves is the `.partial` folder, kept for
inspection, named as unfinished, and removed by the next run. (Before 1.2.1 a failed run left
`<name>_Patched` itself, with `setup.exe`, patched INFs and NVIDIA's now-invalid catalog in it.)

The preflight also reads this boot's Test Signing and Secure Boot state from the registry and warns
before the long part starts if the result could not load on this PC as it is now. It is a warning,
not a stop: a package is often built on one machine for another.

The catalog rebuild dominates the wall clock, by a wide margin: `Inf2Cat.exe` is a single-threaded
32-bit tool that re-validates the whole `Display.Driver` folder once per INF, and a real package has
~43 INFs over ~2.7 GB. Sitting on `Processing INF:` for tens of minutes, at 100% of one core, is
normal. Every other step finishes in seconds.

Step order matters when you run the scripts by hand - `cd Scripts` and:

```powershell
.\Unpack-DriverExe.ps1            -ExePath "621.24-....exe" -OutputPath "621.24_Patched"
.\Add-ExtraGpuSupport.ps1         -DisplayDriverPath "621.24_Patched\Display.Driver"
.\Add-RmCapabilityOverride.ps1    -DisplayDriverPath "621.24_Patched\Display.Driver"
.\Enable-OptionalComponents.ps1   -PackageRoot "621.24_Patched"
.\Test-DriverPatch.ps1            -DisplayDriverPath "621.24_Patched\Display.Driver"
.\New-DriverSigningCert.ps1
.\Sign-DriverPackage.ps1          -DisplayDriverPath "621.24_Patched\Display.Driver"
.\Add-SetupCertOption.ps1         -PackageRoot "621.24_Patched" -CerPath "..\Certificates\DriverPatchSigning_<thumbprint>.cer"
```

The gate has to come **after** every step that edits INFs, and signing has to come last:
`Add-RmCapabilityOverride.ps1` and `Enable-OptionalComponents.ps1` change files that get hashed into
`nv_disp.cat`, so signing first produces a catalog that no longer matches the package and Windows
refuses the driver outright.

## Source verification

Every run re-signs its input with a certificate the machine will trust as a root, so the **input is the
security boundary**: whatever the pipeline is given, it blesses. Before anything is unpacked or copied:

- an `.exe` must carry a valid Authenticode signature from NVIDIA (it covers the appended 7z archive);
- a folder must have every catalog its display INFs declare signed by NVIDIA/WHQL, and every INF and
  driver binary must be a member of one (checked through wintrust, about 20 s for 2.7 GB) - or, for an
  installer plugin outside the catalog, carry a valid NVIDIA/Microsoft signature of its own;
- in a folder, every program **outside** `Display.Driver` (`setup.exe`, the `NVI2` installer core,
  the `HDAudio` / `NVPCF` / `PPC` components - 14 files in a 621.x package, about a second) must carry
  a valid NVIDIA/Microsoft signature too. `Display.Driver` is what gets re-signed, but `setup.exe` is
  what gets run, elevated.

**What a folder cannot prove.** `setup.cfg` and the `.nvi` manifests are not signed by NVIDIA and are
in no catalog, and they tell `setup.exe` what to run. In a download they are covered by the `.exe`'s
own signature; in a folder nothing vouches for them, and the check says so in its report
(`NOT verifiable: ...`) instead of passing over it. That matters most for the folder NVIDIA App
stages under `%ProgramData%`, which ordinary users can write to: treat a folder source as being as
trustworthy as the place it came from, and prefer the original `.exe` when in doubt.

Anything else stops the run. Microsoft signatures are accepted for catalogs (WHQL countersigns them) but
never for an `.exe` source. `-SkipSourceVerification` overrides the check - it exists for hand-patched
packages - and the GUI asks before using it. `-CheckSource` answers `SOURCE_OK` / `SOURCE_UNTRUSTED`
without running anything (`-Json` for a machine-readable answer with `problems` and `notes`).

## Coverage and limits

`whitelist.json` carries **61 entries** covering 51 unique PCI device IDs (see
[Supported GPUs](../README.md#supported-gpus)).

- **Blackwell (RTX 50-series) is out of scope.** The file carries one Blackwell entry, `DEV_2D00`
  under a null subsystem ID that real hardware is unlikely to report. A card outside the whitelist is
  reported as `not in whitelist.json` - by design, not a failure. Unlocking Blackwell mobile parts
  needs entries this project does not have.
- **Written for any driver version is not the same as verified on one.** The patcher hardcodes no
  section numbers and resolves INF names by stem, so it survives NVIDIA's renumbering and renaming -
  but only a handful of releases have been run end to end (the 616.86 desktop-notebook and 616.92
  Studio renames, 617.14 / 617.42, and 621.24 builds). Those runs are not reproducible from this
  repository: the driver packages and the run logs are not in it. Treat a release you have not seen as
  unverified.
- **On an unlisted release, the gate is the thing to watch.** A run that unpacks, patches, signs and
  installs cleanly can still contain no unlock at all - that is exactly what NVIDIA's INF renames
  produced before the stem-based lookup existed. `Patch verification PASSED - N/N whitelist entries
  in place` is the line that says the unlock is in the package. If the whitelist step reports skipping
  an INF, or the gate reports fewer than 61 entries on a full build, stop and read
  [When NVIDIA renames the INFs](#when-nvidia-renames-the-infs) before installing.

### When NVIDIA renames the INFs

`whitelist.json` is keyed by INF filename, and those names are not stable across releases. They have
moved in two different ways:

| Release | Main INF | ASUS OEM INF (`nvami`) | How it moved |
|---|---|---|---|
| baseline | `nv_dispi.inf` | `nvami.inf` | - |
| 616.86 desktop-notebook hotfix | `nv_dispig.inf` | `nvamig.inf` | `g` **appended** to every stem |
| 616.92 Studio (`nsd-dch`) | `nv_dispsi.inf` | `nvamsi.inf` | trailing letter **replaced** by `si` |

A literal lookup fails in the worst way: the whitelist step skips both target INFs and applies
nothing, while the RM-override step carries on happily because it globs `*.inf`. The result is a
package that unpacks, patches, signs and installs cleanly and delivers **no unlock at all**. A plain
`<stem>*.inf` glob is not enough either - it assumes renames only append, and 616.92 replaces a
letter, so `nv_dispsi.inf` does not begin with `nv_dispi`.

The suffix is a per-build quirk, not a convention (the 581.94 desktop-notebook hotfix uses the
ordinary names), so it is not hardcoded. The patcher, the gate and the prune step resolve every
whitelist key through one shared helper, in three tiers:

1. Exact filename match.
2. `<stem>*.inf` - the appended-suffix case.
3. `<stem minus its last character>*.inf` - the replaced-letter case, with a minimum core of four
   characters so a short stem can never widen to something like `n*.inf`.

A release with ordinary names never reaches tier 2 or 3. The substitution is always reported:

```
NOTE: this release has no nv_dispi.inf; it ships nv_dispig.inf instead - patching that.
nv_dispig.inf    58/58 whitelisted, 2 device block(s), 235 spliced section(s) (this release's name for nv_dispi.inf)
```

A widened match that hits more than one file throws. If a future release renames an INF beyond a shared
core, all three tiers miss and the patcher throws with an error saying `whitelist.json` needs updating,
rather than silently doing nothing. A per-version table was considered and rejected: it fails silently
on the first release nobody has entered.

### Section templates and stock "donor" sections

The install-section bodies in `whitelist.json` were captured from 595.79. They name sections by NVIDIA's
numbering at capture time and only do the jobs that existed then (621.x added
`nv_ngx_builtins_copyfiles`). So each template is merged with the closest stock install section of the
INF being patched (Jaccard similarity >= 0.8): every section-referencing directive for a job the
template lacks is added, keyed on directive and section family without the `__NN` suffix. Feature flags
are never copied - those are per-GPU decisions. The gate asks the same question in reverse and fails on a
stale section. The templates cannot be dropped: some whitelisted chips have no stock line at all, so
there is nothing else to point them at.

## The verification gate

Signing is the point of no return. `Inf2Cat` will build a catalog out of unpatched INFs and
`signtool` will sign it, so a package whose patch step quietly found nothing to do comes out looking
finished: it installs, the device enumerates, and the unlock simply is not there.

`Test-DriverPatch.ps1` closes that hole. The pipeline runs it between patching and signing and
refuses to continue if anything is wrong. Re-reading the patched INFs, it asserts:

- every INF named in `whitelist.json` resolves to a file in the package (exact name or rename tier),
  and each resolved file has at least one `[NVIDIA_Devices*]` block;
- every whitelist entry's device and subsystem ID is present in **every** `[NVIDIA_Devices*]` block;
- each device line points at an install section that exists in the same INF;
- every section a spliced-in `SectionExtraGPU*` body references resolves in that INF - and so do the
  references of the stock sections whitelisted lines use;
- no spliced section is stale against the stock donor of its release;
- every `%token%` used by a device line is defined in `[Strings]`;
- every `[nv_miscBase_addreg__NN]` section carries the `RM1457588` override, matched as a real
  directive line rather than a substring.

All of that is a hard failure. A whitelist INF that has vanished under every name the tiers can reach
is an error too, because the entries filed under it are exactly the ones nobody checked. A deliberate
prune is not affected: the pipeline records which whitelist INFs the prune removed and passes them to
every later step as `-PrunedInf`, where they read as a plain note. A file that is present but has no
`[NVIDIA_Devices*]` block, and a package with no `nv_miscBase_addreg__*` section anywhere, are hard
failures as well.

Device lines are matched on the DEV/SUBSYS pair, not on the `%key%` name, because NVIDIA may already
whitelist a device upstream in a later release; then the patcher skips it and the entry is present
under NVIDIA's own line. A trailing `; comment` is ignored, a stock `...&SUBSYS_X&REV_A1` line counts
only for revision A1, and presence is judged per `[NVIDIA_Devices*]` block - each block serves a
different OS target, so an entry listed in one block only is added to the others. The patcher, the
gate, the prune step and the optional-components step share one parser and one matching function
(`Get-InfDeviceLine` / `Test-InfDeviceIdMatch` in `Scripts\Lib\Inf.ps1`), so they read a line the
same way.

One limit worth knowing before reading a green verdict as proof: every matcher reads **one physical
line at a time**. INF lines may be continued with a trailing backslash, and a device entry, a
`[Strings]` definition or an `RM1457588` override split over two lines would be invisible to the check
that just certified it. The gate therefore reports the count and the line numbers of such
continuations as a warning and leaves the judgement to you; it does not fold them, because folding would
rewrite bytes of an already-patched package. No NVIDIA release so far splits those lines.

Run it against any package, patched or not:

```powershell
.\Scripts\Test-DriverPatch.ps1 -DisplayDriverPath "621.24_Patched\Display.Driver"   # add -ReportOnly to inspect without failing
```

Both patchers fail loudly when the layout is not what they understand: `Add-ExtraGpuSupport.ps1`
throws if an INF has no `[NVIDIA_Devices*]` block at all, and `Add-RmCapabilityOverride.ps1` throws
if no INF in the package has an `[nv_miscBase_addreg__NN]` section.

### Byte-faithful reading and writing

OEM INFs in the package can be ANSI, and every byte ends up in a catalog hash. `Get-InfTextFile`
sniffs the BOM, decides strict UTF-8 or the ANSI codepage by trial, and records the line terminator;
`Write-InfLines` / `Write-InfText` write the file back with the same settings, atomically (temp file +
`File.Replace`). A BOM stays a BOM, an LF-only file stays LF-only. `setup.cfg` and the `.nvi` manifest
are edited as text with tolerant patterns and then verified as XML, with byte-exact rollback -
re-serialising the XML would rewrite NVIDIA's whole file.

## Making a run finish in minutes

Almost all the wall clock in a patch run is `Inf2Cat` rebuilding the catalog, single-threaded on one
core. Two things were measured on a real 2.71 GB `Display.Driver`, and the first kills the obvious
idea:

**Trimming the `/os` list does nothing.** One, two and all five OS targets give the same runtime and
a byte-identical catalog. **The cost is superlinear in INF count**, driven by the INFs and not by the
payload bytes:

| INFs | Time |
|---|---|
| 1 | 79.7 s |
| 2 | 128.1 s |
| 4 | 147.4 s |
| 8 | 583.8 s |

Four to eight INFs quadruples it, which is why all 43 take about fifty minutes. `Inf2Cat /?` offers
no way to reduce its own work, and parallelising is not available: all 43 INFs declare
`CatalogFile = NV_DISP.CAT`, so they build one shared catalog, and catalogs cannot be merged.

So the only lever is fewer INFs, which is what `-PruneForeignOemInfs` does:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "...exe" -PruneForeignOemInfs
```

A stock package ships 43 display INFs: the generic desktop one plus one per laptop OEM, and usually
exactly one can apply to a given machine. An INF survives if it can match a GPU actually present, if
this toolkit patches it **and** one of its whitelist entries names present hardware, or if you passed
`-KeepInf`. Everything else goes, with its manifest entry. The catalog and filter files that share a
pruned INF's stem are left where they are, manifest entry included, and the step says so rather than
deleting files it cannot account for. Requiring a whitelist match matters: keeping every INF the
toolkit *could* patch retains a 3.9 MB OEM INF whose entries all name a GPU the machine does not
have, and on its own that INF accounted for three quarters of the catalog build.

Measured on 616.86, 43 INFs down to 1:

| Step | Unpruned | Pruned to 2 | Pruned to 1 |
|---|---|---|---|
| Catalog rebuild | ~3000 s | 385 s | **96 s** |
| RM override | 1485 sections / 40 INFs | 122 / 2 | 17 / 1 |
| Whole pipeline | ~57 min | 7.6 min | **2.2 min** |

Do not bother trimming the whitelist entries themselves: on an identical two-INF package, patching
zero entries, all 61, or one took 391.6 s, 384.9 s and 372.5 s. The spread is noise - the cost is in
the INFs and the binaries, not in the device lines added to them.

Three safety rules:

- **A pruned build needs a GPU worth pruning for.** The run stops in preflight, before anything is
  unpacked, if no GPU in this machine is one `whitelist.json` unlocks:

  ```
  Nothing to unlock on this machine, and a for-this-PC-only build was requested.

    NVIDIA GeForce RTX 4060 (DEV_2702&SUBSYS_000014C2) - not in whitelist.json
  ```

  A pruned run on such a box completes and is a no-op: it keeps the INF that matches the desktop
  card, splices in 58 mobile-GPU lines nothing there can ever match, reports `PASSED`, and signs the
  result - NVIDIA's own driver for a GPU that already works, needing Test Signing mode to install.
  The universal build (the default) is the correct choice there, and is never questioned. Pass
  `-AllowUnsupportedGpu` to build the pruned package anyway; `-CheckLocalGpuSupport` answers the same
  question without running anything. If no NVIDIA display GPU can be read at all the run continues
  with a warning - a WMI quirk should not refuse a build.
- **Pruning must never delete every INF.** If the whitelist names do not resolve against a release,
  the strict rule and the keep-everything fallback both come up empty and pruning would delete every
  display INF. The keep set is re-checked after the fallback and the step throws instead. That holds
  no matter what emptied the keep set.
- **A failed prune is undone.** Pruned INFs move to a staging folder and are deleted only once the
  manifest and the folder are verified to agree; any failure before that moves them back and
  restores the manifest. After verification the deletion is final - there is no backup copy, so
  recovering an INF means re-unpacking the download.

Matching follows Windows' own rules: an exact `DEV`+`SUBSYS` line, or a bare `DEV` line that covers
any subsystem of that device. A line with extra qualifiers (`&REV_xx`, `&CC_xxxxxx`) counts as a
possible match and keeps its INF - keeping one that turns out not to apply costs time, dropping one
that does apply breaks the install. Multi-GPU machines are handled: the kept set is the union of what
every display-class NVIDIA GPU present needs, and the reasons are printed per INF. Only the GPU is
considered, not the HD Audio function NVIDIA exposes on the same PCI device.

The self-containment of a pruned package is a claim, not a guarantee: the script scans the kept INFs
for `Include=`, `Needs=` and `CopyINF=` references to a pruned name and refuses when it finds one,
but that scan reads one physical line at a time, recognises only **literal** filenames, and looks
inside `Display.Driver` only. The captured section bodies in `whitelist.json` carry
`CopyINF = nvppc.inf`, so this is a real thing to watch on a release nobody has run. The prune is
also why a pruned package is not portable: by the time `setup.exe` runs, the INFs are gone, so
whoever installs cannot change it. In the GUI it is the **"Build for this PC only"** checkbox,
unticked by default, and ticking it on a machine this toolkit does not unlock gets a dialog offering
the portable build instead.

## PhysX and the NVIDIA App

Whether `setup.exe` offers "PhysX System Software" and the NVIDIA App is not fixed: both are gated by
`setup.cfg` constraints that read **per-device feature flags out of the driver INF**, and NVIDIA
writes those flags unevenly. In stock 616.64's main INF, 55 of 105 device install sections carry
`NVSupportPhysx = 1` and 28 carry `NVSupportGFExperienceUDA = 1`. The constraints are
`level="silent"`, so a GPU whose section lacks the flag makes the component vanish from the installer
with no message at all - which is why the offer appears on some hardware and not others.

`Enable-OptionalComponents.ps1` levels this out for the GPUs this toolkit unlocks: it resolves each
whitelisted device line to the install section it points at and ensures that section carries both
flags. It also flips `Display.NvApp` from `disposition="default" userSelectable="false"` (pre-ticked
and locked) to `userSelectable="true"`, so both components are ticked by default and both can be
unticked under Custom Installation Options. It runs as a pipeline step before the catalog is built,
and `-SkipOptionalComponents` skips it.

It deliberately does **not** delete the `setup.cfg` constraints: that would force these components on
for every GPU, including ones NVIDIA flagged as unsupported. Most whitelisted devices get a freshly
spliced `SectionExtraGPU*` section, so the change lands only on them. When a whitelisted device reuses a
stock section that other devices also use, the section is **cloned** as `<section>_ChameleonOpt` and
only the whitelisted lines are repointed - editing it in place switched PhysX/App on for unrelated GPUs
(seen on 621.24: `Section017`, `Section139`, `Section141`). One asymmetry: this step only **warns** when
a whitelisted device line points at a section that does not exist, and moves on; the gate treats the
same condition as a hard failure, so the case still stops a run, one step later. None of this is
confirmed through a real install - verify on your own hardware.

## Why VRAM size / compute needs a second fix

Symptom: the driver installs on a whitelisted GPU, the device shows up in Device Manager, but the
VRAM size is wrong and compute (CUDA/NVENC/OptiX) does not work.

The driver does a **second, internal Resource-Manager-level hardware check**, separate from and
deeper than the INF's PCI ID whitelist. A device can pass the INF check - so it installs and
enumerates - and still fail this internal one, which is what causes the symptoms.
`HKR,,RM1457588,%REG_DWORD%,1` reads as a validation-bypass override for exactly that check, and
**NVIDIA ships it themselves**: in the stock 595.79 package the MSI OEM INF `nvmsoai.inf` carries it
in both of its `nv_miscBase_addreg__NN` sections, and the key name also appears in `nvlddmkm.sys` and
the `gsp_*.bin` GSP firmware images, so the driver really reads it. NVIDIA's use of it is precisely
this case: an OEM-specific INF enabling full capability on hardware the generic desktop INF would
restrict.

It also explains the old "install a hand-patched driver first, then ours over it, and it works"
workaround: that installer writes the value once under the device's own driver key, and a driver
*update* does not necessarily clear per-device values the new INF does not mention. A **clean**
install has no such leftover, so the internal check stays in effect.

The hand-patched reference touched only the sections its author's own hardware needed.
`Add-RmCapabilityOverride.ps1` adds the override to **every** `nv_miscBase_addreg__*` section in
**every** driver INF, rather than resolving which sections each of the 61 whitelist entries
references - fragile across the same section renumbering the whitelist patcher already works around.
The key has no observed effect on hardware that passes the internal check on its own, so applying it
broadly is the safer and more complete fix. Verified structurally: after patching, every
`nv_miscBase_addreg__*` section in every INF (1400 sections across 39 files in the 595.79 package)
carries the override, with no duplicated or corrupted section headers. Narrowing it to reachable
sections is a valid future change only with an install test on hardware.
