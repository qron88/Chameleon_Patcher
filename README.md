# Chameleon Patcher

<img src="Assets/Chameleon.png" alt="Chameleon Patcher" width="120" align="right">

Chameleon Patcher takes a stock NVIDIA driver package and patches it so it installs and works on
GPUs that package does not normally recognise - chiefly desktop PCI-E expansion cards carrying a
**mobile** GPU core (laptop RTX 20-, 30- and 40-series and RTX-Ada mobile parts). That is mobile
silicon on a desktop card, a combination the stock desktop driver's INF whitelist does not cover,
so the driver will not install on such a card as-is.

Point the tool at a downloaded driver `.exe` and it verifies the source, unpacks, patches, checks and
re-signs it, and leaves a plain folder behind: `<name>_Patched`.

Two independent gates have to come off, and the patcher handles both:

- **The INF PCI ID whitelist.** 61 device/subsystem entries are added to the driver INFs - 58 to
  `Display.Driver\nv_dispi.inf` (the main desktop INF) and 3 to `nvami.inf` (an OEM INF whose stock lines all carry ASUS's subsystem vendor ID `1043`). All
  additions, no removals. This is what lets the driver install and the device enumerate. The full
  list is in [Supported GPUs](#supported-gpus).
- **The driver's internal Resource-Manager check.** One registry value,
  `HKR,,RM1457588,%REG_DWORD%,1`, is added to every `nv_miscBase_addreg` AddReg section across the
  driver INFs. Without it a whitelisted GPU installs and enumerates, but misreports its VRAM size
  and has broken compute - see
  [Why VRAM size / compute needs a second fix](#why-vram-size--compute-needs-a-second-fix).

Editing INFs invalidates `nv_disp.cat`, so the patcher rebuilds the catalog with `Inf2Cat` and
re-signs it with a self-signed code-signing certificate minted on your machine. A patched package
therefore installs only on a machine that trusts that certificate and has Windows Test Signing mode
on - see [Trusting the certificate](#trusting-the-certificate).

`Scripts\whitelist.json` is the data-driven form of those 61 entries (device ID, subsystem ID,
description, and a captured INF section body used as a template), derived by diffing a stock package
against a hand-patched one. The patching is written to survive NVIDIA renumbering and renaming INFs,
so it is written for **any** driver version - see [Coverage and limits](#coverage-and-limits) for
what has actually been run end to end.

Design notes and measurements are also kept in [CHANGELOG.md](CHANGELOG.md#reference-notes); before
reworking a mechanism, read [AGENTS.md](AGENTS.md), which says why each one is the way it is.

## Contents

- [Quick start](#quick-start)
- [What you need](#what-you-need)
- [Supported GPUs](#supported-gpus)
- [What the pipeline does](#what-the-pipeline-does)
- [Source verification](#source-verification)
- [Coverage and limits](#coverage-and-limits)
- [The verification gate](#the-verification-gate)
- [Making a run finish in minutes](#making-a-run-finish-in-minutes)
- [PhysX and the NVIDIA App](#physx-and-the-nvidia-app)
- [Why VRAM size / compute needs a second fix](#why-vram-size--compute-needs-a-second-fix)
- [Signing](#signing)
- [Trusting the certificate](#trusting-the-certificate)
- [Cleaning up trusted certificates](#cleaning-up-trusted-certificates)
- [Installing the patched driver](#installing-the-patched-driver)
- [The GUI](#the-gui)
- [Tests](#tests)
- [Project layout](#project-layout)
- [Version](#version)
- [Safety notes](#safety-notes)
- [Contributors](#contributors)

## Quick start

Double-click `Chameleon-Patcher.exe`, pick the downloaded driver `.exe` (or an already-unpacked
package folder), press **Start Patching**. The app verifies the source, unpacks, patches, checks,
signs and adds the installer checkbox, shows progress per step, and offers to launch `setup.exe` when
it finishes. It must stay in the project root - it finds `Scripts\Invoke-DriverPatchPipeline.ps1`
next to itself.

Four checkboxes, and what each maps to in the pipeline:

| Checkbox | Default | What it does |
|---|---|---|
| Sign with an existing certificate from a .pfx file | off | Adds `-PfxPath`; the `.pfx` is imported into `Cert:\CurrentUser\My` once (non-exportable) and signing then uses the store. A typed password travels only in the child process's environment, never on a command line. |
| Add a certificate-trust checkbox to the installer, ticked by default (recommended) | **on** | Unticking passes `-SkipSetupCertOption`, so `setup.exe` changes no trust settings and `Approve-DriverPatchCert.ps1` stays a separate step. |
| Build for this PC only - much faster, not portable | off | `-PruneForeignOemInfs`. See [Making a run finish in minutes](#making-a-run-finish-in-minutes). |
| Delete the output folder first if it exists | off | Off: an existing output folder stops the run. On: the app asks once more, then removes it. |

The same pipeline from a terminal:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "621.24-desktop-win10-win11-64bit-international-dch-whql.exe"
```

No certificate and no password: the pipeline finds your existing signing key in
`Cert:\CurrentUser\My` and signs with it, so every driver release keeps using the certificate you
already trust. Before copying anything it prints what it resolved, then runs the steps:

```
Preflight: checking tools and signing identity...
  7z:       <path>\7z.exe
  Inf2Cat:  <Windows Kits>\10\bin\10.0.28000.0\x86\Inf2Cat.exe
  signtool: <Windows Kits>\10\bin\10.0.28000.0\x64\signtool.exe
  cert:     <thumbprint> (from certificate store - no password needed)
```

Queries that run without patching anything:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -CheckPatchTools                        # TOOLS_OK / TOOLS_MISSING + install help
.\Scripts\Invoke-DriverPatchPipeline.ps1 -CheckLocalGpuSupport                   # SUPPORTED / UNSUPPORTED / UNKNOWN, one line per GPU
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "<exe>" -CheckSource     # SOURCE_OK / SOURCE_UNTRUSTED
```

Starting from an already-unpacked folder: `-SourcePackagePath "<folder>"` - the same pipeline minus
the unpack step. `-SkipSetupCertOption` leaves `setup.cfg` untouched if you prefer `pnputil` or
`Approve-DriverPatchCert.ps1` separately.

## What you need

Two installs; everything else ships with Windows 10/11. Patching needs **no internet access** - the
one network call is a best-effort RFC 3161 timestamp on the signature, and an unreachable timestamp
server leaves the catalog signed with a warning (`-SkipTimestamp` skips the attempt).

**Install these two**

| Dependency | What it is for | Install |
|---|---|---|
| **7-Zip** (or NanaZip - any 7z-compatible CLI) | Unpacks the driver download. It is the only route; `-SourcePackagePath` avoids it. | <https://7-zip.org/> or `winget install -e --id 7zip.7zip` |
| **Windows SDK**, with **Windows SDK Signing Tools** and **Windows Driver Kit** kept selected - the WDK's *Binaries* feature carries `Inf2Cat.exe` | `Inf2Cat.exe` rebuilds `nv_disp.cat`, `signtool.exe` signs it. Neither has a substitute. A full WDK development environment is **not** needed. | <https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/> |

Both are resolved before a run starts (`-CheckPatchTools`, and the GUI asks the same question before
unpacking). `Inf2Cat.exe` and `signtool.exe` are looked for under `%WDKContentRoot%`, then
`Windows Kits\10\bin` (newest SDK version first, x64 preferred - `Inf2Cat.exe` ships x86-only), then
on `PATH`; override with `-Inf2CatPath` / `-SignToolPath`. A 7z CLI is found through the WindowsApps
`7z.exe` alias, `Program Files\7-Zip`, `Program Files (x86)\7-Zip`, `Program Files\NanaZip` and
`PATH`, or passed as `-SevenZipPath`. A missing dependency stops the run in seconds with the install
command in the message, before any multi-GB copy.

**Already in Windows** - Windows PowerShell 5.1 (every `.ps1` targets 5.1; PowerShell 7 is a
deliberate non-dependency), .NET Framework 4.x (the GUI is a WinForms app), `certutil.exe`, the PKI
module (`New-SelfSignedCertificate` / `Export-Certificate` / `Export-PfxCertificate`), and
`Get-CimInstance` (reads this machine's GPUs for the pruning gate).

**To install what this toolkit produces** - Test Signing mode plus a certificate the machine trusts
(see [Trusting the certificate](#trusting-the-certificate)), administrator rights, and a driver to
patch. The project bundles no driver.

**To rebuild the GUI** - `csc.exe` from `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\`, invoked by
`Source\Build.ps1`. Already in Windows, so a rebuild needs no install.

## Supported GPUs

Everything `Add-ExtraGpuSupport.ps1` adds comes from `Scripts\whitelist.json`: **61 entries, 51
unique PCI device IDs**, 58 in `nv_dispi.inf` and 3 in `nvami.inf`. Each entry is one
`%NVIDIA_DEV.xxxx...%` device line in every `[NVIDIA_Devices*]` block of its INF, pointing at an
install section (a freshly spliced `SectionExtraGPU*` built from the captured template, or an existing
stock section when one already fits that chip).

How to read the tables:

- **Subsystem** is the `SUBSYS_` part of the hardware ID, written `<subsystem device><subsystem
  vendor>`. *any* means the entry has no subsystem qualifier and matches every subsystem of that
  device. `10DE` is NVIDIA's own generic vendor ID, `44494D50` and `00000000` are generic/null IDs
  that mobile cores often report on an adapter board. The four rows with a named vendor are real OEM
  subsystem IDs.
- **GPU** is the label in `whitelist.json` (an `m` suffix = mobile part). It is a description, not a
  guarantee: the INF matches on the PCI ID alone.
- Entries NVIDIA already whitelists upstream in a given release are skipped by the patcher and count
  as present under NVIDIA's own line.
- Where a device ID appears more than once, each row is a separate INF line (different subsystem).

Subsystem breakdown of the 61 entries: 35 `SUBSYS_000010DE`, 16 with no subsystem qualifier, 3
`SUBSYS_44494D50`, 3 `SUBSYS_00000000`, 4 specific OEM IDs (MSI, ASUS x2, Lenovo).

### Turing (RTX 20-series) - 20 entries, `nv_dispi.inf`

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_1E90` | GeForce RTX 2080 | any |
| `DEV_1E90` | GeForce RTX 2080m | 10DE |
| `DEV_1E91` | GeForce RTX 2070 Super | any |
| `DEV_1E93` | GeForce RTX 2080 Super | any |
| `DEV_1E93` | GeForce RTX 2080m Super | 10DE |
| `DEV_1ED0` | GeForce RTX 2080 | any |
| `DEV_1ED1` | GeForce RTX 2070 Super | any |
| `DEV_1ED3` | GeForce RTX 2080 Super | any |
| `DEV_1F10` | GeForce RTX 2070 | any |
| `DEV_1F11` | GeForce RTX 2060 | any |
| `DEV_1F12` | GeForce RTX 2060 | any |
| `DEV_1F14` | GeForce RTX 2070 | any |
| `DEV_1F14` | GeForce RTX 2070m | 10DE |
| `DEV_1F15` | GeForce RTX 2060 | any |
| `DEV_1F36` | Quadro RTX 3000 | 10DE |
| `DEV_1F50` | GeForce RTX 2070 | any |
| `DEV_1F51` | GeForce RTX 2060 | any |
| `DEV_1F52` | GeForce RTX 2060 | any |
| `DEV_1F54` | GeForce RTX 2070 | any |
| `DEV_1F55` | GeForce RTX 2060 | any |

### Turing GTX 16-series - 1 entry, `nv_dispi.inf`

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_2191` | GeForce GTX 1660m Ti | 10DE |

### Ampere (RTX 30-series and RTX A-series mobile) - 23 entries, `nv_dispi.inf`

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_2420` | GeForce RTX 3080m Ti | 10DE |
| `DEV_2438` | RTX A5500m | 10DE |
| `DEV_249C` | GeForce RTX 3080m | 00000000 |
| `DEV_249C` | GeForce RTX 3080m | 10DE |
| `DEV_249C` | GeForce RTX 3080m | 44494D50 |
| `DEV_249D` | GeForce RTX 3070m | 00000000 |
| `DEV_249D` | GeForce RTX 3070m | 10DE |
| `DEV_249D` | GeForce RTX 3070m | 44494D50 |
| `DEV_24A0` | GeForce RTX 3070m Ti | 10DE |
| `DEV_24BA` | RTX A4500m | 10DE |
| `DEV_2501` | GeForce RTX 3060 SUPER | 397E1462 (MSI) |
| `DEV_2501` | GeForce RTX 3060m | 87E81043 (ASUS) |
| `DEV_2520` | GeForce RTX 3060m | 10DE |
| `DEV_2520` | GeForce RTX 3060m | 44494D50 |
| `DEV_25A0` | GeForce RTX 3050m Ti | 10DE |
| `DEV_25A2` | GeForce RTX 3050m | 10DE |
| `DEV_25A5` | GeForce RTX 3050m | 10DE |
| `DEV_25AD` | GeForce RTX 2050 | 3AF817AA (Lenovo) |
| `DEV_25B8` | RTX A2000m | 10DE |
| `DEV_25B8` | RTX A2000m | 106C1043 (ASUS) |
| `DEV_25BA` | RTX A2000m | 10DE |
| `DEV_25BC` | RTX A1000m | 10DE |
| `DEV_25FA` | RTX A2000m | 10DE |

`DEV_25AD` is an Ampere-based RTX 2050 mobile part, listed here for its device ID range.

### Ampere (RTX A-series mobile) - 3 entries, `nvami.inf`

These three go into `nvami.inf` instead of the main desktop INF. That INF is NVIDIA's per-OEM INF for
ASUS: every one of its 537 device lines in stock 582.78 has subsystem vendor `1043`. In stock 621.24 it
is also the only INF that lists these chips at all (ASUS-specific lines such as
`DEV_24B8&SUBSYS_19A21043`, installing through `Section139` / `Section141`); `nv_dispi.inf` has no line for
`DEV_24B8` / `24B9` / `24BB`. The added `SUBSYS_000010DE` lines sit next to those and reuse the same install
sections. Placement in this file is a convention of `whitelist.json`, not a requirement of Windows: PnP
matches a hardware ID against any INF in the package, so a generic line would also work in
`nv_dispi.inf` given a suitable install section.

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_24B8` | RTX A3000m | 10DE |
| `DEV_24B9` | RTX A3000m | 10DE |
| `DEV_24BB` | RTX A3000m | 10DE |

### Ada Lovelace (RTX 40-series and RTX Ada mobile) - 13 entries, `nv_dispi.inf`

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_24B7` | RTX 4000 Ada Generation Laptop GPU | 10DE |
| `DEV_2717` | GeForce RTX 4090m | 10DE |
| `DEV_2730` | RTX 5000 Ada Generation Laptop GPU | 10DE |
| `DEV_2757` | GeForce RTX 4090m | 10DE |
| `DEV_27A0` | GeForce RTX 4080m | 10DE |
| `DEV_27BA` | RTX 4000 Ada Generation Laptop GPU | 10DE |
| `DEV_27BB` | RTX 3500 Ada Generation Laptop GPU | 10DE |
| `DEV_27E0` | GeForce RTX 4080m | 10DE |
| `DEV_2820` | GeForce RTX 4070m | 10DE |
| `DEV_2860` | GeForce RTX 4070m | 10DE |
| `DEV_28A0` | GeForce RTX 4060m | 10DE |
| `DEV_28A1` | GeForce RTX 4050m | 10DE |
| `DEV_28B8` | RTX 2000 Ada Generation Laptop GPU | 10DE |

### Blackwell (RTX 50-series) - 1 entry, `nv_dispi.inf`

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_2D00` | GeForce RTX 5060m | 00000000 |

This single entry sits under a null subsystem ID that real hardware is unlikely to report; Blackwell
is effectively out of scope - see [Coverage and limits](#coverage-and-limits).

### What else changes for these GPUs

Besides the device line itself, every whitelisted GPU gets:

- the **RM override** `RM1457588=1` through the `nv_miscBase_addreg__NN` section its install section
  uses (and, since it is applied to all of them, through every other section too);
- the **PhysX / NVIDIA App flags** (`NVSupportPhysx = 1`, `NVSupportGFExperienceUDA = 1`) on its
  install section, so `setup.exe` offers both components - see
  [PhysX and the NVIDIA App](#physx-and-the-nvidia-app);
- the full set of install directives of the closest stock section of that release (copy files,
  services, registry, feature scores), so a section captured from 595.79 does not miss jobs that later
  releases added.

To see whether the GPU in *this* PC is one of the above:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -CheckLocalGpuSupport
```

## What the pipeline does

`Scripts\Invoke-DriverPatchPipeline.ps1` is the orchestrator, and the only script the GUI invokes.
Each step prints a `=== N/M: name ===` banner. The numbering below is a default run from a `.exe`:
`-PruneForeignOemInfs` inserts a step after the unpack and shifts the rest by one, and each `-Skip...`
switch removes one.

Before the first step the run does preflight: it resolves the tools, the signing identity and the
source (see [Source verification](#source-verification)).

1. **Unpacking installer** (or *Copying package*) - a 7z-compatible CLI expands the download into
   `<name>_Patched`. The source `.exe` is never modified.
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
  installer plugin outside the catalog, carry a valid NVIDIA/Microsoft signature of its own.

Anything else stops the run. Microsoft signatures are accepted for catalogs (WHQL countersigns them) but
never for an `.exe` source. `-SkipSourceVerification` overrides the check - it exists for hand-patched
packages - and the GUI asks before using it. `-CheckSource` answers `SOURCE_OK` / `SOURCE_UNTRUSTED`
without running anything.

## Coverage and limits

`whitelist.json` carries **61 entries** covering 51 unique PCI device IDs (see
[Supported GPUs](#supported-gpus)).

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
(`Get-InfDeviceLine` / `Test-InfDeviceIdMatch` in `PatchToolDiscovery.ps1`), so they read a line the
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
is off. Prefer this path: you watch it happen, and it is the one verified end to end. With no `-CerPath`
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

## Installing the patched driver

```powershell
pnputil /add-driver "<name>_Patched\Display.Driver\nv_dispi.inf" /install
```

Use the main display INF that is actually in that folder - its name varies by release
(`nv_dispig.inf`, `nv_dispsi.inf`). Or run `setup.exe` from the patched package root for the full
NVIDIA App installer flow.

Before installing either way, look at every catalog, not at the run's summary line:
`Sign-DriverPackage.ps1` signs the catalogs the INFs declare and **leaves the rest carrying NVIDIA's
original, now-invalidated signature** - on a pruned build that includes the catalogs of the pruned
INFs - and `pnputil`/`setup.exe` pick catalogs by what the INFs declare, not by what this toolkit
signed:

```powershell
Get-ChildItem "<name>_Patched\Display.Driver" -Filter *.cat | ForEach-Object {
    $s = Get-AuthenticodeSignature $_.FullName
    "{0,-24} {1,-10} {2}" -f $_.Name, $s.Status, $(if ($s.SignerCertificate) { $s.SignerCertificate.Thumbprint } else { "(unsigned)" })
}
```

Every catalog an INF in that folder references should show your thumbprint; `NotSigned` or a `NVIDIA`
thumbprint on a referenced catalog means the signing step did not cover it. And only install on a
machine whose GPU is one of the newly-whitelisted IDs in [Supported GPUs](#supported-gpus) - on a
machine that already has a supported card, the added entries simply never match, so the driver behaves
exactly as stock.

## The GUI

`Chameleon-Patcher.exe` is a small WinForms app that runs `Scripts\Invoke-DriverPatchPipeline.ps1` as
a child `powershell.exe` (started from `System32\WindowsPowerShell\v1.0`, not by bare name) and parses
its `=== N/M: ... ===` banners for progress. A field for the driver `.exe`/folder, a **Start Patching**
button, a progress bar with the current step name, a "Show details" toggle that expands to a live
console log, and an **Open log folder** button. On success it asks whether to launch `setup.exe`; on
failure it points at the log for that run.

It passes `-NonInteractive`, because the child has no attached console and a prompt would hang with
the app showing no reason why. With it, any would-be prompt becomes a clear error in the log. In the
normal store-signing case no password is involved at all; if you do type one, it travels in the
child's own environment block (`DRIVER_PATCH_PFX_PASSWORD`), never as a command-line argument, and the
pipeline reads it and removes it from its own block before doing anything else. Until that child exits
the variable is visible to anything running as your user.

The GUI has **no certificate fields by default**: signing uses the key in your certificate store, and
a PC with no key gets a certificate minted automatically. The `.pfx` and password fields appear only
after ticking **"Sign with an existing certificate from a .pfx file"** - that is for signing with a
key exported from another PC, typically one your target machines already trust. Unticking the box
clears the password, and anything left in the fields while it is unticked is ignored. Starting a run
with the box ticked and the file or password missing stops before anything runs and offers to fill
them in or untick the box. When a run stops because the key is not on this PC, the GUI shows the
fields, fills in the newest `Certificates\DriverPatchSigning*.pfx`, and says what to enter. It spots
that case by matching the literal phrase `none was supplied and prompting is disabled` in the child's
output - that phrase is an interface between the C# and the two scripts that raise it
(`Invoke-DriverPatchPipeline.ps1`, `Sign-DriverPackage.ps1`), so rewording the message silently removes
the hint while the run still fails for the same reason.

The GUI asks the pipeline instead of reimplementing its rules (`-ShowOutputPath`,
`-CheckLocalGpuSupport`, `-CheckPatchTools`, `-CheckSource`): the first stdout line of each is a
verdict word. The pipeline forces UTF-8 stdout because a windowless child otherwise writes in the OEM
codepage. Change both sides together if you touch that protocol.

Before a run starts, the GUI checks which external tools this machine can resolve and refuses to begin
when one is missing, naming each tool and offering a button that opens its download page - **Open the
7-Zip download page**, **Open the Windows SDK download page**, or both. Nothing is unpacked and nothing
is changed at that point. The check exists because the catalog rebuild takes tens of minutes: finding
out the SDK is missing after a multi-GB unpack is the expensive order. It then verifies the source and,
if that fails, asks before overriding. Ticking "Build for this PC only" on a machine this toolkit does
not unlock gets a dialog offering the portable build instead, and answering yes unticks the box so the
log header and the output folder name reflect what was actually built.

Closing the window mid-run asks first, then ends the pipeline's `powershell.exe` and everything it
started (7z, Inf2Cat, signtool) and records it; the output folder is left incomplete, so tick "Delete
the output folder first" on the next run - the pipeline never overwrites an output folder and has no
resume, so a partial package can never be mistaken for a finished one. An unexpected error is
recorded, not swallowed: `AppDomain.UnhandledException` and `Application.ThreadException` are hooked,
so an exception escaping an `async void` handler writes a `[crash]` line into the log and shows one
readable dialog instead of taking the app down with the log silent mid-patch.

### Patch logs

Every GUI run writes `Logs\patch-YYYYMMDD-HHMMSS.log` next to the `.exe`, flushed per line so it
survives a crash, a `taskkill`, or a hang. It holds what is needed to diagnose a failure without
reproducing it: the version of this tool that wrote it (read back from the assembly), machine context
(real Windows build from the registry, CLR version, whether the process was elevated), the exact
inputs and full child command line, every line the pipeline emitted stamped with elapsed time, and
the exit code and duration. Because the pipeline prints step banners, the gap between two banners is
how long that step took - the quickest way to see that the catalog rebuild is eating the wall clock.
Closing the window mid-run is recorded explicitly, so an abrupt end is distinguishable from a stall.
The 20 most recent logs are kept; older ones are pruned. Nothing sensitive goes in: the `.pfx`
password is never on the child's command line, and the header records only whether one was supplied.

Running the pipeline directly writes no such file - the logging lives in the GUI wrapper:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "...exe" *> patch.log
```

## Tests

```powershell
.\Tests\Run.ps1
```

Pester 3.4 suites (built into Windows PowerShell 5.1), about 5 s. They build tiny packages,
certificates and catalogs under `%TEMP%`; nothing touches a certificate store and nothing is installed.
Run them before every change and add a test for the behaviour you change. There is no CI - the suite is
run by hand.

## Project layout

```
Chameleon_Patcher\
|- Chameleon-Patcher.exe    <- main app, double-click to run; must stay at the root
|- README.md, CHANGELOG.md, AGENTS.md, LICENSE
|- Source\                  <- source for the one component that ships as a binary
|  |- Chameleon-Patcher.cs     <- the GUI; version attributes live at the top
|  `- Build.ps1                <- rebuilds the .exe into the project root
|- Scripts\                 <- everything the app calls; plain PowerShell, also runnable standalone
|  |- Invoke-DriverPatchPipeline.ps1   <- the orchestrator
|  |- Unpack-DriverExe.ps1             <- 7z-compatible CLI expansion of the download
|  |- Add-ExtraGpuSupport.ps1          <- applies whitelist.json
|  |- Add-RmCapabilityOverride.ps1     <- the RM1457588 VRAM/compute override
|  |- Remove-ForeignOemInfs.ps1        <- the opt-in prune
|  |- Enable-OptionalComponents.ps1    <- PhysX / NVIDIA App feature flags
|  |- Test-DriverPatch.ps1             <- the verification gate
|  |- New-DriverSigningCert.ps1        <- mints the self-signed code-signing cert
|  |- Sign-DriverPackage.ps1           <- Inf2Cat rebuild + signtool
|  |- Add-SetupCertOption.ps1          <- the installer cert-trust checkbox
|  |- Approve-DriverPatchCert.ps1      <- trust the cert, run by hand
|  |- Remove-DriverPatchCert.ps1       <- inventory and withdraw trust
|  |- PatchToolDiscovery.ps1           <- shared helpers, dot-sourced by the others
|  |- whitelist.json                   <- the PCI ID whitelist data
|  `- templates\GpuUnlockCert.nvi.template
|- Tests\                   <- Pester suites; Run.ps1 runs them
|- Assets\                  <- branding; not needed at runtime (Build-Icon.ps1 regenerates .ico/.png)
|- Drivers\                 <- optional: your driver downloads (git-ignored)
|- Logs\                    <- created on first run; one timestamped log per patch attempt
`- Certificates\            <- created automatically the first time a certificate is needed
   |- DriverPatchSigning_<thumbprint>.cer  <- public cert, one per minted certificate
   |- DriverPatchSigning.cer               <- legacy fixed name (pre-1.0.2), still honoured as input
   `- DriverPatchSigning_<thumbprint>.pfx  <- only if you asked for one (-Exportable)
```

`Certificates\` does not have to exist ahead of time - `New-DriverSigningCert.ps1` and the pipeline
create it as a sibling of `Scripts\` on first use. `Logs\`, `Certificates\`, `Drivers\` and the
`*_Patched*` output folders are git-ignored: they are your machine's runtime state, not part of the
project.

Everything under `Scripts\` is plain PowerShell, so it is its own source (ASCII-only and CRLF - a
BOM-less non-ASCII `.ps1` is parsed as ANSI by Windows PowerShell 5.1). `Source\` exists for the one
component that does not read as text once built, so the repository always carries what an `.exe` alone
could not: the commented original and the exact command that produced it.

`PatchToolDiscovery.ps1` is the shared foundation: the external-tool lookups (7-Zip/NanaZip,
`Inf2Cat`, `signtool`) and the install guidance shown when one is missing, GPU detection (prune step,
output-folder tag, pruned-build gate), source verification, signing-certificate resolution, INF
device-line matching, and the INF text primitives every writer inserts through (`Get-InfSectionIndex`
decides where a line lands inside a section, one shared `[section]` header pattern keeps the patchers
and the gate reading sections the same way, `Test-InfLineContinuations` reports trailing-backslash
continuations). It also owns the byte-preserving reader/writer pair described under
[Byte-faithful reading and writing](#byte-faithful-reading-and-writing).

## Version

The version is declared once, as assembly attributes at the top of `Source\Chameleon-Patcher.cs`
(currently **1.0.6**):

```csharp
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.6.0")]
[assembly: AssemblyInformationalVersion("1.0.6")]
```

Everything else reads that one declaration back, so it appears in three places: the **window title
bar** (`Chameleon Patcher 1.0.6`), the file's **Win32 version resource** (`csc.exe` folds it in, no
`.rc` to maintain, so Explorer's Details tab and `(Get-Item Chameleon-Patcher.exe).VersionInfo` show
it), and **every patch log header**, stamped at runtime. Bumping a release means editing those
attributes and rebuilding with `.\Source\Build.ps1`; keep `AssemblyVersion` at `x.y.0.0` and let the
file and informational versions carry the precise one.

One limit, because it is the way the number *can* mislead: the version lives in the compiled GUI,
while everything the GUI runs is plain PowerShell read from `Scripts\` at start time. A run is
therefore identified by the version **plus** the revision of `Scripts\` beside the `.exe`; an `.exe`
in a working tree whose scripts have moved on stamps an older number over newer behaviour. Cutting a
release means a dated `CHANGELOG.md` heading, the bumped attributes, a green `.\Tests\Run.ps1`, a
rebuild, and the rebuilt `.exe` committed in the same commit as the scripts it runs against.

`Source\Build.ps1` is a wrapper around one `csc.exe` call and writes the `.exe` to the **project
root**, not beside itself - that placement is load-bearing, because the app resolves
`Scripts\Invoke-DriverPatchPipeline.ps1` relative to its own folder. It prints the version resource it
produced, so a source/Explorer mismatch surfaces at build time. `/win32icon` embeds
`Assets\Chameleon.ico`, and the app reads that icon back out of its own `.exe` for the window and
taskbar, so no `.ico` needs to sit next to the binary.

## Safety notes

- This adds device/subsystem whitelist entries, one registry override value and the installer
  feature flags. It does not modify the driver binaries (`nvlddmkm.sys` and friends), so it cannot do
  anything to hardware that NVIDIA's driver does not already support at code level - it removes an
  INF-level gate and an internal validation gate, both already reachable in the shipped binary. The
  source must be NVIDIA-signed unless you override that explicitly.
- The signing key is created **non-exportable** and is never written as a key file, so by default
  there is no `.pfx` to leak. Be precise about what that buys: non-exportable means the key cannot be
  extracted as a portable file, not that it cannot be misused. Code running as your user can still ask
  that key to sign something, and the OS's own key-archive path can carry key material off the
  machine. If you opt into `-Exportable`, keep the `.pfx` private - anyone holding it can sign kernel
  drivers that your machine, once you trusted the cert, will accept.
- **Trusting the certificate is the part with real blast radius, not the patching.** Every entry you
  add to `Root` is a self-signed authority this machine accepts code from. Keep the number of trusted
  patch certificates at one, prune what you no longer need - see
  [Cleaning up trusted certificates](#cleaning-up-trusted-certificates) - and turn Test Signing mode
  back off when you are done.
- Applies to your own hardware; nothing here is transmitted anywhere.

## Contributors

- **qron88** - author.
- **Qwen (self-hosted LLM)** - analysis and engineering support on
  [1.0.4](CHANGELOG.md#104---2026-10-12): dependency-bar analysis, tool preflight, and the
  release-verification record.
- **Claude (Anthropic)** - security and correctness review and fixes in 1.0.6.

Licensed under the MIT license - see [LICENSE](LICENSE).
