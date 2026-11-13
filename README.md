# Chameleon Patcher

<img src="Assets/Chameleon.png" alt="Chameleon Patcher" width="120" align="right">

Chameleon Patcher patches a stock NVIDIA driver package so that it installs and works on GPUs the
package does not recognise - chiefly desktop PCI-E cards carrying a **mobile** GPU core (laptop RTX
20/30/40-series and RTX-Ada mobile parts). Point it at a driver `.exe` downloaded from nvidia.com; it
verifies, unpacks, patches, checks, re-signs and leaves a plain folder `<name>_Patched`.

Two gates come off:

- **The INF PCI ID whitelist** - 61 device/subsystem entries from `Scripts\whitelist.json` (58 in
  `nv_dispi.inf`, 3 in `nvami.inf`), additions only.
- **The driver's internal Resource-Manager check** - `HKR,,RM1457588,%REG_DWORD%,1` in every
  `nv_miscBase_addreg__NN` section. Without it the GPU installs but misreports VRAM and has no
  working compute. NVIDIA ships the same value in its own MSI OEM INF.

Editing INFs invalidates `NV_DISP.CAT`, so the catalog is rebuilt with `Inf2Cat` and signed with a
self-signed certificate minted on your machine. The result installs only where that certificate is
trusted **and** Test Signing mode is on.

Design notes, measurements and known limits are kept in [CHANGELOG.md](CHANGELOG.md#reference-notes).

## Quick start

Double-click `Chameleon-Patcher.exe` (it must stay in the project root, next to `Scripts\`), pick the
driver `.exe` or an unpacked package folder, press **Start Patching**. On success it offers to launch
`setup.exe`; every run is logged to `Logs\patch-*.log`.

| Checkbox | Default | Effect |
|---|---|---|
| Sign with an existing certificate from a .pfx file | off | `-PfxPath`; the .pfx is imported into `Cert:\CurrentUser\My` once, then signing uses the store. |
| Add a certificate-trust checkbox to the installer | **on** | Off = `-SkipSetupCertOption`. |
| Build for this PC only | off | `-PruneForeignOemInfs`: ~2 min instead of ~1 h, but the package only fits this PC. |
| Delete the output folder first | off | Otherwise an existing output folder stops the run. |

From a terminal:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "621.24-desktop-win10-win11-64bit-international-dch-whql.exe"
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourcePackagePath "<unpacked folder>"   # skips the unpack
.\Scripts\Invoke-DriverPatchPipeline.ps1 -CheckPatchTools        # TOOLS_OK / TOOLS_MISSING
.\Scripts\Invoke-DriverPatchPipeline.ps1 -CheckLocalGpuSupport   # SUPPORTED / UNSUPPORTED / UNKNOWN
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "<exe>" -CheckSource   # SOURCE_OK / SOURCE_UNTRUSTED
```

## What you need

- **7-Zip** (or NanaZip / any 7z CLI) - `winget install -e --id 7zip.7zip`. Not needed with `-SourcePackagePath`.
- **Windows SDK** with *Windows SDK Signing Tools* and *Windows Driver Kit* selected (`signtool.exe`,
  `Inf2Cat.exe`) - <https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/>.
- Windows PowerShell 5.1 and .NET Framework 4.x (both part of Windows 10/11).

Patching needs no internet; the only network call is a best-effort RFC 3161 timestamp (`-SkipTimestamp`).

## What a run does

Before anything is unpacked the run checks the tools, the signing identity and **the source**: an
`.exe` must carry a valid NVIDIA signature; a folder must be covered by NVIDIA's signed catalog.
Anything else stops the run (`-SkipSourceVerification` overrides it, and the GUI asks first).

1. **Unpack** (or copy) into `<name>_Patched`. The source is never modified.
2. *(with `-PruneForeignOemInfs`)* **Prune** the OEM display INFs that cannot match this PC's GPU.
3. **Whitelist** - add the entries; new install sections are built from the captured template and
   brought up to date with the closest stock section of this release.
4. **RM override** - add `RM1457588` to every `nv_miscBase_addreg__NN` section.
5. **PhysX / NVIDIA App** - set the per-device feature flags for the unlocked GPUs (`-SkipOptionalComponents`).
6. **Verification gate** - refuses to sign unless every entry, reference and override is in place (`-SkipPatchVerification`).
7. **Certificate** - reuse the project key in `Cert:\CurrentUser\My`, or mint one (non-exportable).
8. **Catalog** - `Inf2Cat`, `signtool /sha1`, then check every INF is a member of the signed catalog.
9. **Installer option** - a "Chameleon GPU cert." row in `setup.exe` (`-SkipSetupCertOption`).

The catalog rebuild dominates the wall clock (single-threaded `Inf2Cat`, ~50 min for 43 INFs);
`Processing INF:` sitting at 100% of one core for a long time is normal.

## Trusting the certificate and installing

From an elevated PowerShell on the target PC:

```powershell
.\Scripts\Approve-DriverPatchCert.ps1          # adds the .cer to LocalMachine Root + TrustedPublisher
bcdedit /set testsigning on                    # Secure Boot off; reboot afterwards
pnputil /add-driver "<name>_Patched\Display.Driver\nv_dispi.inf" /install   # or run setup.exe
```

The main INF's name varies by release (`nv_dispig.inf`, `nv_dispsi.inf`). Instead of
`Approve-DriverPatchCert.ps1`, leave the installer's "Chameleon GPU cert." row ticked (it runs the same
`certutil` commands; that path is less tested). Turn Test Signing off again when you no longer need it
(`bcdedit /set testsigning off`).

To withdraw trust later: `.\Scripts\Remove-DriverPatchCert.ps1` lists what is trusted; add
`-Thumbprint <tp>` or `-AllPatchCerts -KeepThumbprint <tp>` to remove. Packages signed with a removed
certificate can no longer be installed.

## Safety

- Only driver INFs (and `setup.cfg`) are changed; NVIDIA's binaries are not touched, and the source
  must be NVIDIA-signed unless you override that explicitly.
- **Trusting the certificate is the part with real blast radius.** A certificate in `Root` and
  `TrustedPublisher` is accepted machine-wide, and anything running as your user can ask the key in
  your store to sign. Keep the number of trusted patch certificates at one, and remove them when done.
- The key is non-exportable unless you mint with `-Exportable`; a `.pfx`, if you create one, signs
  kernel drivers for every machine that trusts it - keep it private.

## Project layout

```
Chameleon-Patcher.exe   GUI (built from Source\, runs Scripts\Invoke-DriverPatchPipeline.ps1)
Source\                 Chameleon-Patcher.cs + Build.ps1 (csc.exe from .NET Framework, no SDK)
Scripts\                the pipeline; every script also runs standalone
  PatchToolDiscovery.ps1   shared helpers: tool discovery, INF parsing/writing, catalogs, certificates
  whitelist.json           the 61 entries with their captured section templates
Assets\                 icon sources (Build-Icon.ps1)
Logs\, Certificates\, Drivers\, *_Patched*\   runtime state, git-ignored
```

## Version

1.0.6. The version lives in the assembly attributes at the top of `Source\Chameleon-Patcher.cs` and
shows in the title bar, the file properties and every log header. A release is: bump those
attributes, add a dated `CHANGELOG.md` heading, rebuild with `.\Source\Build.ps1`, and commit the
`.exe` together with the scripts it runs.

## Contributors

- **qron88** - author.
- **Qwen (self-hosted LLM)** - analysis and engineering support on 1.0.4.
- **Claude (Anthropic)** - security and correctness review and fixes in 1.0.6.

Licensed under the MIT license - see [LICENSE](LICENSE).
