// One patch run from the Start button to the result dialog.
// Part of MainForm; see Chameleon-Patcher.cs for the class overview.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ChameleonPatcherGui
{
    public partial class MainForm
    {
        private static readonly Regex StepRegex = new Regex(@"^===\s*(\d+)/(\d+):\s*(.+?)\s*===\s*$", RegexOptions.Compiled);

        private async void BtnStart_Click(object sender, EventArgs e)
        {
            // Inputs stay locked while the pre-run checks run in the background, so a second click
            // or an edited path cannot slip in between a check and the run it was made for.
            SetInputsEnabled(false);
            lblStep.Text = PreparingText;
            try
            {
                await StartPatchingAsync();
            }
            finally
            {
                if (!closing && !IsDisposed && !running)
                {
                    SetInputsEnabled(true);
                    if (lblStep.Text == PreparingText) lblStep.Text = "Ready.";
                }
            }
        }

        private async Task StartPatchingAsync()
        {
            if (scriptsError != null)
            {
                MessageBox.Show(this,
                    "The patcher's scripts could not be unpacked when this window opened:\n" + scriptsError +
                    "\n\nNothing is run from a folder that may hold a mix of old and new scripts. " +
                    "Close Chameleon Patcher and start it again.",
                    "Scripts not ready", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            string driverPath = txtDriverPath.Text.Trim();
            // The .pfx fields count only while their checkbox is ticked. Whatever is left in them
            // otherwise is ignored, so an untick really does mean "sign from the store".
            bool usePfx = chkUsePfx.Checked;
            string certPath = usePfx ? txtCertPath.Text.Trim() : "";
            string password = usePfx ? txtPassword.Text : "";

            if (string.IsNullOrEmpty(driverPath) || !(File.Exists(driverPath) || Directory.Exists(driverPath)))
            {
                MessageBox.Show(this, "Select a valid driver .exe or unpacked folder first.", "Missing input", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            // A typed folder path may end in a separator. Drop it (except on a drive root, where
            // it is part of the path) so the derived "<folder>_Patched" name comes out right.
            if (Directory.Exists(driverPath))
            {
                string root = Path.GetPathRoot(driverPath);
                if (!string.Equals(driverPath, root, StringComparison.OrdinalIgnoreCase))
                {
                    driverPath = driverPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                }
            }
            bool isExe = File.Exists(driverPath) && driverPath.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);
            if (!isExe && !Directory.Exists(driverPath))
            {
                MessageBox.Show(this, "The driver path must be either a .exe file or a folder.", "Invalid input", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            // Ticked but incomplete: stop before anything runs, and offer the two ways out - fill
            // the fields in, or untick and sign the normal way. Without this an empty password
            // only surfaces once the pipeline fails on it.
            if (usePfx && (certPath.Length == 0 || password.Length == 0))
            {
                string missing =
                    certPath.Length == 0 && password.Length == 0 ? "No .pfx file is selected and no password is entered." :
                    certPath.Length == 0 ? "No .pfx file is selected." :
                    "No password is entered for the .pfx file.";
                var choice = MessageBox.Show(
                    this,
                    missing + "\n\n" +
                    "\"Sign with an existing certificate from a .pfx file\" is ticked, so the .pfx file " +
                    "and its password are both needed.\n\n" +
                    "Yes - untick it and sign with the key on this PC (or have a new certificate created)\n" +
                    "No - go back and fill them in",
                    "Certificate details missing",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning);
                if (choice != DialogResult.Yes) return;

                chkUsePfx.Checked = false;   // also clears the password and hides the fields
                usePfx = false;
                certPath = "";
                password = "";
            }
            if (!string.IsNullOrEmpty(certPath) && !File.Exists(certPath))
            {
                MessageBox.Show(this, "The selected certificate file doesn't exist.", "Invalid input", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            // No password check here on purpose. The normal case needs no password at all: the
            // pipeline signs with the private key already in Cert:\CurrentUser\My. It is passed
            // -NonInteractive below, so if a password genuinely IS required (a .pfx whose key
            // isn't in this machine's store, or a first-ever cert that needs a .pfx backup) it
            // fails with an explanatory message instead of blocking on a prompt this GUI cannot
            // answer.

            // Is this NVIDIA's own driver? Asked first: nothing else is worth spending on a source the
            // user decides not to trust, and the answer may add -SkipSourceVerification.
            string sourceArgs = await ConfirmSourceAsync(driverPath, isExe);
            if (sourceArgs == null) return;

            // Ask about a for-this-PC-only build BEFORE the output path is resolved: answering
            // "build the portable one" unticks the checkbox, and that changes the folder name.
            if (!await ConfirmPrunedBuildIsWorthItAsync()) return;

            // A pruned build lands in "<source>_Patched_<GPU>" rather than "<source>_Patched", so
            // the folder itself says which machine it was cut for. Ask the pipeline for the name
            // instead of reproducing the rule here: it owns the GPU detection, and two copies of
            // that logic would eventually disagree.
            string outputPath = await ResolveOutputPathAsync(driverPath, isExe, chkPruneInfs.Checked);
            if (closing || IsDisposed) return;

            if (Directory.Exists(outputPath))
            {
                // The path came back from a child process's stdout. Before it can drive a recursive
                // delete it has to look like what the pipeline names its output: a "*_Patched" or
                // "*_Patched_<GPU>" folder beside the source, never the source itself.
                if (!IsPlausibleOutputFolder(outputPath, driverPath))
                {
                    MessageBox.Show(this,
                        "The output folder the pipeline reported does not look like a patch output folder:\n" + outputPath +
                        "\n\nNothing was deleted. Remove or rename it yourself if it is safe to do so.",
                        "Unexpected output folder", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }
                if (!chkOverwrite.Checked)
                {
                    MessageBox.Show(
                        this,
                        "Output folder already exists:\n" + outputPath +
                        "\n\nCheck \"Delete the output folder first\" to replace it, or remove it manually first.",
                        "Output already exists",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                    return;
                }
                var confirm = MessageBox.Show(
                    this,
                    "This will permanently delete:\n" + outputPath + "\n\nContinue?",
                    "Confirm delete",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning);
                if (confirm != DialogResult.Yes) return;
                try
                {
                    Directory.Delete(outputPath, true);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "Couldn't delete the existing output folder:\n" + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }
            }

            string pipelineScript = Path.Combine(scriptsDir, "Invoke-DriverPatchPipeline.ps1");
            if (!File.Exists(pipelineScript))
            {
                MessageBox.Show(this, "Could not find Invoke-DriverPatchPipeline.ps1 in the Scripts folder next to this program:\n" + pipelineScript, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // Ask the pipeline which tools this machine can resolve, before anything is unpacked.
            // All three are hard requirements, each for its own reason: Inf2Cat is the only thing
            // that rebuilds nv_disp.cat after the INFs are edited, signtool signs what it rebuilds,
            // and a 7z-compatible CLI is what unpacks the driver download this run starts from (an
            // already-unpacked folder never calls it, and is reported as such by the pipeline).
            // NVIDIA's own launcher is not a fallback any more - it self-elevates, asks for the
            // folder to extract into, and unpacks into a system-temp folder a non-elevated run may
            // not be allowed to list - so a missing 7-Zip is as dead a run as a missing SDK, and
            // the catalog rebuild is the step that takes tens of minutes, so finding either out
            // afterwards is expensive. The pipeline owns the rules; this only asks and reports.
            Dictionary<string, object> toolReport = await Task.Run(() => CheckPatchToolsQuery(driverPath, isExe));
            if (closing || IsDisposed) return;
            if (JsonString(toolReport, "verdict") == "TOOLS_MISSING")
            {
                // Split the report into what was missing, what was found, and the guidance the
                // pipeline wrote. Status lines are shown without their paths - a 70-character path is
                // what used to wrap through the middle of a sentence and bury the line the user has to
                // act on. Everything else is re-flowed: prose is collected and wrapped as a paragraph
                // filling the whole width, rather than copied line by line, which is what left the
                // text ragged and each continuation hanging deeper than the line it started on. Only a
                // line the pipeline indented by four - a winget command, a download address - keeps
                // its own line, because that is something to type or to open.
                string missingNames = "";
                string foundNames = "";
                var prose = new StringBuilder();
                var guidance = new StringBuilder();
                var links = new StringBuilder();
                // Which tool is missing and which was found are fields of the answer now, not
                // lines to recognise by their prefix. Only the guidance is still text: it is the
                // same help a console run prints, one string per line, indentation included.
                object needed;
                bool sevenZipNeeded = !(toolReport.TryGetValue("sevenZipNeeded", out needed) && needed is bool && !(bool)needed);
                foreach (string[] tool in new[] {
                    new[] { "Inf2Cat", "inf2cat" }, new[] { "signtool", "signtool" }, new[] { "7z", "sevenZip" } })
                {
                    if (tool[0] == "7z" && !sevenZipNeeded) continue;
                    if (JsonString(toolReport, tool[1]).Length == 0) missingNames = AppendName(missingNames, HumanToolName(tool[0]));
                    else foundNames = AppendName(foundNames, ShortToolName(tool[0]));
                }
                var helpLines = new List<string>();
                foreach (string helpLine in JsonStrings(toolReport, "help"))
                {
                    helpLines.AddRange(helpLine.Replace("\r\n", "\n").Split('\n'));
                }
                foreach (string raw in helpLines)
                {
                    string trimmed = raw.Trim();
                    if (trimmed.Length == 0)
                    {
                        FlushProse(prose, guidance);
                        guidance.AppendLine();
                        continue;
                    }
                    int indent = raw.Length - raw.TrimStart(' ').Length;
                    if (indent >= 4)
                    {
                        // A line the pipeline indents by four is something to act on. An address belongs
                        // in this window - shown, and offered by the button that opens it. A terminal
                        // command does not: it is printed by the very same guidance in a console, and a
                        // window whose button opens the page should not ask anyone to type anything. One
                        // address can show up in two guidance blocks; it is offered once.
                        FlushProse(prose, guidance);
                        if (trimmed.StartsWith("http", StringComparison.OrdinalIgnoreCase))
                        {
                            guidance.AppendLine(raw.TrimEnd());
                            if (links.ToString().IndexOf(trimmed, StringComparison.Ordinal) < 0) links.AppendLine(trimmed);
                        }
                        continue;
                    }
                    if (prose.Length > 0) prose.Append(' ');
                    prose.Append(trimmed);
                }
                FlushProse(prose, guidance);
                string guidanceText = Regex.Replace(guidance.ToString(), "(\r?\n){3,}", "\n\n");

                var sb = new StringBuilder();
                sb.AppendLine(missingNames.IndexOf(',') < 0
                    ? "One tool the patcher needs here is missing:"
                    : "Several tools the patcher needs here are missing:");
                sb.AppendLine();
                if (missingNames.IndexOf(',') < 0)
                {
                    sb.AppendLine(IndentLines(WrapText(missingNames, DialogTextWidth - 2), 2));
                }
                else
                {
                    foreach (string name in missingNames.Split(','))
                    {
                        sb.AppendLine(IndentLines(WrapText(name.Trim(), DialogTextWidth - 2), 2));
                    }
                }
                sb.AppendLine();
                sb.AppendLine(guidanceText.Trim());
                if (foundNames.Length > 0)
                {
                    sb.AppendLine();
                    sb.AppendLine(WrapText("Found already: " + foundNames +
                        ". Full paths are printed by the pipeline's query:", DialogTextWidth));
                    sb.AppendLine();
                    sb.AppendLine("  Invoke-DriverPatchPipeline.ps1 -CheckPatchTools");
                }
                sb.AppendLine();
                sb.AppendLine(WrapText("Nothing has been unpacked and nothing was changed. Install " +
                    "what is named above - the button below opens its download page in your browser - " +
                    "then start the run again.", DialogTextWidth));
                ShowMissingToolsDialog(sb.ToString().Trim(), links.ToString().Trim());
                lblStatus.ForeColor = System.Drawing.Color.DarkRed;
                lblStatus.Text = "Required tools missing - see the message.";
                return;
            }
            // A machine with no 7z-compatible CLI never reaches here: it answered TOOLS_MISSING
            // above and the run stopped before unpacking. What is left to say is which CLI the run
            // will unpack with.
            if (isExe)
            {
                string sevenZipPath = JsonString(toolReport, "sevenZip");
                if (sevenZipPath.Length > 0) lblStatus.Text = "Unpacking with: " + sevenZipPath;
            }

            var argsBuilder = new StringBuilder();
            argsBuilder.Append("-NoProfile -ExecutionPolicy Bypass -File ").Append(Quote(pipelineScript));
            argsBuilder.Append(isExe ? " -SourceExePath " : " -SourcePackagePath ").Append(Quote(driverPath));
            argsBuilder.Append(" -OutputPath ").Append(Quote(outputPath));
            if (!string.IsNullOrEmpty(certPath))
            {
                argsBuilder.Append(" -PfxPath ").Append(Quote(certPath));
            }
            if (!chkAddInstallerOption.Checked)
            {
                argsBuilder.Append(" -SkipSetupCertOption");
            }
            // Opt-in, because it makes the output specific to this machine. The payoff is large:
            // dropping the OEM display INFs that cannot match this PC took a 616.86 run from about
            // 57 minutes to 7.6, almost all of it in the catalog rebuild.
            if (chkPruneInfs.Checked)
            {
                argsBuilder.Append(" -PruneForeignOemInfs");
            }
            // Never prompt in the child. There is no console attached to it, so a Read-Host
            // prompt would hang forever with the GUI showing no reason why; -NonInteractive
            // turns any such case into a clear error we surface in the log instead.
            argsBuilder.Append(" -NonInteractive");
            argsBuilder.Append(sourceArgs);
            // -PfxPassword is deliberately never passed on the command line, where any process
            // listing or event log could read it. When a password is actually needed it travels
            // in an environment variable set only on the child process (see RunPipelineAsync).
            // In the normal, store-signing case there is no password involved at all and nothing
            // is set.

            SetRunning(true);
            txtLog.Clear();
            progressBar.Value = 0;
            lblStep.Text = "Starting...";
            lblStatus.Text = "";
            lblStatus.ForeColor = System.Drawing.Color.DarkRed;

            pfxPasswordWasRequired = false;
            StartLog(driverPath, outputPath, certPath, argsBuilder.ToString(), !string.IsNullOrEmpty(password));
            if (logPath != null)
            {
                AppendLog("Logging this run to: " + logPath);
                AppendLog(new string('-', 78));
                btnOpenLog.Enabled = true;
            }

            int exitCode = await RunPipelineAsync(argsBuilder.ToString(), password);
            pipelineProcess = null;

            // The window was closed mid-run: FormClosing has already stopped the child and
            // finished the log, and the controls below no longer exist.
            if (closing || IsDisposed) return;

            SetRunning(false);
            FinishLog(exitCode, exitCode == 0 ? "success" : "FAILED");
            // The password has already travelled to the child (environment variable) and is
            // recorded as supplied-or-not in the log header; don't leave it sitting in the box
            // afterwards. Retyping it for a retry is the price of not keeping a signing
            // password on screen.
            txtPassword.Clear();

            if (exitCode == 0)
            {
                progressBar.Value = 100;
                lblStep.Text = "Done.";
                lblStatus.ForeColor = System.Drawing.Color.DarkGreen;
                lblStatus.Text = "Patching completed successfully.";

                var launch = MessageBox.Show(
                    this,
                    "Patching completed successfully.\n\nDo you want to launch the driver installer (setup.exe) now?",
                    "Patching complete",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question);
                if (launch == DialogResult.Yes)
                {
                    string setupExe = Path.Combine(outputPath, "setup.exe");
                    if (File.Exists(setupExe))
                    {
                        try
                        {
                            Process.Start(new ProcessStartInfo(setupExe) { UseShellExecute = true, WorkingDirectory = outputPath });
                        }
                        catch (Exception ex)
                        {
                            MessageBox.Show(this, "Couldn't launch setup.exe:\n" + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    }
                    else
                    {
                        MessageBox.Show(this, "setup.exe not found at:\n" + setupExe, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
            else
            {
                // Read the step label BEFORE overwriting it, so the dialog can name the step that
                // actually failed rather than the word "Failed".
                string failedAt = lblStep.Text;
                lblStep.Text = "Failed.";
                lblStatus.Text = "Patching failed (exit code " + exitCode + ") - see details below.";
                if (!detailsPanel.Visible) ToggleDetails();

                // The one failure a user can fix right here: the signing key is not on this PC,
                // so the .pfx password is needed. Open the hidden .pfx fields, fill in the .pfx
                // the pipeline would have used if it is the project's default one, and say so.
                string pfxHint = "";
                if (pfxPasswordWasRequired)
                {
                    if (!chkUsePfx.Checked) chkUsePfx.Checked = true;
                    if (txtCertPath.Text.Trim().Length == 0)
                    {
                        // The certificate script names its .pfx after the certificate's thumbprint
                        // (DriverPatchSigning_<thumbprint>.pfx) so that two runs cannot overwrite each
                        // other's private key, which means the old fixed name is only one candidate
                        // among several now. Offer the newest file matching the pattern; the old
                        // name still matches it.
                        string certDir = Path.Combine(DataDir, "Certificates");
                        string defaultPfx = null;
                        if (Directory.Exists(certDir))
                        {
                            string[] candidates = Directory.GetFiles(certDir, "DriverPatchSigning*.pfx");
                            if (candidates.Length > 0)
                            {
                                Array.Sort(candidates, (a, b) =>
                                    File.GetLastWriteTimeUtc(a).CompareTo(File.GetLastWriteTimeUtc(b)));
                                defaultPfx = candidates[candidates.Length - 1];
                            }
                        }
                        if (defaultPfx != null && File.Exists(defaultPfx)) txtCertPath.Text = defaultPfx;
                    }
                    pfxHint = "The signing key is not on this PC, so the .pfx password is needed. " +
                              "The .pfx fields are now shown above - enter the password and start again.\n\n";
                }

                if (logPath != null)
                {
                    var open = MessageBox.Show(
                        this,
                        "Patching failed at: " + failedAt + "\n\n" +
                        pfxHint +
                        "The full log of this run was saved to:\n" + logPath + "\n\n" +
                        "Open it now?",
                        "Patching failed",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Error);
                    if (open == DialogResult.Yes) OpenLogFile();
                }
                else
                {
                    MessageBox.Show(this, pfxHint + "Patching failed. See the details panel for the full log.", "Patching failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }
    }
}
