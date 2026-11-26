# Development

Tests, continuous integration, the project layout, and how versions and releases work. Part of the [Chameleon Patcher](../README.md) documentation.

## Tests

```powershell
.\Tests\Run.ps1
```

Pester 3.4 suites (built into Windows PowerShell 5.1), about 20 s. They build tiny packages,
certificates and catalogs under `%TEMP%`; nothing touches a certificate store and nothing is installed.
Run them before every change and add a test for the behaviour you change.

| Suite | Covers |
|---|---|
| `PatchToolDiscovery.Tests.ps1` | the shared helpers in `Scripts\Lib\` |
| `InfPatchIntegrity.Tests.ps1` | the INF patchers and the verification gate on a fixture package |
| `PipelineSafety.Tests.ps1` | tool lookup order, boot state, default output folder, whole-package source verification, the `-Json` answers, the `.partial` work folder, and `Remove-ForeignOemInfs.ps1` |
| `Build.Tests.ps1` | `Source\Build.ps1`: naming and script embedding |

Still untested: the GUI itself, and the scripts that need a real certificate store or the WDK
(`Sign-DriverPackage.ps1`, `New-DriverSigningCert.ps1`, `Approve-` / `Remove-DriverPatchCert.ps1`).

### Continuous integration

`.github\workflows\ci.yml` runs on every push to `main` and every pull request, on `windows-latest`
under Windows PowerShell 5.1: it checks that every `.ps1` is ASCII-only, runs `Tests\Run.ps1`, builds
both GUI variants and prints their SHA256.

`.github\workflows\release.yml` runs when a `v<version>` tag is pushed: it refuses a tag that does not
match the version in `Source\Chameleon-Patcher.cs`, runs the tests, builds the standalone executable
from the tagged commit and attaches it to the GitHub release together with
`Chameleon-Patcher-<version>.exe.sha256`. To check a download:

```powershell
(Get-FileHash .\Chameleon-Patcher-<version>.exe -Algorithm SHA256).Hash   # compare with the .sha256 asset
```

## Project layout

```
Chameleon_Patcher\
|- Chameleon-Patcher-<version>.exe          <- built by Source\Build.ps1; scripts embedded, runs anywhere
|- Chameleon-Patcher-Overlay-<version>.exe  <- optional overlay build (-Variant Overlay); must stay at the root
|- README.md, CHANGELOG.md, AGENTS.md, LICENSE
|- Source\                  <- source for the one component that ships as a binary
|  |- Chameleon-Patcher.cs     <- the GUI: entry point, fields, start-up; version attributes at the top
|  |- MainForm.*.cs            <- the rest of the same class: Ui, Dialogs, Pipeline, Log, Run
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
|  |- PatchToolDiscovery.ps1           <- entry point of the shared helpers, dot-sourced by the others
|  |- Lib\                             <- the helpers themselves, one file per subject:
|  |    Tools, Package, Inf, Hardware, Certificates, Source (.ps1)
|  |- whitelist.json                   <- the PCI ID whitelist data
|  `- templates\GpuUnlockCert.nvi.template
|- Tests\                   <- Pester suites; Run.ps1 runs them
|- docs\                    <- reference documentation: supported GPUs, the GUI, pipeline,
|  |                           signing and trust, development
|  `- images\                 <- the screenshots the README shows
|- .github\workflows\       <- CI (tests + build) and the tagged release build
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

`PatchToolDiscovery.ps1` is the shared foundation every script dot-sources. Since 1.2.1 it is only
the entry point: it loads the six files in `Scripts\Lib\` in a fixed, explicit order (not by
wildcard, so a stray `.ps1` in that folder is never run).

| File | Holds |
|---|---|
| `Lib\Tools.ps1` | the external-tool lookups (7-Zip/NanaZip, `Inf2Cat`, `signtool`), the install guidance shown when one is missing, the native-command runner, the System32-only path for `certutil` |
| `Lib\Package.ps1` | what a package root is, the package NVIDIA App stages, the default output folder, Test Signing / Secure Boot state |
| `Lib\Inf.ps1` | the INF text primitives every writer inserts through (`Get-InfSectionIndex` decides where a line lands inside a section, one shared `[section]` header pattern keeps the patchers and the gate reading sections the same way, `Test-InfLineContinuations` reports trailing-backslash continuations), device-line matching, the template/donor merge, and the byte-preserving reader/writer pair described under [Byte-faithful reading and writing](pipeline.md#byte-faithful-reading-and-writing) |
| `Lib\Hardware.ps1` | GPU detection (prune step, output-folder tag, pruned-build gate), whitelist entries, the INF rename lookup |
| `Lib\Certificates.ps1` | signing-certificate resolution, `.pfx` import, project-certificate identity, old-key cleanup |
| `Lib\Source.ps1` | catalog membership through wintrust and source verification |

## Where the tools are looked for

All three are resolved before a run starts (`-CheckPatchTools`, and the GUI asks the same question
before unpacking); a missing one stops the run in seconds with the install command in the message.

- `Inf2Cat.exe` and `signtool.exe`: under `%WDKContentRoot%`, then `Windows Kits\10\bin` (newest SDK
  version first, x64 preferred - `Inf2Cat.exe` ships x86-only), then on `PATH`. Override with
  `-Inf2CatPath` / `-SignToolPath`.
- A 7z CLI: `Program Files\7-Zip` and `Program Files\NanaZip` (and their `(x86)` twins) first, then
  the per-user WindowsApps `7z.exe` alias and `PATH` - admin-installed copies before anything a
  user-level process could have planted. Override with `-SevenZipPath`.
- `certutil.exe` and `bcdedit.exe`: System32 only, never a `PATH` lookup.

A run prints what it resolved before copying anything:

```
Preflight: checking tools and signing identity...
  7z:       <path>\7z.exe
  Inf2Cat:  <Windows Kits>\10\bin\10.0.28000.0\x86\Inf2Cat.exe
  signtool: <Windows Kits>\10\bin\10.0.28000.0\x64\signtool.exe
  cert:     <thumbprint> (from certificate store - no password needed)
```

## Version

The version is declared once, as assembly attributes at the top of `Source\Chameleon-Patcher.cs`
(currently **1.2.1**):

```csharp
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.1.0")]
[assembly: AssemblyInformationalVersion("1.2.1")]
```

Everything else reads that one declaration back, so it appears in four places: the **file name** of
the built executables (`Chameleon-Patcher-1.2.1.exe`, `Chameleon-Patcher-Overlay-1.2.1.exe`), the
**window title bar** (`Chameleon Patcher 1.2.1`), the file's **Win32 version resource** (`csc.exe` folds it in, no
`.rc` to maintain, so Explorer's Details tab and `(Get-Item Chameleon-Patcher-1.2.1.exe).VersionInfo` show
it), and **every patch log header**, stamped at runtime. Bumping a release means editing those
attributes and rebuilding with `.\Source\Build.ps1`; keep `AssemblyVersion` at `x.y.0.0` and let the
file and informational versions carry the precise one.

One limit, because it is the way the number *can* mislead: the version lives in the compiled GUI,
while everything the GUI runs is plain PowerShell. The standalone build freezes the scripts it was
built from, so its number is exact for them. The overlay build reads `Scripts\` beside the `.exe`, so a
run is identified by the version **plus** that revision; an overlay `.exe` in a working tree whose
scripts have moved on stamps an older number over newer behaviour. Cutting a
release means a dated `CHANGELOG.md` heading, the bumped attributes, a green `.\Tests\Run.ps1`, a
push of the `v<version>` tag. The release workflow then builds the standalone `.exe` from that tag and
attaches it with its SHA256 (see [Continuous integration](#continuous-integration)). Built `.exe`
files are not committed (`.gitignore` excludes them); the repository carries source only.

`Source\Build.ps1` is a wrapper around `csc.exe`; it compiles every `.cs` in `Source\` (the GUI is
one class spread over `Chameleon-Patcher.cs` and `MainForm.*.cs`). By default it builds only the standalone `.exe`
(`/define:STANDALONE`, every file under `Scripts\` embedded as a resource); `-Variant Overlay` builds
the overlay and `-Variant All` both. Output goes to the **project root**, not beside the script - for
the overlay that placement is load-bearing, because it resolves
`Scripts\Invoke-DriverPatchPipeline.ps1` relative to its own folder. File names carry the version. It prints the version resource it
produced, so a source/Explorer mismatch surfaces at build time. `/win32icon` embeds
`Assets\Chameleon.ico`, and the app reads that icon back out of its own `.exe` for the window and
taskbar, so no `.ico` needs to sit next to the binary.
