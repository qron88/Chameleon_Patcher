# The GUI

How the app behaves and why, beyond what the [README](../README.md#using-the-app) shows. Part of the [Chameleon Patcher](../README.md) documentation.

## How it runs the pipeline

`Chameleon-Patcher-<version>.exe` (or the overlay `Chameleon-Patcher-Overlay-<version>.exe`) is a
small WinForms app that runs `Scripts\Invoke-DriverPatchPipeline.ps1` as a child `powershell.exe` (started from `System32\WindowsPowerShell\v1.0`, not by bare name) and parses
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
`-CheckLocalGpuSupport`, `-CheckPatchTools`, `-CheckSource`, `-CheckNvAppStaged`), each with `-Json`:
the answer is one line of JSON with a `verdict` property and the details as fields, so the GUI no
longer recognises verdict words, prefixes and indentation in text. The pipeline forces UTF-8 stdout
because a windowless child otherwise writes in the OEM codepage. One text contract remains, in the
run's own output stream rather than in a query: the `.pfx` failure is recognised by its phrase.

When the window opens, the GUI asks whether NVIDIA App has already downloaded a driver
(`-CheckNvAppStaged` - its own update framework stages a fully unpacked package under
`C:\ProgramData\NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts\grd\post-processing\<hash>`,
which is a valid `-SourcePackagePath` source as-is). If one is staged, the GUI offers it by version and
date; accepting fills the source box, declining leaves the window as it was. The offer is only a
prefill: the staged package is still copied (NVIDIA App's own files are never touched), checked
against NVIDIA's signatures - driver files through the catalog, installer programs by their own
signature; see [Source verification](pipeline.md#source-verification) for what that cannot
cover - and then patched and re-signed by the usual flow when Start is pressed. The output goes to
your `Downloads` folder (`NVIDIA-<version>-<hash8>_Patched`), because the staging folder belongs to
NVIDIA App. Outputs that 1.2.0 left beside the staged folder (`<hash>_Patched`) are never offered -
they would fail source verification as already-patched folders.

The standalone build unpacks its scripts to `%LOCALAPPDATA%\ChameleonPatcher\Scripts` at start. If
that fails, Start is disabled for the session rather than running whatever older scripts are there,
and scripts a newer build no longer ships are removed from that folder.

Before a run starts, the GUI checks which external tools this machine can resolve and refuses to begin
when one is missing, naming each tool and offering a button that opens its download page - **Open the
7-Zip download page**, **Open the Windows SDK download page**, or both. Nothing is unpacked and nothing
is changed at that point. The check exists because the catalog rebuild takes tens of minutes: finding
out the SDK is missing after a multi-GB unpack is the expensive order. It then verifies the source and,
if that fails, asks before overriding. Ticking "Build for this PC only" on a machine this toolkit does
not unlock gets a dialog offering the portable build instead, and answering yes unticks the box so the
log header and the output folder name reflect what was actually built.

Closing the window mid-run asks first, then ends the pipeline's `powershell.exe` and everything it
started (7z, Inf2Cat, signtool) and records it. What the run had built so far stays in
`<output>.partial`, which the next run removes on its own; the final output name is never created
by a run that did not finish, so a partial package cannot be mistaken for a finished one. An unexpected error is
recorded, not swallowed: `AppDomain.UnhandledException` and `Application.ThreadException` are hooked,
so an exception escaping an `async void` handler writes a `[crash]` line into the log and shows one
readable dialog instead of taking the app down with the log silent mid-patch.

## Patch logs

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
