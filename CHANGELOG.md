# Changelog

All notable changes to Project Chameleon are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version is declared in the assembly attributes at the top of `Source\Chameleon-Patcher.cs`
and nowhere else; see [Version](README.md#version).

## [Unreleased]

### Added

- **Tests for the INF text handling.** `Tests\PatchToolDiscovery.Tests.ps1` covers the shared
  helpers - the section-index walk, device-line matching, `whitelist.json`-to-INF filename
  resolution, reading a certificate thumbprint from a `.cer`, the driver-version parsing, and the
  unpack version guard. `Tests\InfPatchIntegrity.Tests.ps1` builds a synthetic `Display.Driver`
  package, runs the real patchers against it and the verification gate before and after, and
  asserts that the insertions land with the section bodies rather than in the blank gap after them,
  that the patched package passes the gate, that a second pass leaves the file byte-identical, and
  that the INF is still BOM-less UTF-8 with CRLF endings after three writers have opened it. 56
  cases, in Pester 3.4 syntax so they run on PowerShell 5.1 and 7 alike. They paid for themselves
  the day they were written: the section-index helper had been declared with a `[string[]]`
  parameter, and PowerShell refuses to bind an array containing an empty string to one - which
  describes every real INF file, so all three writers would have thrown on the first blank line of
  any real package. The tests caught it before it shipped.
  They also pin the two picks that decide which folder on disk becomes the package. Those were
  added after re-reading the committed stack: the picks chose between folders on disk with less
  information than they needed to, and the entries under Fixed below are the consequence.
- **The installer checkbox refuses the wrong certificate.** `Add-SetupCertOption.ps1` takes
  `-ExpectThumbprint`, defaulting to the certificate that actually signs the package's `.cat`
  files, and throws if the `.cer` it is about to bind differs. Left ticked, that checkbox trusts
  whatever it is handed into `Root` and `TrustedPublisher`, so a stale or hand-picked `.cer` used to
  buy machine-wide trust for a key with no connection to the package being installed.
- **Continued INF lines are reported rather than read past.** `Test-DriverPatch.ps1` warns with the
  count and line numbers when the sections this toolkit patches contain trailing-backslash
  continuations. Every matcher here reads one physical line at a time, so a device entry, a
  `[Strings]` definition or an `RM1457588` override split across two lines is invisible to the
  check that certifies it.
- **Shared primitives in `PatchToolDiscovery.ps1`.** `Get-InfSectionIndex` (where an inserted line
  lands inside a section), one `[section]` header pattern, `Test-InfLineContinuations`,
  `Get-InfDeviceLine` / `Test-InfDeviceIdMatch` extended to `[Strings]` and misc-section lookups,
  `Get-CerThumbprint -Path`, and `Get-DriverVersionTextFromPath` / `Get-PathVersionForSort`.

### Changed

- The whitelist patcher, the RM override and the verification gate now share one section header
  pattern and one section-index walk instead of each carrying its own header regex, so they cannot
  disagree about where an inserted line goes or about where a section ends.
- `Unpack-DriverExe.ps1` asks for the version it was given at both points where it picks from
  several folders on disk: the `setup.exe` to run, and the expansion folder to treat as the package.
  In both places the version is a preference (the paths that name it come first) with the previous
  order as the fallback, because not every route carries a version in its path; what was unpacked is
  then verified against the requested version. Version order, not name order, also decides between
  candidates: with three-part build numbers now in use, text order puts 617.142 ahead of 617.42.

### Fixed

- **A run could silently patch the wrong driver.** With no 7z-compatible CLI installed, the
  installer route expands into `C:\NVIDIA\DisplayDriver\<version>\<os>\Current` and the script then
  chose the newest-looking folder under that root without comparing it to the version the requested
  `.exe` names. An older expansion left there by a previous run - or one the installer reused -
  meant the older package was copied, patched, verified and signed, and came out looking finished:
  every check inside the gate passes, because the package is internally consistent, and the unlock
  for the driver you actually asked for is simply not there. The expansion is now checked against
  the requested version and the run stops with an explanation (and a warning when neither side
  names a version).
- **The version guard stopped runs that had the right driver.** It compared the two versions as
  texts, and a driver branch is routinely spelled two ways - the download says `617.42`, the
  expansion folder NVIDIA wrote says `617.42.0.0`. `[version]` reports that pair as different too,
  because the parts it did not see are undefined (`-1`) rather than zero, so the comparison needed
  normalizing on both sides, which `Get-NormalizedDriverVersion` now does. A guard that stops good
  runs is a guard people turn off, and this one stops a run whose package it was about to sign.
- **The fallback route could disappear mid-run.** `Find-NvidiaSetupExe` treated the requested
  version as a filter rather than a preference, so on a machine whose only `setup.exe` sat under
  the `NVIDIA Display Operation Server` temp folder - a path that carries no version at all - every
  candidate was discarded and the installer route returned nothing. That showed up as "-CheckPatchTools
  says the tools are fine" followed by "neither a 7z-compatible tool nor an NVIDIA installer was
  found" later in the same run. The version now only orders the candidates; the version of what was
  actually unpacked is what the guard checks.
- **`Find-NewestExpansion` picked on write time alone.** It is the pick that decides which folder
  under `C:\NVIDIA` becomes the package that gets patched and signed, and a timestamp says "written
  most recently", not "written by this run": copying a folder, an antivirus scan or a second
  installer run for another version moves one. It now prefers a candidate whose path names the
  requested version, which NVIDIA writes into the path for exactly this reason, and falls back to
  the timestamp where no path names a version. The version check above stays, because on the temp
  route there is no path to read the version from.
- **A continued line was missed when the backslash was followed by spaces.** The continuation check
  tested whether the raw line ends with a backslash; INF tolerates spaces after it and `Get-Content
  ` keeps them, so the exact split the check exists to find went unreported. It now treats the
  backslash as the last non-blank character of the line.
- **The README drifted from the code it describes**, in a full read-through against the scripts
  rather than from a bug report. Six things, none of them a code fault but all of them able to send
  a reader or a bug report to the wrong place: the worked examples still showed `1.0.3` while the
  attributes and the committed binary say `1.0.4`; two step-number references were off by one each
  (the optional-components step is 5 of 9 in a default run, and the catalog rebuild is 7 of 9, not
  7 of 8); the pipeline's own comments on pruning quoted a 399 s catalog rebuild against the 385 s
  every measured table reports, so the comments were corrected to the measurement rather than the
  reverse; the verification gate was described as asserting that every `whitelist.json` INF is
  present, when a vanished INF is a warning that still lets the run pass at `0/0`; the 7z and SDK
  discovery lists omitted the `Program Files (x86)` roots both actually check; and the installer
  checkbox was called "opt-in" in one place and "ticked by default" in two others, which are not the
  same setting. The gate paragraph now states which checks are hard failures and which are warnings,
  and tells the reader to read the gate's `N/N` count rather than its colour.
- **The README overclaimed what its own version number identifies.** It said the number "cannot
  drift", but the number lives in the compiled GUI while everything it runs is read from `Scripts\`
  at start time, so a binary left in a tree whose scripts moved on stamps an older number over newer
  behaviour. The version section now says what a run is actually identified by - the version plus
  the revision of `Scripts\` beside the `.exe` - and the verified-releases table says plainly that no
  end-to-end run is recorded against 1.0.4 or later, that the `Logs\` its numbers come from are
  git-ignored and so absent from a clone, and that the test suite covers the INF handling but is not
  a substitute for a run on real hardware.

## [1.0.4] - 2026-10-12

### Added

- **Unpacking no longer requires a 7z-compatible CLI.** `Unpack-DriverExe.ps1` has a second
  route: NVIDIA's own installer, `setup.exe -x -s`, which expands the package without installing
  a driver. A machine with neither 7-Zip nor NanaZip installed can now patch a downloaded driver
  `.exe`. 7z stays the preferred route - it extracts straight into the folder you name, runs
  nothing, and is faster; the installer route expands to NVIDIA's fixed location under the volume
  root (`C:\NVIDIA\DisplayDriver\<version>\<os>\Current`) and the result is copied into the
  output folder, and it runs the downloaded installer, so it needs the download on this machine.
  Discovery checks `C:\NVIDIA\DisplayDriver` and the `NVIDIA Display Operation Server` temp
  folder; `-SetupExePath` names the installer explicitly. The expansion is polled on the marker
  file rather than slept on, so a 1 GB package is not bounded by a fixed delay, and a failed
  expansion still removes the partial output folder.
- **`-CheckPatchTools` on the pipeline** prints `TOOLS_OK` / `TOOLS_MISSING` with each resolved
  tool path and the install command for anything missing, touching nothing on disk. The GUI asks
  this before starting a run, so the SDK/7-Zip rules live in the pipeline and are not duplicated
  in C# where they could drift.
- **The GUI refuses to start a run it cannot finish, and says what to install.** A missing
  `Inf2Cat` or `signtool` - the two dependencies with no substitute - now stops before anything
  is unpacked, with a dialog naming each tool and carrying its install command, and stating that
  nothing was changed. Previously that only surfaced in the log, after the run had begun, and the
  catalog rebuild is the step that takes tens of minutes. A missing 7-Zip is not a refusal: the
  status line notes the slower fallback route and the run proceeds.
- **`Get-MissingToolHelp`** turns a missing tool into install guidance inside the message that
  refuses the run, replacing a "not found under Windows Kits" with what to do about it. The SDK
  guidance names the two features that matter — **Windows Driver Kit** for `Inf2Cat.exe` and
  **Windows SDK Signing Tools** for `signtool.exe` — and links Microsoft's SDK download page;
  those feature names were read out of a real SDK install, not guessed. 7-Zip keeps a `winget`
  command.
- **Global crash handlers in the GUI.** `AppDomain.UnhandledException` and
  `Application.ThreadException` are hooked. An exception escaping an `async void` handler
  (`BtnStart_Click` is one) used to be rethrown on the Windows message loop and take the app down
  as a raw Win32 crash - no message, and the run's log ending mid-patch with no recorded reason.
  A crash now writes a `[crash]` line into the run log when one is open and shows one readable
  dialog. The log is this tool's primary diagnostic artifact, so a crash that leaves it silent was
  the worst available failure mode.
- **A verified driver-release matrix in the README** - see
  [Verified driver releases](README.md#verified-driver-releases): 595.79, 616.86, 616.92, 617.14
  and 617.42, each with the toolkit version, the build type, the verification gate's own verdict
  and the outcome, with the 617.x rows read out of the run logs. It states what "verified" covers
  (pipeline completed, gate passed, catalog signed) and what it does not (installed and driven on
  real hardware), and says plainly that Blackwell is out of scope.

### Changed

- **The README no longer claims "on any driver version".** The patching is *built* for any
  release - no hardcoded section numbers, stem-based INF filename resolution - which is not the
  same as being verified on one, and the old wording let the two read as a single claim. The
  intro, the file table and the usage section now point at the verified-release matrix, and the
  usage section names `Patch verification PASSED - N/N whitelist entries in place` as the line to
  check on an unlisted release. That is the failure NVIDIA's INF renames used to produce: a
  package that unpacks, patches, signs and installs cleanly with no unlock in it at all.
- **The dependency list is now the minimum install, not a survey.** One section separates what
  Windows 11 already ships (PowerShell 5.1, .NET Framework 4.x, `certutil`, the PKI module,
  `Get-CimInstance`) from the one thing you install: the **Windows SDK**. The old text said
  "Windows SDK/WDK", which reads as a heavier install than is needed - a full Windows Driver Kit
  is not required. `Inf2Cat.exe` ships in the SDK's Windows Driver Kit feature and `signtool.exe`
  in Desktop Core Tools. 7-Zip moved from a requirement to an optional speed option.
- **PowerShell 7 is documented as a deliberate non-dependency.** The scripts use no PS 7-only
  syntax, PS 7 is an optional install rather than part of Windows, and the goal is the lowest bar
  for the end user, so requiring it would add an install for no benefit. `Invoke-NativeTool`
  already works around a PS 5.1 quirk (redirecting a native command's stderr under
  `$ErrorActionPreference = 'Stop'` wraps each line in a `NativeCommandError` and aborts the
  script even when the exe returned 0), and that workaround stays.

### Fixed

- **A missing SDK was reported one tool at a time, and only from the pipeline.**
  `Assert-PatchTools` resolved `Inf2Cat` and `signtool` through direct calls, so the first missing
  tool threw and the second was never reported - a machine with no SDK got one message, installed
  half of what it needed, and hit the next one later. Both are now resolved independently and
  reported together.
- **A 7z path passed explicitly could be silently replaced.** With `-SevenZipPath` naming a CLI
  that does not exist, the new fallback logic would have quietly switched to the installer route.
  Naming a CLI is a hard request: it now fails loudly with the path it could not find.

## [1.0.3] - 2026-10-07

### Fixed

- **A run could permanently destroy the signing key it should have reused.** The pipeline found
  its certificate only through the `.cer` files in `Certificates\`. With that folder deleted or
  emptied, it concluded there was no certificate, minted a new one, and the old-key cleanup then
  deleted the existing certificate from `Cert:\CurrentUser\My`. That key is non-exportable, so it
  was gone for good, while its trust entry stayed behind in `LocalMachine\Root`. When no `.cer`
  leads to a key, the store is now searched by subject (a valid code-signing certificate with a
  private key, preferring one already trusted in `Root`, then the latest expiry), and the
  missing `.cer` is re-exported. An explicit `-PfxPath` turns the search off.
- **Old signing keys were pruned before signing, and on runs that had just minted a
  replacement.** The cleanup now runs only after the catalog is signed, so a failed run never
  costs a key, and it is skipped on a run that minted a new certificate.
- **Closing the GUI mid-run did not stop the run.** The window said closing would abort the
  patch, but the hidden `powershell.exe` and the 7z / Inf2Cat / signtool processes it started
  kept running with nothing to report to. Closing now stops the whole process tree
  (`taskkill /T`), logs that it did, and ignores late output from the dying child. The 20 s
  pre-run queries also stop their full process tree when they time out.
- **A path ending in a backslash broke the GUI's command line.** A drive root such as `D:\` was
  quoted as `"D:\"`, which the Windows command-line rules read as an escaped quote, merging every
  following argument into one. Arguments are now quoted by those rules (trailing backslashes
  doubled), and a typed folder path loses a trailing separator.
- **`Sign-DriverPackage.ps1` run on its own could not find a certificate minted by 1.0.2.** Its
  default looked only for the legacy `DriverPatchSigning.cer`. It now uses the same candidate
  order and store search as the pipeline.
- **`Approve-DriverPatchCert.ps1` could trust a different certificate from the one the pipeline
  signs with.** It preferred the legacy `DriverPatchSigning.cer` over the thumbprint-named
  files, the opposite of the pipeline. It now uses the shared candidate order and picks the
  certificate whose key is on the machine; on a machine without the key, the first existing
  candidate.
- **The patcher, the prune step, the optional-components step and the verification gate each
  matched INF device lines by their own rule.** A stock line such as `...&SUBSYS_X&REV_A1`
  counted as the whitelist entry for the patcher, which then skipped it, but not for the gate,
  which then failed the run with a misleading "not correctly patched". A line with `&CC_...`
  counted for the patcher but not for pruning, so the INF serving the GPU through such a line
  could be pruned. All four now use one parser and one matching rule (`Get-InfDeviceLine` /
  `Test-InfDeviceIdMatch` in `PatchToolDiscovery.ps1`), which also ignores trailing `;`
  comments.
- **An entry present in only one `[NVIDIA_Devices...]` block was treated as present
  everywhere.** Each block serves a different OS target. The patcher now adds the line to every
  block that lacks it, reusing the section the other block uses, and the gate checks every block.
- **The installer checkbox trusted the certificate in `Root` only.** `Approve-DriverPatchCert.ps1`
  adds `Root` and `TrustedPublisher`; the checkbox now does the same, so installing through
  `setup.exe` does not stop at a "Would you like to install this device software?" prompt.
- **A failed prune could not be undone.** `Remove-ForeignOemInfs.ps1` deleted INFs before
  verifying the result, so a failure partway left them gone. They are now moved to a staging
  folder and deleted only after verification passes; a failure moves them back and restores the
  manifest. `Enable-OptionalComponents.ps1` likewise restores `setup.cfg` if its edit does not
  verify.
- **A pruned build warned about whitelist INFs it had just pruned on purpose.** On an A2000m
  box, `-PruneForeignOemInfs` removes `nvami.inf` because its three entries are all RTX A3000m,
  and then the whitelist step, the optional-components step and the verification gate each
  warned that the INF was missing and that "NVIDIA may have renamed or dropped" it. Three
  warnings on every pruned run teach you to ignore the one that matters. The pipeline now records
  which whitelist INFs the prune step removed and passes them on (`-PrunedInf`); those are
  reported as a note, while a whitelist INF missing for any other reason still warns. If every
  whitelist INF was pruned, the whitelist step now says there is nothing to unlock on this PC
  instead of suggesting the INFs were renamed.
- **The GUI's "Select .exe..." button had its top edge clipped.** The hint label above it had no
  explicit height, so it took the 23 px default, overlapped the top 2 px of the button and, being
  in front of it, hid that strip including the hover highlight. The label now has a fixed height,
  and the "Or select an unpacked folder..." button below no longer overlaps the bottom edge either.

### Changed

- **The GUI's signing-certificate fields are hidden unless asked for.** The normal case never
  needs them: the key is found in the certificate store, and a PC without one gets a new
  certificate, both without a password. The `.pfx` path and password now appear only after
  ticking "Sign with an existing certificate from a .pfx file", with one line each saying what
  the ticked and unticked states do; while it is unticked the fields are ignored, and unticking
  clears the password. Starting with the box ticked but the `.pfx` file or its password missing
  stops before the run and offers to fill them in or untick the box. When a run fails because a `.pfx`
  password is needed, the GUI opens the fields, pre-fills the project's default `.pfx` if there
  is one, and says what to enter. The window now lays itself out from the controls actually
  shown, so it shrinks and grows with the `.pfx` fields and the log panel.
- **The GUI no longer freezes while it checks the GPU and output folder before a run.** Both
  queries now run off the UI thread, with the inputs locked until the run starts or is
  abandoned.
- Documentation brought in line with the code: `Add-SetupCertOption.ps1`'s header described the
  checkbox as unticked by default, and several examples still named the legacy `.cer`.

## [1.0.2] - 2026-10-06

### Fixed

- **`Add-SetupCertOption.ps1`'s restore path always failed verification.** `$disposition` was
  assigned only in the branch that writes `setup.cfg` fresh, but the structural check after the
  commit compares the written disposition against that variable on BOTH paths. On the restore
  path (a previous run interrupted after the `setup.cfg` edit, component folder missing) the
  variable was `$null`, so the check always threw - and the rollback then deleted the folder the
  script had just restored, leaving the package in the same broken state with no way out. The
  variable is now defined before the branch, so the restore path verifies against the intended
  disposition.
- **The installer checkbox re-added the redundant `CA` trust entry.** `templates\GpuUnlockCert.nvi.template`
  still ran `certutil -addstore CA` in both its install and repair phases, even though the project
  deliberately stopped writing the `CA` store for self-signed certificates (see
  `Approve-DriverPatchCert.ps1` and the README) - so every package built with the default
  pipeline re-created the redundant second trusted-authority entry. The two `CA` phases are
  removed from the template; only the `Root` entry remains, and the component's description text
  no longer claims a "root/intermediate CA".
- **`Unpack-DriverExe.ps1` left a partial folder behind after a failed extraction.** The output
  folder was created before 7z ran, so an extraction that failed partway (corrupt archive, full
  disk) left a partial folder that made the next run die instantly on the "Output path already
  exists" guard. The extraction is now wrapped so a failure removes the partial folder before
  rethrowing, and a re-run starts clean.

### Changed

- **`New-DriverSigningCert.ps1` exports `DriverPatchSigning_<thumbprint>.cer`** instead of
  overwriting the fixed-name `DriverPatchSigning.cer` on every run. Each minted certificate now
  has its own unambiguous public file, and minting a new certificate no longer silently re-points
  the old file. The pipeline checks the thumbprint-named files (newest first) before the legacy
  fixed name, and `Approve-DriverPatchCert.ps1` falls back to the most recently minted one when
  the legacy name is absent - so existing `DriverPatchSigning.cer` files keep working unchanged.
- **`Add-ExtraGpuSupport.ps1`'s section-reuse check now sees past extra line qualifiers.** The
  pattern that looks for an already-whitelisted bare device id required the line to end right
  after `DEV`/`SUBSYS`, so a stock line carrying an extra qualifier (e.g. `&CC_030000`) was
  missed and a fresh section family was created from the template instead of reusing the
  existing one. The pattern now also accepts a following `&`, so the reuse optimization applies
  to those lines too.

## [1.0.1] - 2026-09-18

### Added

- **Automatic cleanup of old signing keys.** Every pipeline run now prunes the pile of old
  driver-patch signing certificates from `Cert:\CurrentUser\My`, keeping only the certificate that
  run signed with. This is the safe half of certificate cleanup: per-user, no elevation, and it
  withdraws no trust, so it cannot break an already-patched package. Pass `-KeepAllOldCerts` to
  opt out. The destructive half — withdrawing trust from the Root / CA / TrustedPublisher stores —
  remains opt-in via `Remove-DriverPatchCert.ps1`.

### Fixed

- **7z discovery in `Unpack-DriverExe.ps1` skipped NanaZip.** The unpack step carried its own
  simplified `Find-SevenZip` that did not check the NanaZip candidate, so a machine with only
  NanaZip installed passed the pipeline's preflight (which does check NanaZip) but then failed at
  extraction, after the run had already started. The unpack step now reuses the shared
  `Find-SevenZip` from `PatchToolDiscovery.ps1` via dot-source, so preflight and extraction always
  agree on which 7z CLI to use.
- **INF patches silently flipped the file's BOM state.** `Set-Content -Encoding UTF8` always writes
  a UTF-8 BOM, but NVIDIA's stock INFs are BOM-less UTF-8, so a patch that rewrote an INF added a
  BOM the stock file did not have - an unnecessary encoding diff in a signed package. The patching
  scripts now rewrite INFs through a shared `Write-InfLines` helper (in `PatchToolDiscovery.ps1`)
  that detects the file's original BOM state and matches it. `Add-ExtraGpuSupport.ps1`,
  `Add-RmCapabilityOverride.ps1` and `Enable-OptionalComponents.ps1` all use it now.
- **GUI status label rendered over the buttons.** The status label was positioned at
  `ClientSize.Height - 25`, which put it on top of the "Show details" / "Open log folder" buttons
  the moment a run finished, its text rendering over them. It now sits at a fixed position in a
  dedicated status row below the buttons, and the window heights were adjusted to make room.
- **GUI could hang when the child filled the stderr buffer.** The GUI read only stdout and never
  drained stderr. In a redirected, non-interactive context the pipeline's `Write-Host` banners land
  on stderr, so a child that filled the stderr buffer would block on write and never exit, hanging
  the GUI with no reason. The GUI now drains both streams concurrently and waits for the 20 s
  timeout before consuming them, so the bound is real rather than checked after the fact.
- **Signing password lingered in the box after a run.** The password field is now cleared once a
  run finishes, so a signing password is not left sitting on screen. Retyping it for a retry is the
  price of not keeping it visible.

## [1.0.0] - 2026-09-11

First public release. Everything below describes the state of the toolkit at that point rather
than a change against a previous published version.

### Added

- **`Chameleon-Patcher.exe`** - a WinForms GUI over the whole pipeline, compiled by the .NET
  Framework's built-in `csc.exe`. No SDK, no package restore and no internet access needed.
- **`Scripts\Invoke-DriverPatchPipeline.ps1`** - one command from a downloaded driver `.exe` to a
  patched, signed package: unpack, patch, verify, sign, add the installer checkbox.
- **PCI device/subsystem whitelist patching** (`Add-ExtraGpuSupport.ps1`) driven by
  `whitelist.json`, with no hardcoded INF section numbers, so it survives NVIDIA renumbering
  sections between releases.
- **RM capability override** (`Add-RmCapabilityOverride.ps1`) - adds `RM1457588` to every
  `nv_miscBase_addreg__*` section, fixing VRAM misreporting and broken compute on unlocked GPUs.
  This is a second, separate unlock from the PCI ID whitelist.
- **A verification gate** (`Test-DriverPatch.ps1`) that runs before signing and refuses to
  continue if the patches did not actually apply, so a silently-unpatched package can never be
  signed and shipped as finished.
- **Passwordless signing** from the certificate store, keeping the signing key non-exportable in
  `Cert:\CurrentUser\My` so no `.pfx` password ever reaches a command line.
- **`-PruneForeignOemInfs`** - drops OEM display INFs that cannot match the building machine,
  taking a run from roughly 57 minutes to about 2.
- **Optional-component enabling** (`Enable-OptionalComponents.ps1`) so PhysX and the NVIDIA App
  are offered for unlocked GPUs, and the NVIDIA App can be unticked.
- **Certificate lifecycle scripts** for creating, trusting and later removing patch certificates.
- **Per-run logging** to `Logs\patch-YYYYMMDD-HHMMSS.log`, flushed per line so a log survives a
  crash or a kill, and carrying the tool version, real Windows build and full child command line.
- **Version metadata** in the executable's Win32 version resource, its window title bar and every
  log header, all read from one set of assembly attributes.
- **`Source\`** - the GUI's commented source and `Build.ps1`, which rebuilds the `.exe` into the
  project root and prints the version resource it produced.

### Fixed

- **INF filename resolution across driver releases.** NVIDIA renames display INFs between builds,
  and in two different ways: 616.86 appends a letter (`nv_dispi.inf` becomes `nv_dispig.inf`)
  while 616.92 Studio replaces the trailing one (`nv_dispsi.inf`). Resolution now tries an exact
  match, then `<stem>*.inf`, then `<stem minus its last character>*.inf`, reporting which file
  stood in. Previously a rename made the whitelist step silently patch nothing while the rest of
  the pipeline reported success, producing a correctly signed package with no GPU unlock at all.
- **Pruning could delete every display INF.** The "never prune to nothing" guard resolved its
  fallback set through the same renaming-aware lookup, so on 616.92 the fallback itself matched
  nothing, the keep set stayed empty, and all 45 display INFs were deleted - leaving a 3.6 GB
  package containing no INF and reporting `Manifest and disk agree: 0 INF(s) each` on the way
  out. The guard now re-asserts after the fallback and refuses to prune instead.
