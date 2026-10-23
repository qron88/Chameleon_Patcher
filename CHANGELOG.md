# Changelog

All notable changes to Project Chameleon are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version is declared in the assembly attributes at the top of `Source\Chameleon-Patcher.cs`
and nowhere else; see [Version](README.md#version).

## [Unreleased]

## [1.0.5] - 2026-10-23

### Added

- **Tests for the INF text handling.** `Tests\PatchToolDiscovery.Tests.ps1` covers the shared
  helpers - the section-index walk, device-line matching, `whitelist.json`-to-INF filename
  resolution, and reading a certificate thumbprint from a `.cer`.
  `Tests\InfPatchIntegrity.Tests.ps1` builds a synthetic `Display.Driver`
  package, runs the real patchers against it and the verification gate before and after, and
  asserts that the insertions land with the section bodies rather than in the blank gap after them,
  that the patched package passes the gate, that a second pass leaves the file byte-identical, and
  that the INF is still BOM-less UTF-8 with CRLF endings after three writers have opened it. Those 58
  cases run in Pester 3.4 syntax, so they run on PowerShell 5.1 and 7 alike. They paid for themselves
  the day they were written: the section-index helper had been declared with a `[string[]]`
  parameter, and PowerShell refuses to bind an array containing an empty string to one - which
  describes every real INF file, so all three writers would have thrown on the first blank line of
  any real package. The tests caught it before it shipped.
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
- **A reader and a writer that agree about the bytes of a package file.** `Get-InfTextFile` sniffs a
  file's BOM, decides UTF-8 or this machine's ANSI codepage by trial - strict UTF-8 first, with a
  warning naming the codepage it settled on - and records which line terminator the file uses and
  whether its last line is terminated at all. `Write-InfLines -State` and `Write-InfText -State`
  write it back with those same settings, and `Get-AnsiEncoding` is what the fallback reads its
  codepage from. Every step that rewrites a package file goes through them now - the whitelist
  patcher, the RM override, the optional-components step, the prune step, `Add-SetupCertOption.ps1`
  - and so do the verification gate's own two reads, so the gate certifies the bytes the patchers
  actually wrote instead of the bytes it assumed.
- **Two more suites, one per behaviour this release changes.**
  `Tests\ExtraGpuSectionPlacement.Tests.ps1` (11 cases) patches a fixture whose *last*
  `[NVIDIA_Devices*]` block ends in a blank tail at end of file, which is the case an insertion rule
  gets wrong when it treats a section's exclusive upper bound as its insertion point, and checks
  that every insertion lands inside a device section. The same fixture then checks what the patchers
  leave behind byte-wise - a BOM stays a BOM, LF-only lines stay LF-only, a byte outside UTF-8
  survives the patch and reads back the same - and the RM override patcher gets those three byte
  checks too. `Tests\ForeignOemPrune.Tests.ps1` (8 cases) covers the prune step: which INFs survive,
  the keep-everything fallback, what the safety net says about hardware that is present but not
  installable through the INF it kept, and what happens to the manifest's own bytes. Four of those
  eight fail against the previous revision of `Remove-ForeignOemInfs.ps1`, so they pin the fixes
  below rather than describe the code as it now stands. 61 cases in all.
- **A device line whose name was never defined says so.** An INF with no `[Strings]` section still
  takes the device entry and still installs, but the `%token%` in its device name is never defined,
  so Device Manager shows the token itself. The patcher now warns once per INF instead of leaving
  that to be noticed in Device Manager.

### Changed

- The whitelist patcher, the RM override and the verification gate now share one section header
  pattern and one section-index walk instead of each carrying its own header regex, so they cannot
  disagree about where an inserted line goes or about where a section ends.
- **A device entry lands with the body it belongs to.** The whitelist patcher used a section's
  `EndIndex` as its insertion point, and `EndIndex` is an exclusive upper bound: the line went in
  after the block's blank tail, immediately before the next `[section]` header. That is still part
  of the section as far as the installer and `Inf2Cat` are concerned - no release breaks over it -
  but it is the line a person editing that INF reads as belonging to the section below, and a blank
  tail is precisely what every other writer here walks back over. Entries now go through
  `Get-InfSectionIndex`, the walk the RM override and the optional-components step already used, one
  insertion point per device block, applied last-block-first so the earlier indexes stay valid. The
  spliced `SectionExtraGPU*` family is captured while walking and appended after the entries,
  instead of being inserted into a buffer that the entry insertions are still shifting around.
- **A `whitelist.json` INF that resolves to nothing is an error, not a warning.** Its entries came
  out of the gate's `N/N` count while the run still reported `PASSED`, which is how a universal
  build that lost `nv_dispi.inf` to a rename nothing could resolve reached the signing step at
  `0/0`, with a stderr line as its only trace. A deliberate prune is unaffected: the pipeline
  records which whitelist INFs the prune step removed and passes them to every later step as
  `-PrunedInf`, and those stay the plain note they were. The README-drift entry under Fixed above
  records the warning as it then behaved; this is what replaced it.
- **Only the catalogs Inf2Cat actually rebuilt get signed.** `Sign-DriverPackage.ps1` compares the
  `.cat` files in the folder with what was there before the rebuild. What Inf2Cat wrote or rewrote
  is signed. A catalog whose INF is still in the folder is signed too, with a warning that Inf2Cat
  did not regenerate it and so did not confirm what it covers. A catalog with no INF of the same
  name left in the folder - what a pruned or reused package accumulates, because Inf2Cat writes
  catalogs and never deletes one - is named with its last write time and left unsigned: signing it
  would only dress the leftover up as current.
- **`New-DriverSigningCert.ps1` can no longer overwrite the certificate you trusted.** The `.cer`
  and the `.pfx` are both named after the certificate's thumbprint, and neither is rewritten if it
  already exists: the fixed name meant a second run re-pointed the public file away from the
  certificate you had actually trusted, and on the `.pfx` it replaced the private key behind every
  catalog already signed with the first one, silently. Minting a second valid certificate under a
  subject already in `Cert:\CurrentUser\My` also stops now, and says to sign with that one instead -
  two certificates with one subject are indistinguishable in every UI that shows them, and trusting
  one while signing with the other is a driver install Windows refuses for no visible reason.
  `-Force` overrides that. An expired namesake does not: minting the next certificate is the right
  answer when the old one aged out, so those are reported as clutter rather than treated as a
  conflict. The script warns when a `-Subject` matches none of the patterns the toolkit recognises a
  project certificate by, which is how a custom subject used to end up invisible to the next run and
  to the certificate cleanup alike. Legacy `DriverPatchSigning.cer` and `DriverPatchSigning.pfx`
  keep working as inputs; they are simply no longer written to.
- **The signing password no longer sits in the pipeline's own environment.** It was set as
  `$env:DRIVER_PATCH_PFX_PASSWORD` on the pipeline process to be inherited by the signing child,
  which means anything running as this user could read it for the whole run. It is now handed to the
  child through that child's environment block and removed from the pipeline's own, and the
  scripts downstream use the secure string they were passed.
- **The GUI pre-fills a `.pfx` name the toolkit actually writes.** Its fallback for a run that
  stopped because the key is not on this machine was the fixed `Certificates\DriverPatchSigning.pfx`
  - a name this toolkit stopped writing when the exports became thumbprint-named. It now takes the
  most recently written `DriverPatchSigning*.pfx` in that folder, which is the one that matches the
  certificate the failed run was looking for, and still finds a legacy fixed-name file when that is
  what is there.
- **`Find-SevenZip` looks for a NanaZip installed as an application too**, under `Program Files` and
  `Program Files (x86)`, not only the `7z.exe` alias the Store app registers in WindowsApps.
- **`-CheckPatchTools` and the GUI treat a 7z-compatible CLI as required.** A machine with no 7z
  CLI answers `TOOLS_MISSING`, the GUI stops the run before unpacking anything, and both print the
  guidance names the page that installs what is missing (`https://7-zip.org/` for 7-Zip, the Windows
  SDK download page for the two catalog tools) and keeps the `winget` line for whoever reads it in a
  terminal. The query does no recursive folder scanning any more, and the status line names the CLI a
  run will unpack with.
- **The refused-run dialog reads as a message now, and it can be copied out of.** The GUI composes
  its own text from the tool report instead of pasting the report in: what is missing is named in
  words ("a 7z-compatible CLI (7-Zip or NanaZip)"), the tools that *were* found are named without
  their 70-character paths - those paths are what used to wrap straight through the middle of a
  sentence - and the guidance is re-flowed into full-width paragraphs rather than copied one
  pipeline line at a time, which is what left it ragged and indented deeper with every line. Only a
  command or a download address keeps a line to itself, and a word longer than the width (a URL, a
  path) is never split. It is a window laid out like the MessageBox it replaced - error icon, the
  system message font, nothing in its title bar, buttons along the bottom right - with the message
  painted as plain labels (nothing selected, nothing to scroll, no line cut at the window edge) and
  one button more, which is something a MessageBox cannot have: it opens the download page of what is
  missing in the default browser - **Open the 7-Zip download page**, **Open the Windows SDK download
  page**, or **Open both download pages** when both are needed. Opening a page is your browser
  reaching the network, and it is a convenience, not a requirement - the patching itself still needs
  no network for this. The guidance was rewritten for that reader: it names the page to open, and the
  `winget` command stays in the console answer, where a terminal is already open.
- **Both SDK tools missing is described once.** Asking for `Inf2Cat.exe` and `signtool.exe` together
  used to print two blocks that each repeated the same download address and the same advice, which
  reads as two problems when there is one installer to fetch. One block now names the two SDK
  features that have to stay selected - which is the part a person actually gets wrong.

### Fixed

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
- **Two couplings that were nobody's to read about are now written down.** The GUI identifies a
  missing `.pfx` password by matching the literal phrase `none was supplied and prompting is
  disabled` in the child's output and only then offers the `Import-PfxCertificate` line that fixes it
  for good, so that phrase is an interface between `Chameleon-Patcher.cs` and the two scripts that
  raise it: reword it and the hint disappears while the run still fails for the same reason. And
  `Enable-OptionalComponents.ps1` only warns, then skips, when a whitelisted device line points at an
  install section that does not exist, where `Test-DriverPatch.ps1` treats the same condition as
  fatal - so the case still stops a run, just at the gate rather than at the step. Both are written
  up as they already behave; neither is a code change.
- **A package file that is not UTF-8 was rewritten as UTF-8.** Every writer here read an INF with
  `Get-Content` and wrote it back through a UTF-8 writer, so a BOM-less INF carrying a byte outside
  UTF-8 - a legacy codepage in a device description, and these INFs are old enough to carry one -
  came out different from what went in. On PowerShell 5.1 `Get-Content` decoded it in the ANSI
  codepage and the writer emitted UTF-8, doubling each such byte; on PowerShell 7 `Get-Content`
  decoded it as UTF-8 and the unreadable bytes arrived as U+FFFD, which the writer wrote out
  faithfully. Either way a signed package ended up containing text the stock package never had. The
  writers read through `Get-InfTextFile` now, which names the encoding it settled on and writes the
  file back in that encoding. This is verified against a fixture written in this machine's ANSI
  codepage, not against a real NVIDIA INF: no package on this machine is known to be non-UTF-8.
- **Line endings were normalised on the way through a patch.** The shared writer joined every line
  with CRLF, so a package file whose lines end in LF alone came back with every one of its lines
  rewritten - a patch that was supposed to add two device lines produced a diff of the whole file,
  in a folder whose contents are about to be catalogued and signed. The reader records the
  terminator the file actually uses and the writer uses it, including whether the final line is
  terminated at all, so a file that went in LF-only comes out LF-only and a file with no final
  newline does not gain one. This is also how `package.nvi` and `setup.cfg` are read and written
  now, so editing a manifest no longer re-encodes the manifest.
- **A manifest rewritten by the prune step lost its BOM, and its rollback was not a rollback.**
  `Remove-ForeignOemInfs.ps1` read `package.nvi` as text, which drops the BOM it finds, and wrote it
  back as UTF-8 without one; the failure path then restored that text rather than the bytes it had
  found. A manifest that started with a BOM ended up without one on a successful run, and a run that
  failed verification put back a different file than it had changed. The manifest is read as text
  for the edit and rolled back from bytes now, so the undo restores the file instead of an
  approximation of it. `Enable-OptionalComponents.ps1`'s `setup.cfg` and `Add-SetupCertOption.ps1`'s
  manifest copy work the same way.
- **The prune step vouched for hardware the INF it kept cannot install.** Its safety net - the one
  that speaks up when an INF the toolkit patches is about to be pruned - compared device IDs only.
  A foreign-OEM INF whose device id matched this GPU but whose subsystem did not was reported as
  covered by `whitelist.json`, quoting an entry that does not describe this card, while the GPU
  actually present ended up with no INF that can match it. It answers for device *and* subsystem
  now, and names which of the two it found: an entry that covers this exact GPU but lives in no INF
  in this package is a note that the GPU will be supported once the package is patched, and an INF
  nothing in the whitelist covers is a warning naming the device and subsystem that are really
  there.
- **The files a pruned INF leaves behind are reported.** A pruned INF's catalog and filter files
  share its stem, and they stay in the folder with their manifest entries: nothing here can
  establish whether an INF that was kept references them, so deleting them is not something this
  toolkit can verify - but leaving them silently was equally unreported. The step now says plainly
  which companions were left, file and manifest entry both, and warns when the manifest names a
  companion that is not on disk.

### Removed

- **The alternative unpack route is gone, and with it everything that drove it.** Twelve helper
  functions in `PatchToolDiscovery.ps1` and `Unpack-DriverExe.ps1`, the `-SetupExePath` parameter of
  `Unpack-DriverExe.ps1`, the extra scan roots and the poll that counted files and bytes written
  while a package expanded into a folder the toolkit did not choose, the unreadable-root check, the
  version guard against a cached expansion, and the 31 cases covering all of it are removed. A
  driver download is unpacked by a 7z-compatible CLI or not at all, and a missing CLI fails the
  preflight naming what has to be installed and where to get it. The names
  that were deleted are readable in the history of those two files.
- **The driver-version path helpers.** `Get-DriverVersionTextFromPath`, `Get-PathVersionForSort`
  and `Get-NormalizedDriverVersion` read a driver version out of a path, or compared two version
  texts as versions. Nothing in this toolkit reads a driver version out of a path any more, so no
  script here needed them, and helpers used only by their own tests are how a toolkit accumulates
  code nobody is willing to delete.

**A note about the tests.** The four suites under Added were written and run green during this
release, but the `Tests\` folder was lost on the machine the work was done on before this entry was
committed. What git carries for `Tests\` is the pair of files from before 1.0.5, and those exercise
helpers this release deleted; the two suites written for the changed insertion rule and for the prune
step were never committed at all. So the case counts above describe the suites as they were written
and verified, not as they are committed, and `Invoke-Pester Tests` on this tree runs cases that no
longer match these scripts. The README's [Tests](README.md#tests) chapter says the same thing, and it
is the specification to rebuild from.

## [1.0.4] - 2026-10-12

### Added

- **`-CheckPatchTools` on the pipeline** prints `TOOLS_OK` / `TOOLS_MISSING` with each resolved
  tool path and the install command for anything missing, touching nothing on disk. The GUI asks
  this before starting a run, so the SDK/7-Zip rules live in the pipeline and are not duplicated
  in C# where they could drift.
- **The GUI refuses to start a run it cannot finish, and says what to install.** A missing
  `Inf2Cat` or `signtool` - the two dependencies with no substitute - now stops before anything
  is unpacked, with a dialog naming each tool and carrying its install command, and stating that
  nothing was changed. Previously that only surfaced in the log, after the run had begun, and the
  catalog rebuild is the step that takes tens of minutes.
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
  that does not exist, the lookup would have quietly carried on with something else. Naming a CLI is
  a hard request: it now fails loudly with the path it could not find.

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
