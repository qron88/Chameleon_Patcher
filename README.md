# Chameleon Patcher

<img src="Assets/Chameleon.png" alt="Chameleon Patcher" width="120" align="right">

Project Chameleon patches a stock NVIDIA driver package so it installs and works properly on GPUs
the package normally does not recognize — chiefly desktop PCI-E expansion cards that carry a
mobile GPU core (laptop RTX 20-, 30- and 40-series and RTX-Ada mobile parts) transplanted onto a
desktop form factor by third-party manufacturers. These are not standard laptop GPUs in a laptop,
nor standard desktop GPUs: they are mobile silicon on a desktop card, a combination the stock
desktop driver's INF whitelist does not cover, so the driver will not install or enumerate them
as-is. (Blackwell coverage is essentially nil: one `DEV_2D00` entry, under a null subsystem ID
that real hardware is unlikely to report.) This is the standard "make the desktop driver see my
transplanted mobile GPU" enthusiast unlock, done reproducibly: point the tool at a downloaded
driver `.exe` and it unpacks, patches, verifies and re-signs it, leaving a plain folder behind.

The patching is built to survive NVIDIA renumbering and renaming INFs between releases, so it is
written for **any** driver version — but only the releases in
[Verified driver releases](#verified-driver-releases) have actually been run end to end. Read that
table before pointing this at a brand-new driver.

Two independent gates have to come off for an unlocked GPU to work, and the patcher handles both:

- **The INF-level PCI ID whitelist.** 61 device/subsystem-ID entries are added to the driver's
  INFs — 58 to `Display.Driver\nv_dispi.inf` (the main desktop INF) and 3 to `nvami.inf` (the
  ASUS OEM INF). All additions, no removals. Most are **generic/OEM subsystem IDs**
  (`SUBSYS_000010DE`, `SUBSYS_44494D50`, `SUBSYS_00000000`); a few are specific real OEM
  subsystem IDs (MSI/ASUS/Lenovo). This is what lets the driver install and the device enumerate.
- **The driver's internal Resource-Manager check.** One registry override,
  `HKR,,RM1457588,%REG_DWORD%,1`, is added to every `nv_miscBase_addreg` AddReg section across the
  driver INFs. Without it a whitelisted GPU installs but misreports VRAM size and has broken
  compute - see [Why VRAM size / compute needs a second fix](#why-vram-size--compute-needs-a-second-fix).

Editing the INFs invalidates `nv_disp.cat`, so the patcher also rebuilds the catalog and re-signs
it with a self-signed code-signing certificate it generates and keeps locally. A patched package
therefore installs only on a machine that trusts that certificate and has Windows Test Signing
mode on - see [Trusting the certificate](#trusting-the-certificate).

`Scripts\whitelist.json` is the data-driven form of those 61 PCI ID whitelist entries (device ID,
subsystem ID, description, and a captured INF section body to use as a template), originally
derived by diffing a stock `Original_Nvidia_595.79...` package against a hand-patched one.

The toolkit needs two things installed on the machine: a 7z-compatible CLI (7-Zip or NanaZip) to
unpack the driver download, and the Windows SDK for `Inf2Cat.exe` and `signtool.exe`. Everything
else is already in Windows, and everything is checked before a run starts - see
[Dependencies](#dependencies).

## Dependencies

Everything the toolkit needs, in one place. Two things have to be installed; the rest of it is
already in Windows 10/11. Nothing here needs internet access to *run* - signing reaches the network
once for an RFC3161 timestamp, and that is best-effort: an unreachable timestamp server leaves the
catalog signed and the run continuing with a warning, and `-SkipTimestamp` skips the attempt
entirely. The one place this toolkit points at the internet is what happens when a dependency is
missing: the refused-run window can open that tool's download page for you (see
[GUI](#the-graphical-interface)), which is your browser asking for internet, not the patcher.

**Install these two**

| Dependency | What it is for | Install |
|---|---|---|
| **7-Zip** (or NanaZip - any 7z-compatible CLI) | Unpacks the driver download. It is the only route. See [Unpacking a driver .exe](#unpacking-a-driver-exe). | <https://7-zip.org/> - or `winget install -e --id 7zip.7zip` from a terminal |
| **Windows SDK**, with **Windows SDK Signing Tools** and **Windows Driver Kit** kept selected - it is the WDK's *Binaries* feature that carries `Inf2Cat.exe` | `Inf2Cat.exe` rebuilds `nv_disp.cat` after the INFs are edited, `signtool.exe` signs what it rebuilds. Neither has a substitute, and nothing else in the SDK is ever run here. A full Windows Driver Kit development environment is **not** needed - those two SDK features are enough. | <https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/> |

Both are resolved automatically before a run starts: the scripts call that a preflight
(`-CheckPatchTools`), the GUI asks the same question before unpacking anything, and a missing one
stops the run with the install command in the message instead of failing halfway through.
`Inf2Cat.exe` and `signtool.exe` are looked for under `%WDKContentRoot%` and
`Windows Kits\10\bin` (newest SDK version first, x64 preferred — `Inf2Cat.exe` ships x86-only) and
then on `PATH`, and can be named directly with `-Inf2CatPath` / `-SignToolPath`. A 7z CLI is looked
for via the WindowsApps `7z.exe` alias, `Program Files\7-Zip`, `Program Files (x86)\7-Zip`,
`Program Files\NanaZip` and then `PATH`, and can be named with `-SevenZipPath`.

Two files have to exist for a run to work, and they come from two features of the SDK install:
`signtool.exe` from **Windows SDK Signing Tools**, and `Inf2Cat.exe` from the **Windows Driver Kit**
content - its *Binaries* feature is the one that carries the tool. Headers, libs, debuggers,
extension SDKs and the rest of what the SDK installer offers are never executed by anything in this
toolkit. On the machine every verified release here was measured on, `Windows Driver Kit`
10.1.28000.2526 sits on top of `Windows SDK` 10.1.28000.2705; the two version numbers differ in
their last digits and that is not a problem, because both put their tools into the same
`Windows Kits\10\bin\10.0.28000.0` tree, and that is where the lookup finds them. `%WDKContentRoot%`
is empty on that machine too - the variable belongs to the WDK's own shell environment, not to a
tool being run from PowerShell - so no environment setup is needed for the patcher, and the fallback
search path is the one in use. Ask your own machine what it has:
`.\Scripts\Invoke-DriverPatchPipeline.ps1 -CheckPatchTools` prints the full path of each tool, or
says which one is missing and how to install it.

### Unpacking a driver .exe

`Unpack-DriverExe.ps1` expands the download with a 7z-compatible CLI and with nothing else, and it
does it in seconds. A machine without one stops there and is told what to install. Point
`-SourcePackagePath` at a folder you unpacked by hand and no CLI is needed at all.

**Already in Windows 10/11 — nothing to install**

- **Windows PowerShell 5.1** (`powershell.exe`) — every `.ps1` here targets it specifically, not
  PowerShell 7+. Two of its quirks are worked around: `$PSScriptRoot` is empty inside a `param()`
  default when a script is launched via `-File`, and `Read-Host -AsSecureString` does not work over
  a redirected stdin pipe. PS 7 is deliberately **not** a dependency (no PS 7-only syntax is used)
  and the test suite runs on 5.1 and 7 alike.
- **.NET Framework 4.x** — `Chameleon-Patcher.exe` is a compiled WinForms app; the runtime is
  present on any normal Windows 10/11 install.
- **`certutil.exe`** — used by `Approve-DriverPatchCert.ps1` and by the `GpuUnlockCert.nvi`
  installer component.
- **The PKI module** (`New-SelfSignedCertificate` / `Export-Certificate` / `Export-PfxCertificate`)
  — used by `New-DriverSigningCert.ps1`.
- **`Get-CimInstance`** — `PatchToolDiscovery.ps1` reads this machine's GPUs through
  `Win32_PnPEntity` for the pruning gate.

**To install what this toolkit produces**

- **Test Signing mode**, plus a certificate the machine trusts: the patched package is signed with a
  self-signed key. See [Trusting the certificate](#trusting-the-certificate).
- **Administrator rights** — `Approve-DriverPatchCert.ps1` (`certutil -addstore`) and running
  `setup.exe` both need them.
- **A driver to patch** — a real NVIDIA download (`.exe` or already-unpacked package). The project
  bundles neither.

**Only needed to rebuild the GUI** (after editing `Source\Chameleon-Patcher.cs`): `csc.exe`, at
`%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`, invoked by `Source\Build.ps1`. That is in
Windows already, so rebuilding needs no install either — see [GUI](#gui).

**Internal dependencies within the project**

- `Invoke-DriverPatchPipeline.ps1` is the orchestrator: it calls the other scripts in sequence, and
  it is the only script `Chameleon-Patcher.exe` invokes.
- `Add-ExtraGpuSupport.ps1` needs `whitelist.json`.
- `Add-SetupCertOption.ps1` needs `templates\GpuUnlockCert.nvi.template`.
- `Sign-DriverPackage.ps1`, `Approve-DriverPatchCert.ps1` and the certificate generation all work
  on `Certificates\DriverPatchSigning_<thumbprint>.cer` (and `.pfx` when you asked for one), and all
  three pick the certificate through one shared routine in `PatchToolDiscovery.ps1` so they cannot
  disagree about which one it is. `Sign-DriverPackage.ps1` reads only the **public** `.cer` to learn
  the thumbprint to sign with; the `.pfx` is touched on the fallback path only.
- `Invoke-DriverPatchPipeline.ps1`, `Unpack-DriverExe.ps1` and `Sign-DriverPackage.ps1` dot-source
  `PatchToolDiscovery.ps1`.

**Expect the catalog rebuild to dominate the runtime.** `Inf2Cat.exe` is a single-threaded 32-bit
tool that re-validates the whole `Display.Driver` folder once per INF, and a real package has ~43
INFs over ~2.7 GB, so the "Rebuilding + signing catalog" step (7 of 9 in a default run, and one
lower each time you start from an already-unpacked folder or pass a `-Skip...` switch) can run for
tens of minutes at 100% of one core while every other step finishes in seconds. Nothing is wrong
when it appears to sit on `Processing INF:` for a long time.

## Project layout

```
Chameleon_Project\
├─ Chameleon-Patcher.exe    <- main app, double-click to run; must stay at the root
├─ README.md
├─ Source\                  <- source for the one thing here that ships as a binary
│  ├─ Chameleon-Patcher.cs     <- the GUI; version attributes live at the top
│  └─ Build.ps1                <- rebuilds the .exe into the project root
├─ Logs\                    <- created on first run; one timestamped log per patch attempt
├─ Assets\                  <- branding; not needed at runtime
│  ├─ Chameleon.ico            <- embedded into the .exe at build time
│  ├─ Chameleon.png            <- logo with transparency
│  ├─ Chameleon-source.jpg     <- the original artwork
│  └─ Build-Icon.ps1           <- regenerates the .png and .ico from the source
├─ Scripts\                 <- everything the app calls; also runnable standalone
│  ├─ Invoke-DriverPatchPipeline.ps1
│  ├─ Unpack-DriverExe.ps1
│  ├─ Add-ExtraGpuSupport.ps1
│  ├─ Add-RmCapabilityOverride.ps1
│  ├─ Remove-ForeignOemInfs.ps1
│  ├─ Enable-OptionalComponents.ps1
│  ├─ Test-DriverPatch.ps1
│  ├─ New-DriverSigningCert.ps1
│  ├─ Sign-DriverPackage.ps1
│  ├─ Add-SetupCertOption.ps1
│  ├─ Approve-DriverPatchCert.ps1
│  ├─ Remove-DriverPatchCert.ps1
│  ├─ PatchToolDiscovery.ps1
│  ├─ whitelist.json
│  └─ templates\GpuUnlockCert.nvi.template
└─ Certificates\            <- created automatically the first time a cert is needed
   ├─ DriverPatchSigning_<thumbprint>.cer  <- public cert, one file per minted certificate
   ├─ DriverPatchSigning.cer   <- legacy fixed name (versions before 1.0.2); still honoured
   └─ DriverPatchSigning_<thumbprint>.pfx  <- only if you asked for one (-Exportable)
      (the legacy fixed name is still honoured as an input; it is no longer written)
```

There is **no `Tests\` folder in this repository.** The four Pester files the [Tests](#tests)
chapter describes were lost on the machine they were written on and never committed, so nothing
under `Tests\` exists to run and `Invoke-Pester` finds nothing. Read that chapter as the
specification of the suite, not as a description of this tree.

`Certificates\` doesn't need to exist ahead of time - `New-DriverSigningCert.ps1` and
`Invoke-DriverPatchPipeline.ps1` both create it automatically (as a sibling of `Scripts\`) the
first time a certificate is generated there.

Everything under `Scripts\` is plain PowerShell, so it is its own source. `Source\` exists for the
one component that does not read as text once built - the compiled GUI - so the repository always
carries what an `.exe` alone could not tell you: the commented original and the exact command that
produced it. `Assets\` is the same idea for the artwork, keeping `Chameleon-source.jpg` and the
script that regenerates the `.ico` and `.png` from it.

## Files

| File | Purpose |
|---|---|
| `Chameleon-Patcher.exe` | GUI wrapper around the pipeline below - see [GUI](#gui). Carries the project version in its Win32 version resource. |
| `Source\Chameleon-Patcher.cs` | The GUI's source. Version attributes sit at the top of the file and are the single place the release number is declared - see [Version](#version). |
| `Source\Build.ps1` | Rebuilds the `.exe` into the project root with `csc.exe` and prints the version resource it produced. |
| `Scripts\Invoke-DriverPatchPipeline.ps1` | All-in-one: unpack → patch → sign → add the installer checkbox, and prune old signing keys from `Cert:\CurrentUser\My` (see `-KeepAllOldCerts`). Takes either a raw downloaded `.exe` or an already-unpacked folder; result is always a plain folder. |
| `Scripts\Unpack-DriverExe.ps1` | Extracts a downloaded driver `.exe` (a 7-Zip SFX) into a plain folder using a 7z-compatible CLI - 7-Zip, NanaZip, or any `7z` on `PATH`. That is the only route: a machine without one is stopped and told what to install. |
| `Scripts\Add-ExtraGpuSupport.ps1` | Applies `whitelist.json` to a stock `Display.Driver` folder. Does not hardcode section numbers, so it survives INF renumbering between releases, and resolves INF *filenames* by stem so it survives them being renamed too — see [When NVIDIA renames the INFs](#when-nvidia-renames-the-infs). Written for any driver version; only the releases in [Verified driver releases](#verified-driver-releases) have been run end to end. |
| `Scripts\Add-RmCapabilityOverride.ps1` | Adds the `RM1457588` registry override to every `nv_miscBase_addreg__*` section in every driver INF - fixes VRAM size misreporting and broken compute on whitelisted GPUs. See [below](#why-vram-size--compute-needs-a-second-fix). |
| `Scripts\Remove-ForeignOemInfs.ps1` | Drops the OEM display INFs that cannot match this machine, taking the catalog rebuild from ~50 min to ~7. Opt-in via `-PruneForeignOemInfs`. The catalog and filter files that share a pruned INF's stem stay where they are, manifest entry included, and the step says so rather than deciding for you. See [Making a run finish in minutes](#making-a-run-finish-in-minutes-instead-of-an-hour). |
| `Scripts\Enable-OptionalComponents.ps1` | Makes PhysX and the NVIDIA App offered for the unlocked GPUs, and the NVIDIA App unticked-able. See [PhysX and the NVIDIA App](#physx-and-the-nvidia-app). |
| `Scripts\Test-DriverPatch.ps1` | Verifies a package really was patched, and is run **before signing** so a silently-unpatched package can't be signed and shipped as finished. See [The verification gate](#the-verification-gate). Also runnable standalone against any package. |
| `Scripts\New-DriverSigningCert.ps1` | Generates a fresh, locally-owned self-signed code-signing cert (does **not** touch system trust stores). The key is **non-exportable** and stays in `Cert:\CurrentUser\My`, so there is no `.pfx` and no password at all. `-Exportable` opts into a portable `.pfx`. Defaults to a 3-year life. It will not overwrite a `.cer` or `.pfx` that already exists, and it will not mint a second valid certificate under a subject already in the store unless you pass `-Force` - see [Renaming the certificate](#renaming-the-certificate). |
| `Scripts\Sign-DriverPackage.ps1` | Rebuilds `nv_disp.cat` from the patched INFs (`Inf2Cat.exe`) and signs it (`signtool.exe`) with your cert. Signs **without any password** when the key is in your certificate store — see [Signing without a password](#signing-without-a-password). Which catalogs count as current is decided by comparing the `.cat` files in the folder with what was there before the rebuild: what Inf2Cat wrote or rewrote is signed, a catalog whose **same-stem INF** is still in the folder is signed with a warning that Inf2Cat did not regenerate it, and anything else is named and left unsigned rather than dressed up as current. That pairing is by filename, and catalog names actually come from the INF's `[Version] Catalog…` directives, not from the INF's filename - so check the signature of every `.cat` in `Display.Driver` after a run (see [Installing the patched driver](#installing-the-patched-driver)) rather than trusting the green summary. |
| `Scripts\PatchToolDiscovery.ps1` | Shared lookup for the external tools (7-Zip/NanaZip, `Inf2Cat.exe`, `signtool.exe`) and for the install guidance shown when one is missing, dot-sourced by the others. The pipeline resolves all three before copying anything, so a missing SDK or a missing 7-Zip fails in seconds instead of after a multi-GB copy. Also owns the routines every script must agree on: GPU detection (prune step, output-folder tag, pruned-build gate), signing-certificate resolution (pipeline, `Sign-DriverPackage.ps1`, `Approve-DriverPatchCert.ps1`), INF device-line matching (patcher, prune step, optional components, verification gate), and the `Remove-OldDriverPatchCerts` cleanup of old signing keys. It also owns the INF text primitives every writer inserts through: `Get-InfSectionIndex` decides where a new line lands inside a section, the shared `[section]` header pattern keeps the patchers and the gate reading sections the same way, and `Test-InfLineContinuations` reports trailing-backslash continuations. `Test-DriverPackageRoot` is the one test both the unpack step and the pipeline use to decide whether a folder is a driver package. |
| `Scripts\Add-SetupCertOption.ps1` | Adds a "Chameleon GPU cert." component to `setup.exe`'s Custom Installation Options screen, **ticked by default** and still user-selectable; `-Unchecked` makes it opt-in. Left ticked, it trusts the certificate in `Root` and `TrustedPublisher`, like `Approve-DriverPatchCert.ps1`. The label lives in `templates\GpuUnlockCert.nvi.template`, the same string in every locale. `-ExpectThumbprint` (default: the certificate that actually signs the package's `.cat` files) must match the `.cer` being bound, or the step throws. The checkbox hands whatever it is given to `Root` and `TrustedPublisher`, so this is what keeps an unrelated key out of the machine trust store. |
| `Scripts\Approve-DriverPatchCert.ps1` | Standalone alternative to the installer checkbox: trusts the cert via a separate, explicit script you run yourself. Adds `Root` (makes the chain work) and `TrustedPublisher` (installs without a device-software prompt). By default it trusts the certificate the pipeline signs with. |
| `Scripts\Remove-DriverPatchCert.ps1` | The counterpart to the above. Inventories every patch certificate and which stores it sits in, and removes the ones you pick. Read-only until you ask it to delete. See [Cleaning up trusted certificates](#cleaning-up-trusted-certificates). |
| `Scripts\whitelist.json` | The device/subsystem whitelist data the patcher applies. |
| `Scripts\templates\GpuUnlockCert.nvi.template` | The verified-working installer-component manifest `Add-SetupCertOption.ps1` copies into each patched package. |
| *nothing under `Tests\`* | The four Pester files described in [Tests](#tests) are **not in this repository**: they were lost before any of them was committed. The behaviour they cover is described there as a specification, and is currently checked by hand rather than by a runnable suite. |
| `Certificates\DriverPatchSigning_<thumbprint>.cer` / `.pfx` | Your signing certificate (created on first use). Versions before 1.0.2 wrote a fixed-name `DriverPatchSigning.cer`; both names are honoured. If the folder is deleted, the pipeline finds the key in your certificate store anyway and re-exports the `.cer` - see [Signing without a password](#signing-without-a-password). |

Unpacking a downloaded `.exe` is done by a 7z-compatible CLI - this machine has NanaZip (a
7-Zip-compatible Store app), auto-detected through the `7z.exe` WindowsApps alias, and a plain
7-Zip install under Program Files is found the same way. With neither installed the run stops and
prints the command that installs one, so 7-Zip is a requirement rather than a speed option. The
other dependency you must install is the Windows SDK - see [Dependencies](#dependencies).

## GUI

`Chameleon-Patcher.exe` wraps the whole pipeline in a small Windows app - no PowerShell command
line needed. A field for the driver `.exe`/folder, a "Start Patching" button, a progress bar with
the current step name, a "▼ Show details" toggle that expands to a live console log, and an
"Open log folder" button. On
success it asks whether to launch `setup.exe` right away; on failure it points you at the log for
that run - see [Patch logs](#patch-logs).

Four checkboxes, and what each one maps to in the pipeline:

| Checkbox | Default | What it does |
|---|---|---|
| Sign with an existing certificate from a .pfx file | off | Adds `-PfxPath` and, when you type a password, hands it through the child's environment. See below. |
| Add a certificate-trust checkbox to the installer, ticked by default (recommended) | **on** | Leave it on and the run adds the `GpuUnlockCert` component as usual; untick it and the run passes `-SkipSetupCertOption`, so `setup.exe` makes no trust changes and `Approve-DriverPatchCert.ps1` stays a separate step. |
| Build for this PC only - much faster, but not portable to other machines | off | `-PruneForeignOemInfs`. See [A pruned build needs a GPU worth pruning for](#a-pruned-build-needs-a-gpu-worth-pruning-for). |
| Delete the output folder first if it already exists | off | When the output folder exists and this is off, the run stops and says so. When it is on, the app asks once more - "This will permanently delete: …" - and only then removes the folder. |

The GUI passes exactly those switches (plus `-NonInteractive`, so no script can block on a prompt the
window cannot answer). Everything else is command-line only: `-SkipOptionalComponents`,
`-SkipPatchVerification`, `-KeepAllOldCerts`, `-KeepInf`, `-PruneForeignOemInfs` options such as
`-IgnoreLocalHardware`, `-SkipTimestamp`, and the tool-path overrides. PhysX/NVIDIA App enabling and
patch verification therefore always run in a GUI run, and there is no GUI route to `-ReportOnly` on
the gate.

Closing the window while a run is in progress asks first, then stops the run: the pipeline's
`powershell.exe` and everything it started (7z, Inf2Cat, signtool) are ended together, and the log
records it. The output folder is left incomplete, so tick "Delete the output folder first" on the
next run.

It must stay at the project root - it locates `Scripts\Invoke-DriverPatchPipeline.ps1` relative
to its own folder. Internally it just runs that same script as a child `powershell.exe` process
and parses its `=== N/M: ... ===` step banners for progress.

It passes `-NonInteractive`, because the child has no attached console and any prompt would hang
with the GUI showing no reason why (`Read-Host -AsSecureString` does not reliably read from a
redirected stdin pipe without a real console). With `-NonInteractive` the pipeline turns any
would-be prompt into a clear error that appears in the log instead. In the normal store-signing
case no password is involved at all. If you do type one, it travels in an environment variable set
on the child's own environment block (`$env:DRIVER_PATCH_PFX_PASSWORD` there), never as a command-line
argument; the pipeline converts it to a secure string and clears the variable from its own block as
soon as it has done so. Two caveats on that, both worth knowing if you are auditing a run: the
variable is set whenever you typed a password, even when the run ends up not needing one because the
key was in the store - the pipeline only clears it on the branch that reads it - and it stays in the
child process's environment until that child exits, which on a long catalog rebuild is tens of
minutes. Anything running as your user can read a process's environment block.

The GUI spots that particular error by looking for the phrase `none was supplied and prompting is
disabled` in the child's output, and then offers the `Import-PfxCertificate` line that fixes it
permanently. The phrase is therefore an interface between the C# and the two scripts that raise it
(`Invoke-DriverPatchPipeline.ps1`, `Sign-DriverPackage.ps1`), not prose: reword the message and the
hint silently stops appearing, with the run still failing for the same reason. All three live in
this repository, so keep the wording in sync when editing either side.

Ticking "Build for this PC only" on a machine whose GPU this patcher doesn't unlock gets a dialog
before the run starts, offering the portable build instead - see [A pruned build needs a GPU worth
pruning for](#a-pruned-build-needs-a-gpu-worth-pruning-for). Answering yes unticks the box, so the
log header and the output folder name both reflect what was actually built.

Before a run starts, the GUI asks the pipeline which external tools this machine can resolve
(`-CheckPatchTools`) and refuses to begin when any of the three is missing: `Inf2Cat.exe` and
`signtool.exe` have no substitute, and a 7z-compatible CLI is what unpacks the driver download.
The dialog names each missing tool, points at the page that installs it, and says plainly that nothing
has been unpacked and nothing was changed. It is laid out like the message box it replaced - error
icon, system font, buttons bottom right - with the message as plain text, plus one button a message
box cannot carry: **Open the 7-Zip download page**, **Open the Windows SDK download page**, or
**Open both download pages** when both are needed, and it opens the page in the default browser - so
that one convenience needs internet access, while the patching itself does not. It is a button, not a
requirement: close the window and install whatever is missing any way you like. The console answer to
the same question (`-CheckPatchTools`, and the message a script throws) keeps the `winget` command as
well, because whoever is already in a terminal can use it. When
both
SDK tools are missing they are described once, as one package to fetch. That check exists because
the catalog rebuild is the step
that takes tens of minutes - finding out the SDK is absent after a multi-GB unpack is the expensive
order. Once the tools are there, the status line says which 7z CLI the run will unpack with.
See [Dependencies](#dependencies).

An unexpected error is recorded, not swallowed. `AppDomain.UnhandledException` and
`Application.ThreadException` are both hooked, so an exception escaping an `async void` handler
writes a `[crash]` line into the run log and shows one readable dialog, instead of taking the app
down as a raw Win32 crash and leaving the log silent mid-patch.

There are **no certificate fields by default** - signing uses the key already in your certificate
store, with no password, and a PC with no key gets a new certificate minted automatically. The
`.pfx` file and password fields appear only after ticking **"Sign with an existing certificate
from a .pfx file"**. That is for signing with a certificate exported from another PC - typically
one your target machines already trust - instead of the key on this PC or a newly minted one. A
fresh PC with no key needs nothing ticked. The expanded section spells out both states. While the
box is unticked anything left in those fields is ignored, and unticking it clears the password.
Starting a run with the box ticked but the `.pfx` file or its password missing stops before
anything runs and offers either to go back and fill them in or to untick the box and sign the
normal way. If a run stops because the key is not on this PC and a `.pfx` password is needed, the
GUI shows the fields and fills in the newest `Certificates\DriverPatchSigning*.pfx` in that folder -
the exports are named after the certificate's thumbprint - and says what to enter. See [Signing without a password](#signing-without-a-password).

It's a self-contained `.exe` compiled from `Source\Chameleon-Patcher.cs` via the .NET Framework's
built-in `csc.exe` (no external tools, no internet needed) - rebuild after editing the source with:

```powershell
.\Source\Build.ps1
```

which is a wrapper around one `csc.exe` call:

```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /target:winexe /out:Chameleon-Patcher.exe /win32icon:Assets\Chameleon.ico /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /platform:x64 Source\Chameleon-Patcher.cs
```

`Build.ps1` writes the `.exe` to the **project root**, not beside itself, and that placement is
load-bearing: the app resolves `Scripts\Invoke-DriverPatchPipeline.ps1` relative to its own folder,
so a binary left in `Source\` would look for `Source\Scripts\` and fail at launch. It also prints
the version resource it produced, so a mismatch between the source attributes and what Explorer
shows surfaces at build time rather than after a release.

`/win32icon` embeds `Assets\Chameleon.ico` as the file icon, and the app reads that same icon back
out of its own `.exe` for the window and taskbar, so no `.ico` has to sit next to the binary.

### Version

The version is declared once, as assembly attributes at the top of `Source\Chameleon-Patcher.cs`:

```csharp
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.5.0")]
[assembly: AssemblyInformationalVersion("1.0.5")]
```

Everything else reads that one declaration back, so the number appears in three places and cannot
drift between them:

**1. The window title bar**, which is the quickest check and makes a screenshot self-identifying:

```
Chameleon Patcher 1.0.5
```

**2. The file's Win32 version resource.** `csc.exe` folds the attributes in by itself - there is no
`.rc` file to maintain - so the number shows in Explorer's **Details** tab, and in:

```powershell
(Get-Item Chameleon-Patcher.exe).VersionInfo | Select-Object FileVersion, ProductVersion, ProductName
```

**3. Every patch log header**, stamped from the assembly at runtime rather than from a repeated
literal, so a log and the binary that wrote it cannot disagree:

```
=== Chameleon Patcher - patch log ===
started        : 2026-10-23 09:12:44 +02:00
version        : 1.0.5
```

The log line matters because a patched driver package carries no trace of which build of this tool
made it. Bumping a release means editing those three attributes and rebuilding; nothing else
refers to the number. Keep `AssemblyVersion` at `x.y.0.0` and let the file and informational
versions carry the precise one.

One limit worth knowing, because it is the one way the number *can* mislead: the version lives in
the compiled GUI, while everything the GUI actually runs is plain PowerShell read from `Scripts\`
at start time. A run is therefore identified by the version **plus** the revision of `Scripts\`
next to the `.exe`. A `.exe` sitting in a working tree whose scripts have moved on since the last
release stamps an older number over newer behaviour, so a bug report quoting it can point at the
wrong code. Before treating a version in a log as the whole truth, check it against
[CHANGELOG.md](CHANGELOG.md): the newest dated heading is the number a log should match, and anything
committed after that heading - including anything parked under the `Unreleased` heading a release cut
leaves empty - is newer than the number the log carries. Cutting a release means a `CHANGELOG.md`
heading with a date, the
bumped attributes, a rebuild with `Source\Build.ps1`, and the rebuilt `.exe` committed in the same
commit as the scripts it runs against.

### Patch logs

Every run through the GUI writes a log to `Logs\patch-YYYYMMDD-HHMMSS.log`, next to the `.exe`.
The on-screen details panel disappears when you close the window, which is exactly when a failed
patch needs looking at, so the same stream also goes to disk. If a run fails, the app tells you
where the log is and offers to open it; the **Open log folder** button opens the most recent one
with it already selected in Explorer.

A log holds everything needed to diagnose a failure without reproducing it:

- Which build of this tool wrote it, read back from the assembly's own version attributes.
- Machine context - real Windows build (read from the registry, because `Environment.OSVersion`
  reports 6.2.9200 to unmanifested apps and would otherwise claim Windows 8), CLR version, and
  whether the process was elevated.
- The exact inputs and the full child command line, so the run can be repeated by hand.
- Every line the pipeline emitted, stdout and stderr, each stamped with elapsed time since the
  child started. Because the pipeline prints `=== N/M: ... ===` banners, the gap between two
  banners is how long that step took - the quickest way to see that the catalog rebuild is eating
  the wall clock rather than something being stuck.
- Exit code, duration, and a short pointer on where to start reading.

Writes are flushed per line rather than buffered to the end, so the log survives a crash, a
`taskkill`, or a hang partway through - not just a clean failure. Closing the window mid-run
stops the pipeline and records that explicitly, so an abrupt end is distinguishable from a stall. The 20 most recent logs
are kept and older ones are pruned automatically.

Nothing sensitive is written. The `.pfx` password never appears on the child's command line in the
first place (it travels in an environment variable), and the log header records only whether one
was supplied, never its value.

Running the pipeline directly from PowerShell does not produce one of these files - the logging
lives in the GUI wrapper. Redirect the script's output instead:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "...exe" *> patch.log
```

## Usage (recommended: the all-in-one pipeline)

Point it straight at a downloaded driver `.exe` — this is the normal case:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "D:\Downloads\610.88-desktop-win10-win11-64bit-international-dch-whql.exe"
```

One command: unpacks the download (never touches the source `.exe`), applies the
device/subsystem whitelist, applies the RM capability override, **verifies the patches actually
applied**, reuses (or first generates) a signing cert, rebuilds and signs `nv_disp.cat`, and adds
the "Chameleon GPU cert." installer checkbox, ticked by default (`-SkipSetupCertOption` leaves it
out). Output goes to a plain folder, `<basename>_Patched` next to the
source.

Re-run exactly that same command for each NVIDIA driver release. You do **not** need to
pass a certificate or a password: the pipeline finds your existing signing key in
`Cert:\CurrentUser\My` on its own and signs with it, so every release keeps using the same
already-trusted certificate instead of minting a new one you'd have to re-trust. A release listed
in [Verified driver releases](#verified-driver-releases) is a known-good run; on an unlisted one,
watch the `Patch verification PASSED` line before you trust the output. Before it copies
anything it prints which tools and which certificate it resolved:

```
Preflight: checking tools and signing identity...
  7z:       C:\Users\Kuba\AppData\Local\Microsoft\WindowsApps\7z.exe
  Inf2Cat:  C:\Program Files (x86)\Windows Kits\10\bin\10.0.28000.0\x86\Inf2Cat.exe
  signtool: C:\Program Files (x86)\Windows Kits\10\bin\10.0.28000.0\x64\signtool.exe
  cert:     2A4A4A0C6666E4CD1E59E04CBF4EAFCB06843EA8 (from certificate store - no password needed)
```

A machine with no 7z-compatible CLI gets a different answer, and nothing is unpacked:

```
TOOLS_MISSING
  Inf2Cat:  C:\Program Files (x86)\Windows Kits\10\bin\10.0.28000.0\x86\Inf2Cat.exe
  signtool: C:\Program Files (x86)\Windows Kits\10\bin\10.0.28000.0\x64\signtool.exe
  7z:       NOT FOUND

A 7z-compatible CLI is required to unpack a driver .exe, and none is installed. 7-Zip is free and
lives on its own download page:

    https://7-zip.org/

    From a terminal, the same install is:
        winget install -e --id 7zip.7zip

NanaZip, or any 7z-compatible CLI on PATH, is found the same way once it is installed. The other way
through is -SourcePackagePath: unpack the driver yourself and hand this toolkit the folder it
produced.

The GUI prints this same guidance without the terminal command, and puts a button next to it that
opens the address.
```

Ask the same question on its own, without patching anything:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -CheckPatchTools
```

Prints `TOOLS_OK` or `TOOLS_MISSING` with each resolved path, and the install guidance for anything
that is missing. The GUI runs this before it starts a patch.

If you already have an unpacked folder instead of the `.exe`, use `-SourcePackagePath` instead -
same pipeline minus the unpack step:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourcePackagePath "D:\NVIDIA\610.xx-desktop-win10-win11-64bit-international-dch-whql"
```

Use `-SkipSetupCertOption` to leave `setup.cfg` untouched and use `Approve-DriverPatchCert.ps1`
(or `pnputil`) separately instead.

### Doing it step by step instead

Equivalent to what the pipeline does, if you want to inspect or customize each stage (run these
from inside `Scripts\`, or adjust the paths accordingly):

```powershell
cd Scripts
.\Unpack-DriverExe.ps1 -ExePath "610.88-....exe" -OutputPath "610.88_Patched"
.\Add-ExtraGpuSupport.ps1 -DisplayDriverPath "610.88_Patched\Display.Driver"
.\Add-RmCapabilityOverride.ps1 -DisplayDriverPath "610.88_Patched\Display.Driver"
.\Enable-OptionalComponents.ps1 -PackageRoot "610.88_Patched"
.\Test-DriverPatch.ps1 -DisplayDriverPath "610.88_Patched\Display.Driver"
.\New-DriverSigningCert.ps1
.\Sign-DriverPackage.ps1 -DisplayDriverPath "610.88_Patched\Display.Driver"
.\Add-SetupCertOption.ps1 -PackageRoot "610.88_Patched" -CerPath "..\Certificates\DriverPatchSigning_<thumbprint>.cer"
```

`Enable-OptionalComponents.ps1` edits INFs too, so the gate has to run **after** it, not before - a
package whose feature flags were added after verification is a package whose catalog was built from
INFs the gate never saw. `-PruneForeignOemInfs` is the same story one step earlier: the pipeline runs
`Remove-ForeignOemInfs.ps1` straight after unpacking and before any patching, and hands every later
step the list of names it removed (`-PrunedInf`) so their absence reads as a note instead of a warning.

`Sign-DriverPackage.ps1` needs no certificate arguments once `New-DriverSigningCert.ps1` has run
once: it finds the key in your certificate store by itself. Pass `-CertThumbprint` to pick a
specific certificate, or `-PfxPath` to sign on a machine that has only the `.pfx`.

Run `Add-RmCapabilityOverride.ps1` **before** signing - it edits the same INFs that get hashed
into `nv_disp.cat`, so signing first would just produce a catalog that no longer matches the
files (Windows would refuse to load the driver at all, not just misreport VRAM/compute).

## The verification gate

Signing is the point of no return for a mistake. `Inf2Cat` will happily build a catalog out of
unpatched INFs, and `signtool` will happily sign it, so a package whose patch step quietly found
nothing to do comes out the far end looking completely finished. It installs, the device
enumerates, and the unlock simply isn't there - and nothing about the finished package says so.

`Test-DriverPatch.ps1` closes that hole. The pipeline runs it as step 5 (6 with
`-PruneForeignOemInfs`), between patching and
signing, and refuses to continue if anything is wrong. It re-reads the patched INFs and asserts:

- Every INF named in `whitelist.json` resolves to a file in the package - by exact name or through
  the rename tiers below - and each resolved file has at least one `[NVIDIA_Devices*]` block.
- Every whitelist entry's PCI device and subsystem ID is actually whitelisted, in every
  `[NVIDIA_Devices*]` block of the INF.
- Each device line points at an install Section that **exists** in the same INF.
- Every section a spliced-in `SectionExtraGPU*` body references resolves in that INF.
- Every `%token%` a device line uses is defined in `[Strings]`.
- Every `[nv_miscBase_addreg__NN]` section carries the `RM1457588` override.

Two limits on that list, both worth knowing before reading a green verdict as proof:

- The RM bullet tests for the text `RM1457588` anywhere in the misc section body - **including on a
  comment line** - rather than for the directive `HKR,,RM1457588,%REG_DWORD%,1` on a non-comment line.
  A section whose only mention of the key is `; upstream note: RM1457588 …` satisfies it.
  `Add-RmCapabilityOverride.ps1` decides whether a section already carries the override with the same
  loose substring test, so patcher and gate can agree that the value is present when nothing writes it,
  and the package then installs, enumerates and reports `PASSED` while carrying exactly the VRAM-size
  and compute symptoms the override exists to fix (see [Why VRAM size / compute needs a second
  fix](#why-vram-size--compute-needs-a-second-fix)). The whitelist bullets, by contrast, assert the
  syntax they check for.
- The reference-resolution bullet walks the bodies of the spliced-in `SectionExtraGPU*` sections, and
  the exists-check covers the section the matched device line points at. When a whitelisted entry
  reuses an existing stock section - which is the usual case, because the patcher prefers a section
  already valid for that chip - the `AddReg` / `CopyFiles` / `AddService` targets inside that stock
  section are not audited. Only the spliced families are.

Everything on that list is a hard failure, with one exception worth stating plainly. A whitelist INF
that has vanished under every name the tiers can reach used to be a **warning**: the run said
`PASSED` and the entries filed under that key were simply left out of the `N/N` count. Those are the
entries nobody checked, and they are the ones that decide whether the GPU works, so it is an error
now. A pruned build is not affected - the pipeline records which whitelist INFs the prune step
removed and hands them to every step after it as `-PrunedInf`, where they read as the plain note
they were, and the gate run on its own takes the same switch for the same reason. What the error
catches is what the warning used to let through: a universal build that lost `nv_dispi.inf` to a
rename nothing can resolve, passing at `0/0` with one stderr line as its only trace. Read the gate's
numbers, not just its colour. A file that **is** present but has no `[NVIDIA_Devices*]` block at
all, and a package with no `nv_miscBase_addreg__*` section anywhere, are both hard failures too,
because either one means the INF layout is not what the patcher expects.

Run it yourself against any package, patched or not:

```powershell
.\Scripts\Test-DriverPatch.ps1 -DisplayDriverPath "610.88_Patched\Display.Driver"
```

Add `-ReportOnly` to inspect without failing. `-SkipPatchVerification` on the pipeline bypasses
the gate, but there is rarely a good reason to.

**How device lines are matched.** A real device line reads

```
%NVIDIA_DEV.1E90% = Section001, PCI\VEN_10DE&DEV_1E90&SUBSYS_000010DE
```

with the install section **before** the hardware ID. Lines are matched on the DEV and SUBSYS pair,
not on the `%key%` name, because NVIDIA may already whitelist a given device upstream in a later
release. In that case `Add-ExtraGpuSupport.ps1` skips it and the entry is present under NVIDIA's
own line. What matters is that the combination is whitelisted, not who put it there.

The patcher, the gate, the prune step and the optional-components step all use one parser and one
matching rule (`Get-InfDeviceLine` / `Test-InfDeviceIdMatch` in `PatchToolDiscovery.ps1`), so they
cannot disagree about whether an entry is there:

- A trailing `; comment` is ignored.
- For "is this whitelist entry present", the hardware ID must be exactly that DEV/SUBSYS. A stock
  `...&SUBSYS_X&REV_A1` line only matches revision A1, so the patcher adds its own line and the
  gate looks for exactly that.
- Presence is judged per `[NVIDIA_Devices*]` block. Each block serves a different OS target, so an
  entry NVIDIA lists in one block only is added to the others, pointing at the same section.

"Shared rule" means shared *matching function*, not a shared model of the file, and the difference
shows up in three places:

- The patcher treats every physical `[NVIDIA_Devices…]` header as its own block, while the gate merges
  the bodies of repeated headers with the same name (which is what the INF compiler does). A release
  that extends a models section by repeating its header is therefore read as two blocks by the patcher
  and as one by the gate: the patcher really does put the entry in both physical blocks, but the gate
  reports the merged body and so cannot tell a package where both blocks got the line from one where
  only the first did. The per-block guarantee above is enforced by the patcher and is not what the
  gate measures.
- `[Strings]` is found only by an exact `[Strings]` header. An INF that defines its descriptions in a
  `[Strings.NTamd64]`-style variant gets its `%token%` inserted by the patcher without the definition
  being found, while the continuation scanner already treats `Strings.<something>` as in scope, so the
  gate then reports the token as undefined.
- The whitelist side of the comparison is case-sensitive: entries come out of `whitelist.json` exactly
  as written and are compared against the upper-cased value parsed from the INF. Today's
  `whitelist.json` is all upper case, so this holds by hand-maintenance rather than by construction -
  a lower-case `dev`/`subsys` added by hand or generated from another source simply stops matching,
  and the patcher writes the lower-case value straight into the INF.

The two patchers also fail loudly rather than shrugging. `Add-ExtraGpuSupport.ps1` throws if
an INF has no `[NVIDIA_Devices*]` block at all, and `Add-RmCapabilityOverride.ps1` throws if no
INF in the package has an `[nv_miscBase_addreg__NN]` section. Both of those mean "this driver
release's layout is not what this script understands", which is worth stopping for.

A package can also be *partly unreadable* rather than wrong, and the gate says so instead of
certifying only what it managed to see. INF lines may be continued with a trailing backslash, and
every matcher in this toolkit reads one physical line at a time, so a device entry, a `[Strings]`
definition or an `RM1457588` override split across two lines is invisible to the very check that
just certified it. The gate reports how many such lines sit inside the sections it patches, and
where, as a warning. It does not fail the run - whether a given continuation matters is a human
judgement - but it puts the possibility on the record before signing rather than leaving it to turn
up as a missing unlock afterwards.

## Tests

**Status first: this repository contains no tests.** The `Tests\` folder described below was lost on
the machine the 1.0.5 work was done on, before any of it was committed, and this repository's history
holds no earlier copy of it either — there is nothing to restore from git and nothing for
`Invoke-Pester` to run. What follows is therefore the **specification** of the suite: what it covered
when it existed, and what it would have to cover again. Until it is rebuilt, the text handling that
decides where a line lands in an INF is checked by reading the code and by real driver runs, not by a
test run.

The parts of this toolkit that decide *where a line goes in an INF* are pure text handling, which
means they can be tested without a driver download, a certificate, or a machine willing to boot the
result. That is what `Tests\` was for:

```powershell
# The layout the suite is meant to have; on this checkout these commands find nothing to run.
Invoke-Pester Tests                                # all four files
Invoke-Pester Tests\InfPatchIntegrity.Tests.ps1    # just the end-to-end one
```

`PatchToolDiscovery.Tests.ps1` covered the shared helpers, one behaviour per case: the section-index
walk that decides whether an inserted line lands with the section body or in the blank gap before
the next header; device-line matching, including a trailing comment and a `&REV_` line that must not
count as the same hardware ID; `whitelist.json`-to-INF filename resolution across the renames
releases have used; reading a certificate thumbprint from a `.cer`; and what a machine with no
7z-compatible CLI is told: the run stops and prints where to get one - the download page, and the
`winget` command for whoever is already in a terminal.

`InfPatchIntegrity.Tests.ps1` built a small but structurally faithful `Display.Driver` folder in a
temp directory - two `[NVIDIA_Devices*]` blocks, two `[nv_miscBase_addreg__NN]` sections whose
bodies end in a comment line and a blank line, `[Strings]` last with a blank tail - then runs the
real patchers against it and the gate before and after. The blank tails are deliberate: every
insertion in the pipeline goes through one section-index walk, and a fixture without tails would not
test the thing that differs between driver releases. It asserts that the gate refuses the unpatched
package while naming both problems, that the entry lands in *both* device blocks, that the spliced
`SectionExtraGPU*` family and its `[Strings]` definition sit inside their sections rather than under
them, that the RM override appears exactly once per misc section and above that trailing comment,
that the patched package then passes the gate, and that a second pass of both patchers leaves the
file byte-identical. It also checks the INF is still BOM-less UTF-8 with CRLF endings after three
different writers have opened it.

`ExtraGpuSectionPlacement.Tests.ps1` patched a fixture whose *last* `[NVIDIA_Devices*]` block is the
one that ends the file, which is the case an insertion rule gets wrong when it treats a section's
exclusive upper bound as its insertion point, and asserted that every insertion lands inside a
section. Then it checked what the patchers hand back: a BOM stays a BOM, LF-only line endings stay
LF-only, a byte that is not valid UTF-8 survives the patch and reads back unchanged - and the RM
override patcher was held to the same three byte checks. `ForeignOemPrune.Tests.ps1` covered the prune
step: which INFs survive, what the fallback keeps, what the safety net says about hardware that is
present but cannot install through the INF it kept, and what the manifest's own bytes look like
afterwards. Four of its eight cases failed against the previous revision of
`Remove-ForeignOemInfs.ps1`, which was the point: they pinned fixes, not the code as it then read.

Pester 3.4 is what ships with PowerShell 5.1, so a rebuilt suite should use its syntax and run on
5.1 and 7 - the same two interpreters the scripts themselves have to work on. These are the cases
worth having before touching the section walk or the matching rules, which are the two places where a
wrong answer looks exactly like a successful patch.

What that leaves in place today is the gate in [The verification gate](#the-verification-gate) and the
runs in [Verified driver releases](#verified-driver-releases) - one gate that reads the finished INFs,
and four recorded driver runs, none of them against 1.0.4 or 1.0.5. The gate has documented limits of
its own (see the two caveats there), which is the other reason a rebuilt suite matters: the four
highest-value cases to write first are the ones the gate currently cannot fail - an `RM1457588`
mention that is only a comment, a whitelisted device line reusing a stock section with a dead
`AddService` target, a device block whose header is repeated, and a `whitelist.json` whose entries do
not apply.

## Verified driver releases

The patching logic is written to survive NVIDIA renumbering and renaming INFs, so it is *built*
for any driver version. That is not the same as being *verified* on one, and the two are kept
apart deliberately. The table below is every release this toolkit has been run against end to end,
taken from the run logs — not from a claim.

| Driver release | Toolkit version | Build | Whitelist gate | Outcome |
|---|---|---|---|---|
| 595.79 | — | reference | — | Source of `whitelist.json`: a stock package diffed against a hand-patched one. Not a toolkit run. |
| 616.86 desktop-notebook | 1.0.1+ | pruned | 58/58 | Ran against a real package. The release that exposed the `nv_dispig.inf` rename (tier 2) and the prune-to-nothing bug; the pruning timings below are measured on it. |
| 616.92 Studio (`nsd-dch`) | 1.0.1+ | pruned | 58/58 | Ran against a real package. The release that exposed the `nv_dispsi.inf` rename (tier 3), including the run that deleted all 45 display INFs. |
| 617.14 | 1.0.3 | universal | 61/61 in place, references resolve, RM override applied | Success, 31 min 43 s — full 43-INF catalog rebuild, timestamped signature. |
| 617.42 | 1.0.3 | pruned to 1 INF | 58/58 in place, references resolve, RM override applied | Success, 1 min 20 s. Built for an RTX A2000m (`DEV_25B8&SUBSYS_000010DE`). |

The 617.14 and 617.42 rows are read straight out of `Logs\` and carry the gate's own verdict. The
616.86 and 616.92 rows are reconstructed from the changelog and the measured timings — those runs
predate the current log format, so their gate numbers are the reported ones, not a log line. Those
logs are runtime files under `Logs\`, which is git-ignored, so they are not in the repository and
cannot be checked from a clone.

No end-to-end run is recorded against 1.0.4, 1.0.5 or against the current working tree: the newest
runs in the table above were made by 1.0.3, and everything added since then is in
[CHANGELOG.md](CHANGELOG.md) under
[1.0.5](CHANGELOG.md#105---2026-10-23). Nothing in this repository covers that gap: the test suite
described in [Tests](#tests) is not in the tree, and the run logs the table is read from are git-ignored.
A suite exercising the INF text handling and the gate end to end against a synthetic package is the
missing piece, and it is not a substitute for a real run on real hardware either way - a driver
release that is not listed above is still unverified in the sense that matters.

One consequence of that, worth stating for anyone reading a clone: the 617.14 and 617.42 rows are
backed by `Logs\` files that live only on the machine that ran them. From a checkout of this
repository those two rows cannot be reproduced or re-checked at all - no driver package, no run log
and no test in this tree reproduces a patched, signed package. What a clone does let you check is the
*code path*, by reading the patchers and running `Test-DriverPatch.ps1 -DisplayDriverPath` against a
package you unpacked yourself.

What "verified" means here, concretely: the pipeline ran to completion, `Test-DriverPatch.ps1`
passed its gate, and `signtool` signed the rebuilt catalog. **It does not mean the patched driver
was installed and driven on real hardware** — see [PhysX and the NVIDIA App](#physx-and-the-nvidia-app)
and [Trusting the certificate](#trusting-the-certificate), where the project says so plainly.

**On an unlisted release, the gate is the thing to watch.** A run that unpacks, patches, signs and
installs cleanly can still carry no unlock at all — that is exactly the failure NVIDIA's INF renames
produced before the stem-based lookup existed. `Patch verification PASSED - N/N whitelist entries in
place` is the line that says the unlock is in the package. If the whitelist step reports skipping an
INF, or the gate reports fewer than 61 entries on a universal build, stop and read
[When NVIDIA renames the INFs](#when-nvidia-renames-the-infs) before installing.

**Blackwell (RTX 50-series) is out of scope.** `whitelist.json` carries one Blackwell entry,
`DEV_2D00` under a null subsystem ID that real hardware is unlikely to report. A 617.42 run on a
machine carrying a GeForce RTX 5070 Ti reports it as `not in whitelist.json` — by design, not as a
failure. Unlocking Blackwell mobile parts needs entries this project does not have.

## Making a run finish in minutes instead of an hour

Almost all the wall-clock time in a patch run is `Inf2Cat` rebuilding the catalog, single-threaded
on one core. Two things were measured on a real 2.71 GB `Display.Driver`, and the first one kills
the obvious idea:

**Trimming the `/os` list does nothing.** One target, two targets and all five produce the same
runtime and a byte-identical catalog:

| INFs | OS targets | Time | Catalog |
|---|---|---|---|
| 4 | 1 | 145.3 s | 4473 KB |
| 4 | 2 | 145.3 s | 4473 KB |
| 4 | 5 | 147.4 s | 4473 KB |

**The cost is superlinear in INF count**, and driven by the INFs rather than the payload bytes:

| INFs | Time |
|---|---|
| 1 | 79.7 s |
| 2 | 128.1 s |
| 4 | 147.4 s |
| 8 | 583.8 s |

Four to eight INFs quadruples it, which is why all 43 take about fifty minutes. `Inf2Cat /?`
offers no way to reduce its own work: `/nocat` only suppresses the catalog, `/pageHashes` adds
work, and there is no switch to skip the signability test.

Parallelising it across cores is not available either. All 43 INFs declare
`CatalogFile = NV_DISP.CAT`, so they build one shared catalog, and merging catalogs is not
something Inf2Cat or signtool can do.

So the only real lever is to have fewer INFs, which is what `-PruneForeignOemInfs` does:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "...exe" -PruneForeignOemInfs
```

A stock package ships 43 display INFs: the generic desktop one plus one per laptop OEM. Usually
exactly one can apply to any given machine. An INF survives if it can match a GPU actually present,
if this toolkit patches it **and** one of its whitelist entries names present hardware, or if you
passed `-KeepInf`. Everything else goes, along with its manifest entry. The catalog and filter files
that share a pruned INF's stem are not touched and keep their manifest entries too: nothing here can
establish whether an INF that was kept references them, so the step leaves them and says that it did
rather than delete files it cannot account for.

That second condition matters more than it sounds. Keeping every INF the toolkit *could* patch is
too generous: on this machine it retained `nvamig.inf`, whose three whitelist entries are all RTX
A3000m, on a box with an A2000m. That INF is 3.9 MB with 62,280 lines and 3,010 sections against
`nv_dispig.inf`'s 677 KB, and on its own it accounted for three quarters of the catalog build.
A whitelist INF pruned this way is reported by the later steps as a note ("was pruned from this
package - its N entries do not apply") rather than as a missing-INF failure. The gate treats an
unresolved whitelist INF as an error, precisely because the entries filed under it are the ones
nobody checked, so a deliberate prune has to be named for a pruned run to pass - which the pipeline
does on its own. That is what keeps the error meaning what it says: the release renamed or dropped
an INF the toolkit needs, and a build that ships without one it was supposed to patch no longer
reaches the signing step.

The keep rule is answered for the GPU that is actually here, subsystem included. An OEM INF whose
device id matches this card but whose subsystem does not is reported as uncovered, naming the device
and subsystem that are really present, rather than being vouched for by a `whitelist.json` entry that
describes a different card. An entry that does cover this exact GPU but lives in no INF this package
ships is a note that it will be supported once the package is patched.

Measured on 616.86, 43 INFs down to 1:

| Step | Unpruned | Pruned to 2 | Pruned to 1 |
|---|---|---|---|
| Catalog rebuild | ~3000 s | 385 s | **96 s** |
| RM override | 1485 sections / 40 INFs | 122 / 2 | 17 / 1 |
| Whole pipeline | ~57 min | 7.6 min | **2.2 min** |

If nothing matches, the rule backs off to keeping every whitelist INF and says so. Should that
fallback come up empty too, the step refuses to run rather than deleting every display INF — see
[Pruning must never delete every INF](#pruning-must-never-delete-every-inf).

Do not bother trimming the whitelist entries themselves. Measured on an identical two-INF package,
patching zero entries took 391.6 s, all 61 took 384.9 s, and one took 372.5 s. The spread is noise;
the cost is in the INFs and the binaries, not in the device lines added to them.

**The result is specific to the hardware in the machine that built it** and will not install on
other vendors' cards, which is why it is opt-in rather than the default.

In the GUI this is the **"Build for this PC only"** checkbox, unticked by default to match the
command line. The choice belongs to whoever *builds* the package: by the time `setup.exe` runs the
pruned INFs are already gone, so it is not something the person installing can change.

### A pruned build needs a GPU worth pruning for

`-PruneForeignOemInfs` stops in preflight, before anything is unpacked, if **no GPU in this
machine is one `whitelist.json` unlocks**:

```
Nothing to unlock on this machine, and a for-this-PC-only build was requested.

  NVIDIA GeForce RTX 5070 Ti (DEV_2C05&SUBSYS_F3221569) - not in whitelist.json
```

The two options are opposites here, so the same machine gives them opposite answers:

| | Pruned (`-PruneForeignOemInfs`) | Universal (default) |
|---|---|---|
| What survives | only INFs that can match **this** machine | everything |
| Whitelist entries that can ever match | those for hardware present here | all 61 |
| Machine that built it | must be the machine that needs the unlock | irrelevant |
| No unlockable GPU here | **stops** | runs normally |

Take a box with an RTX 5070 Ti. `DEV_2C05` is a desktop Blackwell part the stock generic INF
already carries a bare `DEV` line for, and it is not in `whitelist.json` at all. Without the gate,
a pruned run there completes: it keeps `nv_dispig.inf` because that INF matches the 5070 Ti,
splices in 58 mobile-GPU device lines that nothing on that machine can ever match, adds the RM
override to 17 sections, reports `verification PASSED`, and signs the result with an untrusted
certificate. What comes out is NVIDIA's own driver for a GPU that already works, needing Test
Signing mode to install. Every step reports success and the unlock is a no-op.

The universal run on the same machine is the *correct* use of it - all 43 INFs, all 61 entries,
installable on the card that actually has the locked GPU. So the gate is on the pruned path
only, and a universal build is never questioned.

Detection failing is not the same as "not a target": if no NVIDIA display GPU can be read at all
the run continues with a warning, because `Remove-ForeignOemInfs.ps1` already backs off to keeping
every whitelist INF when it has no hardware to go on, and a WMI quirk should not be what refuses a
run.

Pass `-AllowUnsupportedGpu` to build the pruned package anyway. Ask what the machine's verdict is
without running anything:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -CheckLocalGpuSupport
# SUPPORTED | UNSUPPORTED | UNKNOWN, then one line per GPU
```

The GUI asks the same question when the box is ticked, before it starts, and offers to build the
portable package instead - so an unsupported GPU costs a dialog rather than a failed run.

**Multi-GPU machines are handled.** Every display-class NVIDIA GPU present is detected and the
kept set is the union of what they need, so a box with, say, an RTX 5070 Ti and an RTX A2000 keeps
whatever supports either. The 5070 Ti is covered by a bare `DEV_2C05` line in the generic INF and
the A2000 by the whitelist, so both end up served by `nv_dispi.inf` and the prune is still safe.
Where a GPU genuinely needs an OEM INF, that INF is kept too. The reasons are printed per INF:

```
nv_dispig.inf   - patched by this toolkit; matches present hardware DEV_2C05&SUBSYS_88881043
nvamig.inf      - patched by this toolkit
```

Only the GPU is considered, not the HD Audio function NVIDIA exposes on the same PCI device, which
no display INF ever matches.

Why this is claimed rather than guaranteed: the check is the runtime half of the story. The script
scans the kept INFs for `Include=`, `Needs=` and `CopyINF=` references to a name being pruned, and it
refuses when a kept INF references a pruned one — but that scan reads one physical line at a time and
only recognises **literal** filenames, so a reference hidden in a trailing-backslash continuation or
reached through a `[Strings]` token (`CopyINF = %nv_inc%`) is not something it can see. It also looks
inside `Display.Driver` only: the INFs of sibling sub-packages, other `.nvi` manifests and the root
`setup.cfg` are not read, even though the first tier of the whitelist lookup exists because NVIDIA has
already rewritten every display INF name in a single release. The self-containment above is measured on
the releases in [Verified driver releases](#verified-driver-releases); on an unlisted release the
runtime check is the only thing standing between a prune and a package whose INFs point at files that
are no longer there. `CopyINF` is a real reference to watch for — the captured `nv_dispi.inf` section
bodies in `whitelist.json` carry `CopyINF = nvppc.inf`.

Pruned INFs are moved to a staging folder in the package root and deleted once the manifest and the
folder are verified to agree; any failure **before** that verification moves them back and restores the
manifest, leaving the package as it was. Once the verification passes the deletion is final — there is
no backup copy of a pruned INF anywhere, so recovering one means re-unpacking the driver download. The
manifest entries and the companion files that share a pruned INF's stem (its `.cat`, `.co`, `.df`
siblings) are left in place by design, and the step says so rather than deciding for you.

Hardware matching follows Windows' own rules: an exact `DEV`+`SUBSYS` line, or a `DEV` line with
no `SUBSYS`, which covers any subsystem of that device. A line carrying extra qualifiers
(`&REV_xx`, `&CC_xxxxxx`) counts as a possible match and keeps its INF - keeping one that turns out
not to apply costs only time, dropping one that does apply breaks the install. An OEM INF listing
the right device under someone else's subsystem can never win the install, so keeping it would be
waste. A GPU that
matches no kept INF but *is* in `whitelist.json` is fine and reported as such, since adding it to
the generic INF is the whole point of this toolkit. A GPU matching neither raises a warning.

Only the INFs are pruned, not the driver binaries, so the package stays the same size on disk.

## PhysX and the NVIDIA App

Whether `setup.exe` offers "PhysX System Software" and the NVIDIA App is not a fixed property of
the installer. Both are gated by constraints in `setup.cfg` that read **per-device feature flags
out of the driver INF**:

```xml
<sub-package name="Display.PhysX">
  <constraints>
    <property name="Display.Driver!Feature.Physx" level="silent" .../>
  </constraints>
</sub-package>
```

Those flags are the INF's own `NVSupportPhysx = 1` and `NVSupportGFExperienceUDA = 1` lines,
written into each device install section. NVIDIA sets them unevenly. In stock 616.64's main INF:

| Flag | Sections carrying it |
|---|---|
| Total device install sections | 105 |
| `NVSupportPhysx = 1` | 55 |
| `NVSupportGFExperienceUDA = 1` | 28 |

Because the constraints are `level="silent"`, a GPU whose section lacks the flag makes the
component vanish from the installer with no message at all. That is why the offer appears on some
hardware and not others.

`Enable-OptionalComponents.ps1` levels this out for the GPUs this toolkit unlocks. It resolves
each whitelisted device line to the install Section it points at and ensures that Section carries
both flags. It runs as pipeline step 5 (6 with `-PruneForeignOemInfs`), before the catalog is
built; the number drops by one for each `-Skip...` switch and for starting from an already
unpacked folder. Skip it with `-SkipOptionalComponents`.

It also flips one attribute in `setup.cfg`. `Display.NvApp` ships as
`disposition="default" userSelectable="false"`, meaning pre-ticked and **locked**; the script sets
`userSelectable="true"` so it becomes a row you can untick. PhysX needs no such change, since it
is already `disposition="default"` with no selectability restriction. The result is both
components ticked by default and both removable under Custom Installation Options.

**What it deliberately does not do** is delete the `setup.cfg` constraints. That would force these
components on for every GPU, including ones NVIDIA flagged as unsupported. Setting the INF flags
makes the unlocked GPUs behave like first-class ones instead, which is a much narrower claim.

**On blast radius.** Most whitelisted devices get a freshly spliced `SectionExtraGPU*` section, so
the change lands only on them. A few reuse an existing stock section, because
`Add-ExtraGpuSupport.ps1` prefers a section already valid for that chip in the current driver over
a template captured from an older one. Measured on 616.86, editing those affects one extra device
ID, `DEV_24B6`, which shares `Section139` with a whitelisted RTX A3000 part and gains the App flag
with it. The script prints how many device lines reference every section it touches, so a future
release that shares sections more widely shows up rather than passing unnoticed.

One asymmetry to know about: this step only **warns** when a whitelisted device line points at an
install section that does not exist in the INF, and moves on (`skipping`). The gate treats the same
condition as a hard failure, so the case still stops a run — just at the verification step rather
than here. That is intentional: this step's job is to add flags where it safely can, and the gate is
the thing that decides whether the package is sound.

None of this is confirmed through a real install. Verify on your own hardware before relying on it.

## When NVIDIA renames the INFs

`whitelist.json` is keyed by INF filename, `nv_dispi.inf` and `nvami.inf`. Those names are not
stable across releases, and they have moved in two different ways:

| Release | Main INF | ASUS OEM INF | How it moved |
|---|---|---|---|
| baseline | `nv_dispi.inf` | `nvami.inf` | — |
| 616.86 desktop-notebook hotfix | `nv_dispig.inf` | `nvamig.inf` | `g` **appended** to every stem |
| 616.92 Studio (`nsd-dch`) | `nv_dispsi.inf` | `nvamsi.inf` | trailing letter **replaced** by `si` |

Looking those names up literally fails in the worst possible way. The whitelist step skips both
target INFs and applies nothing, while the RM-override step carries on normally because it globs
`*.inf` and never cares about names. The result is a package that unpacks, patches, signs and
installs cleanly, and delivers **no GPU unlock at all**. A plain `<stem>*.inf` glob is not enough
either: it assumes renames only ever *append*, and 616.92 replaces a letter instead, so
`nv_dispsi.inf` does not begin with `nv_dispi`.

The suffix is a per-build quirk, not a flavour convention - the 581.94 desktop-notebook hotfix
uses the ordinary names - so it is not hardcoded. Instead the patcher, the verification gate and
the prune step resolve each whitelist key through one shared helper, which tries three tiers,
widest last:

1. An exact filename match.
2. `<stem>*.inf` — the appended-suffix case.
3. `<stem minus its last character>*.inf` — the replaced-letter case, requiring a core of at least
   four characters so a short stem can never widen to something like `n*.inf`.

A release using the ordinary names never reaches tier 2 or 3. On 616.92, tier 3 resolves
`nv_disp*.inf` → `nv_dispsi.inf` and `nvam*.inf` → `nvamsi.inf`, both unambiguously — note that
`nvam*` does not catch `nvmdsi.inf`, `nvmisi.inf` or `nvmosi.inf`, which start `nvm`. The
substitution is reported rather than silent:

```
NOTE: this release has no nv_dispi.inf; it ships nv_dispig.inf instead - patching that.
```

and the gate labels it too, so a passing run still shows which file stood in:

```
nv_dispig.inf    58/58 whitelisted, 2 device block(s), 235 spliced section(s) (this release's name for nv_dispi.inf)
```

Both sides must use the same helper. If only the patcher followed a rename, the gate would then
reject a package that had in fact been patched correctly.

If a future release renames an INF beyond a shared core, all three tiers miss and the patcher
throws rather than silently doing nothing, with an error saying `whitelist.json` needs updating.

### Pruning must never delete every INF

`Remove-ForeignOemInfs.ps1` resolves whitelist INFs through that same helper, including in its
"never prune to nothing" fallback. If the whitelist names do not resolve against a release, the
strict rule and the fallback both come up empty, and pruning would delete every display INF -
on a 616.92 package, all 45 of them, leaving 3.6 GB with no INF in it. So the keep set is checked
again after the fallback, and the step throws instead of pruning to nothing:

```
Refusing to prune: that would delete all 45 display INF(s) and leave an unusable package. Even
the keep-everything fallback matched nothing, which means the INF names in whitelist.json
(nv_dispi.inf, nvami.inf) do not resolve against this release. Re-run without
-PruneForeignOemInfs, or update whitelist.json to this release's INF names.
```

Deleting 100% of the display INFs is never a correct outcome, so this holds regardless of what
caused the keep set to come out empty — a naming change, odd hardware detection, or a future bug.

## Signing without a password

`New-SelfSignedCertificate` puts the private key in `Cert:\CurrentUser\My`, not just in the
exported `.pfx`. `signtool` can use a key straight from that store, selected by thumbprint, so on
the machine that generated the certificate **there is no password to type and no `.pfx` to
unlock** — not on the first run, and not on any later driver release:

```powershell
signtool sign /sha1 <thumbprint> /fd SHA256 nv_disp.cat
```

That is what the pipeline does by default. It works out which certificate to use on its own, in
this order:

1. `-CertThumbprint`, if you passed one.
2. The **public** `.cer` files in `Certificates\` - `DriverPatchSigning_<thumbprint>.cer` newest
   first, then the legacy `DriverPatchSigning.cer` - taking the first whose private key is in your
   store and has not expired. Reading a `.cer` needs no password.
3. If no `.cer` leads to a key, a search of `Cert:\CurrentUser\My` itself, by subject: a
   code-signing certificate of this project with a private key and time left on it, preferring
   one already trusted in `LocalMachine\Root`, then the one that expires last. The missing `.cer`
   is then re-exported to `Certificates\`. This is what keeps a deleted `Certificates` folder from
   costing you your key: without it the run would mint a new certificate, and the cleanup of old
   keys would delete the existing one, which cannot be recovered because it is non-exportable.
4. Only then a `.pfx` (with its password), or a newly minted certificate.

Passing `-PfxPath` skips step 3, since you have said which certificate to use.
`Sign-DriverPackage.ps1` run on its own follows the same order, **except that it also skips step 3
whenever `-PfxPath` is supplied** - so a machine that already holds a valid project key in
`Cert:\CurrentUser\My` still takes the password route if a `.pfx` path is merely present on the
command line (the GUI can pre-fill one). The `.pfx` is therefore only a portable backup, needed when
signing on a *different* machine.

`Approve-DriverPatchCert.ps1` uses the candidate list from step 2 but **not** the store search of
step 3. That is deliberate for the target PC, where only the copied `.cer` files exist and there is no
key to find; the consequence is that on the *signing* machine it agrees with the pipeline only while
the `.cer` of the certificate in use is still on disk. If `Certificates\` was emptied, or the key was
pruned from `Cert:\CurrentUser\My`, `Approve` falls back to the newest `DriverPatchSigning_*.cer` by
write time while the pipeline signs with the store certificate that expires last - and the two can then
name different certificates. Check the pair yourself when it matters:

```powershell
Get-AuthenticodeSignature "<pkg>\Display.Driver\nv_disp.cat" | Select-Object -ExpandProperty SignerCertificate | Select-Object Thumbprint, Subject
```

`Add-SetupCertOption.ps1` is the one route that enforces the match: its `-ExpectThumbprint` defaults to
the certificate that actually signed the package's `nv_disp*.cat`, and it throws on a mismatch.

There is a real security reason to prefer this and not only a convenience one. `signtool` has no
way to read a `.pfx` password from stdin, so the `/f` + `/p` form has to put the password on a
child process's command line, where any process listing can read it. Signing from the store means
no password exists anywhere in the run.

**On a machine that has only the `.pfx`**, import it once and that machine becomes passwordless
too:

```powershell
Import-PfxCertificate -FilePath "Certificates\DriverPatchSigning_<thumbprint>.pfx" -CertStoreLocation Cert:\CurrentUser\My
```

The exports are named after the certificate, so more than one `.pfx` can end up in that folder; the
newest one is what the GUI offers when a run stops for lack of a key. Until you import, pass
`-PfxPath` and supply its password; the script warns that the password will be briefly visible on
signtool's command line.

**Timestamping is best-effort.** A timestamp is attempted first, and if the timestamp server is
unreachable the catalog is still signed, with a warning, instead of failing the whole run. Pass
`-SkipTimestamp` to skip the attempt entirely and sign fully offline. The only thing an
un-timestamped signature loses is validity past the signing certificate's own expiry, counted from
when you **minted** it rather than from when you built the driver. For a 3-year local test-signing
certificate used on the machine that made it, that is usually not a practical concern; it becomes one
when an older certificate is reused for a later release, or when `-ValidityYears` was raised, because
then the whole remaining life of that key is what a catalog without a timestamp is pinned to.

## Why VRAM size / compute needs a second fix

Symptom: driver installs fine on a whitelisted GPU, device shows up in Device Manager, but VRAM
size is wrong and compute (CUDA/NVENC/OptiX/etc.) doesn't work. Found by diffing stock against a
hand-patched package at the *AddReg section body* level rather than only at the device-ID
whitelist level - device-ID diffing alone completely misses it. Alongside the whitelist entries,
the hand-patched reference adds one registry value, `HKR,,RM1457588,%REG_DWORD%,1`, to a handful
of `nv_miscBase_addreg__NN` AddReg sections per INF.

NVIDIA's driver does a **second, internal Resource-Manager-level hardware check**, separate from
and deeper than the INF's PCI device/subsystem ID whitelist. A device can pass the INF-level
check - so the driver installs, the device enumerates fine - and still fail this internal check,
which is what causes the VRAM/compute symptoms. `RM1457588` reads as a validation-bypass style
override for exactly this internal check.

**NVIDIA ships this same override themselves**, which is the strongest evidence that it is the
intended mechanism rather than a lucky guess. In the stock 595.79 package, `nvmsoai.inf` (an MSI
OEM INF) contains `HKR,,RM1457588,%REG_DWORD%,1` in **both** of its two `nv_miscBase_addreg__NN`
sections. It is the only stock INF that carries it, and the key name also appears inside
`nvlddmkm.sys` and the `gsp_*.bin` GSP firmware images, confirming the driver really does read it.
So NVIDIA's own use of it is precisely the case this project needs: an OEM-specific INF enabling
full capability on hardware the generic desktop INF would otherwise restrict. Applying it to every
`nv_miscBase_addreg__*` section matches what NVIDIA does in that INF, at the same granularity.

This also explains the "install the hand-patched driver first, then install ours over it, and it
works" workaround: that installer writes this registry value once, under the device's own driver
key, during its first install. A driver *update* over an already-installed device does not
necessarily clear per-device registry values that the new INF doesn't mention, so the override
silently survives from that earlier install even though this package's own INF never wrote it. A
**clean** install has no such leftover value, so the internal check stays in effect and the
symptoms show up.

The hand-patched reference only touches the specific `nv_miscBase_addreg__NN` sections referenced
by the specific device Sections its author patched - whichever hardware they personally had to
test with. `Add-RmCapabilityOverride.ps1` instead adds the override to **every**
`nv_miscBase_addreg__*` section in **every** driver INF, rather than trying to resolve which
specific sections each of the 61 `whitelist.json` entries' target Section references (fragile
across the same kind of INF section renumbering `Add-ExtraGpuSupport.ps1` already has to work
around between driver versions). This key has no observed effect on hardware that already passes
the internal check on its own, so applying it broadly is the safer and more complete fix -
verified structurally: after patching, every `nv_miscBase_addreg__*` section in every INF (1400
sections across 39 files in the 595.79 package) has the override, with no duplicate/corrupted
section headers.

## Trusting the certificate

Signing the catalog is not enough by itself — Windows only trusts kernel driver signatures that
chain to a **Microsoft-anchored** certificate (WHQL, or an EV cert cross-signed via the Hardware
Dev Center) *unless the machine is in Test Signing Mode*, in which case it accepts any cert that
you've explicitly trusted locally. There are three ways to get there:

**1. `Scripts\Approve-DriverPatchCert.ps1`** (recommended), run yourself from an elevated prompt,
separately from the installer:

```powershell
.\Scripts\Approve-DriverPatchCert.ps1
```

Prints exactly what it's about to trust and asks for confirmation before running `certutil`. This
is the path to prefer because you watch it happen and it is the one actually verified end to end.
With no `-CerPath` it trusts the certificate the pipeline signs with: the `.cer` whose key is on
this machine, or on a machine without the key, the newest `.cer` in `Certificates\`.

**2. Manually**, if you'd rather see the raw commands:

```powershell
certutil -addstore Root             "Certificates\DriverPatchSigning_<thumbprint>.cer"
certutil -addstore TrustedPublisher "Certificates\DriverPatchSigning_<thumbprint>.cer"
```

`Root` is what makes a self-signed signature chain at all, and is the only one strictly required.
`TrustedPublisher` stops Windows asking "Would you like to install this device software?" during
the install. There is deliberately **no `CA` entry**: a self-signed certificate is its own root,
so there is no intermediate to chain through. `Remove-DriverPatchCert.ps1` removes any `CA` entry
it finds for a patch certificate.

**3. The installer checkbox** — *not fully verified, see below*. `Custom Installation Options` in
`setup.exe` shows a **"Chameleon GPU cert."** row alongside Graphics/Audio Driver,
**ticked by default**. Leave it ticked and `setup.exe` runs `certutil -addstore` itself,
elevated, before installing the driver - for `Root` and `TrustedPublisher`, the same two stores
as option 1. Untick it and nothing about your trust settings changes. The row renders with correct
title, description, and version columns. It is `disposition="default"`, so it starts ticked but
stays user-selectable; `Add-SetupCertOption.ps1 -Unchecked` makes it start unticked.

What has been confirmed is that the row *renders* correctly with the intended disposition. What has
**not** been confirmed is the checked-through-a-full-install case: that `certutil` fires cleanly
under the installer's elevated context and the driver then installs without further prompts. Until
you've verified that yourself, prefer option 1. You can check whether it worked with:

```powershell
certutil -store Root <thumbprint>
```

Whichever path, you *also* need one of:

```powershell
# Turn on Windows Test Signing mode (requires Secure Boot disabled in firmware, and a reboot)
bcdedit /set testsigning on
```

Test Mode weakens driver signature enforcement globally and requires Secure Boot off — turn it
back off (`bcdedit /set testsigning off`) when you're done experimenting. **Alternative:** Windows
also lets you disable driver signature enforcement for a single boot (Shift+Restart →
Troubleshoot → Startup Settings → Disable driver signature enforcement) — no trust-store or BCD
changes, but has to be redone after every reboot.

## Renaming the certificate

The name Windows shows for your signing certificate is its subject, set when the certificate is
created. `New-DriverSigningCert.ps1` defaults to:

```
CN=Chameleon Project - Customised driver for Nvidia GPU
```

That name appears in the Windows certificate manager, in `signtool` output, and as the publisher
on the "Would you like to install this device software?" prompt. Override it with `-Subject`.

**A subject cannot be edited after the fact.** It is bound into the signed certificate structure,
so changing the default renames nothing that already exists. To actually carry a new name you have
to create a new certificate, and that has knock-on costs:

- It gets a **new thumbprint**, so it is a different identity as far as Windows is concerned.
- It is **not trusted**, so `Approve-DriverPatchCert.ps1` has to be run again from an elevated
  prompt before anything signed with it will install.
- Packages you signed earlier still carry the **old** certificate. They keep working only while
  that old certificate stays trusted. Re-sign them, or keep both trusted, or accept that the older
  packages become uninstallable.
- A new certificate has **no `.pfx` backup** unless you ask for one with `-Exportable`, and the
  `.pfx` it does write is named after the new thumbprint.

Minting is guarded, because every part of this failure mode was silent. A **valid** certificate with
the subject you are about to create is refused - two certificates under one subject are
indistinguishable in every UI that shows them, and it is entirely possible to trust one and sign with
the other - and the message names the thumbprint to sign with instead, or `-Force` if a second one is
really wanted. An expired namesake does not block: making the next certificate is the right answer
when the old one aged out, so those are reported rather than treated as a conflict. A `-Subject`
outside the patterns this toolkit recognises a project certificate by gets a warning, because that
certificate is invisible to the next run's certificate resolution and to the cleanup alike. And
neither the `.cer` nor the `.pfx` of a thumbprint that already has one is rewritten.

So renaming is worth doing when you are about to mint a certificate anyway, and rarely worth doing
on its own. Nothing forces you to switch: the existing certificate signs future driver releases
perfectly well under its old name.

If you do rename, remember that `Remove-DriverPatchCert.ps1` finds certificates by subject
pattern. Its defaults already cover the current name plus the two legacy names this project has
signed under (see `-SubjectPattern` in that script). Add to that list rather than replacing it,
or a renamed certificate becomes invisible to the tool meant to clean it up and quietly
accumulates as an untracked trusted root.

## Cleaning up trusted certificates

**What the pipeline does for you.** After the catalog is signed, the pipeline prunes the pile of
old signing *keys* from `Cert:\CurrentUser\My`, keeping only the certificate that run signed with
(pass `-KeepAllOldCerts` to opt out). That is the safe half of certificate cleanup: per-user, no
elevation, and it withdraws no trust, so it cannot break an already-patched package. It does not
run if signing failed, and it is skipped on a run that had to mint a new certificate, so keys are
never deleted in the same run that replaced them. What remains
below is the destructive half — withdrawing *trust* from the Root / CA / TrustedPublisher stores —
which needs elevation and means catalogs signed by the removed certificate stop validating, so it
stays opt-in.

Trusting a certificate is not a one-off cost you pay and forget: each trusted entry is a
self-signed authority your machine will accept code from, kernel drivers included, until you take
it back out. Every certificate you trust adds another such entry, and a trust entry outlives the
key it belongs to, so they accumulate. Check what you have:

```powershell
.\Scripts\Remove-DriverPatchCert.ps1
```

That is read-only. It lists every patch certificate, when it expires, and which stores it sits in.
To prune everything except the one you still sign with:

```powershell
.\Scripts\Remove-DriverPatchCert.ps1 -AllPatchCerts -KeepThumbprint <the one you use>
```

Removing trust from a certificate means catalogs it signed stop validating, so a patched package
signed with it can no longer be installed. An already-installed driver keeps running. Work out
which certificate signed which package before pruning:

```powershell
Get-AuthenticodeSignature "<pkg>\Display.Driver\nv_disp.cat" | Select-Object -ExpandProperty SignerCertificate
```

**One gotcha worth knowing.** A `CurrentUser` trust store is a *merged view*: it shows that user's
own entries plus everything inherited from the matching `LocalMachine` store. An inherited entry
cannot be deleted through the user view — the attempt fails with access-denied even in an elevated
session — it has to be removed from `LocalMachine`. So a certificate listed under
`CurrentUser\Root` is not necessarily removable there. `Remove-DriverPatchCert.ps1` detects this,
skips those entries rather than failing confusingly, and prints the elevated command to finish the
job:

```powershell
.\Scripts\Remove-DriverPatchCert.ps1 -Scope LocalMachine -Thumbprint <thumb1>,<thumb2>
```

Add `-IncludePrivateKeys` to also drop leftover cert+key pairs from `Cert:\CurrentUser\My`. Those
are clutter rather than exposure once their trust entries are gone, and removing a non-exportable
key is irreversible, so it is deliberately opt-in. Note what that switch actually covers with the
default `-Scope Both`: `LocalMachine\My` is inventoried too, and a machine-level cert+key pair whose
subject matches one of the `-SubjectPattern` wildcards is removed from it along with the per-user
ones. That is broader than the per-user cleanup the option's own help text describes, so inventory
first (the bare read-only run) and prefer `-Thumbprint` over `-AllPatchCerts` when you know which
certificate you mean.

The same applies to the trust stores themselves: `-AllPatchCerts` selects by **subject substring**,
and the patterns (`*Chameleon*`, `*Driver Patch*`, `*FrankenDriver*`) are not anchored. A third-party
certificate authority whose name happens to contain one of those strings is a candidate like any
certificate this project minted, and removing it from `LocalMachine\Root` breaks software that had
nothing to do with this toolkit. `-Thumbprint` is the narrower request.

## Installing the patched driver

```powershell
pnputil /add-driver "<name>_Patched\Display.Driver\nv_dispi.inf" /install
```

or run `setup.exe` from the patched package root for the full NVIDIA App installer flow.

Before installing either way, look at every catalog in the package, not just at the run's summary
line. `Sign-DriverPackage.ps1` signs the catalogs it judged current and **leaves the rest carrying
NVIDIA's original, now-invalidated signature** - on a pruned build that includes the catalog and
binaries of the INFs the prune removed - and `pnputil`/`setup.exe` pick catalogs by what the INFs
declare, not by what the toolkit signed:

```powershell
Get-ChildItem "<name>_Patched\Display.Driver" -Filter *.cat | ForEach-Object {
    $s = Get-AuthenticodeSignature $_.FullName
    "{0,-24} {1,-10} {2}" -f $_.Name, $s.Status, $(if ($s.SignerCertificate) { $s.SignerCertificate.Thumbprint } else { "(unsigned)" })
}
```

Every catalog an INF in that folder actually references should show your thumbprint. A `NotSigned`
or a `NVIDIA` thumbprint on a catalog that is still referenced is the package telling you the signing
step did not cover it.

Only install this on a machine whose GPU is actually one of the newly-whitelisted device
IDs in `whitelist.json` — installing it elsewhere just gives you an INF with extra entries that
don't match your hardware, no effect either way.

## Safety notes

- This adds device/subsystem whitelist entries and one registry override value; it does not
  modify the actual GPU driver binaries (`nvlddmkm.sys`, etc.), so it can't functionally do
  anything to hardware NVIDIA's driver doesn't already technically support at the code level — it
  just removes an INF-level gate and an internal validation-check gate, both already present and
  already reachable in the shipped driver binary.
- Applies only to your own hardware; nothing here is transmitted anywhere or affects other
  machines.
- The signing key is created **non-exportable** and never written as a key file, so by default there
  is no `.pfx` to leak. Be precise about what that does and does not buy: non-exportable means the key
  cannot be extracted as a portable file, not that it cannot be misused. Any code running as your user
  can still ask that key to sign something (Windows does not restrict what a stored key signs), and the
  OS's own key-archive/backup path can carry the key material off the machine. If you opt into a file
  with `-Exportable`, keep `Certificates\DriverPatchSigning_<thumbprint>.pfx` private — anyone with it
  can copy the key off your machine entirely and sign kernel drivers that your machine, once you have
  trusted the cert, will accept. Non-exportable limits *exfiltration*; the entry you put in `Root` is
  what decides how far any signature from that key is honoured, which is the thing to keep short-lived.
- Trusting the certificate is the part with real blast radius, not the patching. Prune what you no
  longer need — see [Cleaning up trusted certificates](#cleaning-up-trusted-certificates) — and
  turn Test Signing mode back off when you're done.

## Contributors

- **qron88** — author.
- **Qwen (self-hosted LLM)** — analysis and engineering support on [1.0.4](CHANGELOG.md#104---2026-10-12):
  dependency-bar analysis, tool preflight, and the verified-release matrix.
