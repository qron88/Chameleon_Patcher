// Talking to the pipeline: the -Json queries, the run's child process, argument quoting, stopping the process tree.
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
        /// <summary>
        /// Stops a process and every process it started. Process.Kill() on .NET Framework stops
        /// only the one process, which here would leave 7z, Inf2Cat or signtool running on with
        /// nothing to report to. taskkill /T walks the tree. Returns true once the process is gone.
        /// </summary>
        private static bool KillProcessTree(Process p)
        {
            if (p == null) return true;
            try
            {
                if (p.HasExited) return true;
            }
            catch
            {
                return true;
            }

            try
            {
                var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "taskkill.exe"), "/PID " + p.Id + " /T /F")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using (var killer = Process.Start(psi))
                {
                    if (killer != null) killer.WaitForExit(10000);
                }
            }
            catch
            {
            }

            try
            {
                if (!p.HasExited) p.Kill();
                return p.WaitForExit(5000);
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// Quotes one argument for the Windows command-line convention powershell.exe parses
        /// with. Backslashes are literal except directly before a quote, so a path ending in "\"
        /// - a drive root such as D:\ - must have its trailing backslashes doubled; otherwise the
        /// closing quote reads as an escaped literal quote and swallows the arguments after it.
        /// </summary>
        private static string Quote(string s)
        {
            var sb = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char c in s)
            {
                if (c == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (c == '"')
                {
                    sb.Append('\\', backslashes * 2 + 1).Append('"');
                }
                else
                {
                    sb.Append('\\', backslashes).Append(c);
                }
                backslashes = 0;
            }
            sb.Append('\\', backslashes * 2).Append('"');
            return sb.ToString();
        }

        /// <summary>
        /// Asks the pipeline to resolve its external tools (-CheckPatchTools) and returns its
        /// answer, or null if the question could not be answered. Touches nothing on disk, so this
        /// is safe to call before a run.
        /// </summary>
        private Dictionary<string, object> CheckPatchToolsQuery(string driverPath, bool isExe)
        {
            // The SDK search walks Windows Kits recursively; on a cold disk that alone can take longer
            // than the default bound, and a timed-out query silently skipped this check. The source is
            // passed along because only an .exe needs the 7z CLI: for an unpacked folder the pipeline
            // answers "7z: NOT NEEDED" instead of refusing a run that would work without it.
            return QueryPipelineJson("-CheckPatchTools", isExe ? null : driverPath, isExe, false, 120000);
        }

        /// <summary>
        /// Asks the pipeline whether the source is genuinely NVIDIA's (-CheckSource). An untrusted
        /// source gets one explicit question; answering yes is the only way the GUI passes
        /// -SkipSourceVerification. Returns null to stop, otherwise the extra arguments to pass.
        /// </summary>
        private async Task<string> ConfirmSourceAsync(string driverPath, bool isExe)
        {
            lblStep.Text = "Verifying the driver is NVIDIA's...";
            // A folder is checked file by file against NVIDIA's catalog - tens of seconds.
            Dictionary<string, object> reply = await Task.Run(() => QueryPipelineJson("-CheckSource", driverPath, isExe, false, 600000));
            if (closing || IsDisposed) return null;
            if (reply == null) return "";   // Unanswerable here: the pipeline checks again and stops on its own.
            if (JsonString(reply, "verdict") != "SOURCE_UNTRUSTED") return "";

            // Problems first - they are the reason for the question - then the notes, eight lines
            // in all so the dialog stays a dialog on a source with hundreds of foreign files.
            var detail = new StringBuilder();
            int shown = 0;
            foreach (string key in new[] { "problems", "notes" })
            {
                foreach (string line in JsonStrings(reply, key))
                {
                    if (shown >= 8) break;
                    shown++;
                    detail.AppendLine(line.Trim());
                }
            }
            var answer = MessageBox.Show(
                this,
                "This driver is not verifiably NVIDIA's:\n\n" + detail +
                "\nThe patcher re-signs everything in it with a certificate your PC trusts as a root, " +
                "so a modified or repackaged driver would be trusted too.\n\n" +
                "Use the original download from nvidia.com unless you trust this file for another reason.\n\n" +
                "Continue with this file anyway?",
                "Unverified driver source",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2);
            return answer == DialogResult.Yes ? " -SkipSourceVerification" : null;
        }

        /// <summary>
        /// Runs the pipeline in one of its ask-and-stop modes (-ShowOutputPath,
        /// -CheckLocalGpuSupport) and returns its stdout, or null if the question could not be
        /// answered. Those modes touch nothing on disk, so this is safe to call before a run.
        /// </summary>
        private string QueryPipeline(string queryArgs, string driverPath, bool isExe, bool prune, int timeoutMs = 20000)
        {
            string pipelineScript = Path.Combine(scriptsDir, "Invoke-DriverPatchPipeline.ps1");
            if (!File.Exists(pipelineScript)) return null;

            try
            {
                var args = new StringBuilder();
                args.Append("-NoProfile -ExecutionPolicy Bypass -File ").Append(Quote(pipelineScript));
                if (driverPath != null)
                {
                    args.Append(isExe ? " -SourceExePath " : " -SourcePackagePath ").Append(Quote(driverPath));
                }
                if (prune) args.Append(" -PruneForeignOemInfs");
                args.Append(' ').Append(queryArgs);

                var psi = new ProcessStartInfo
                {
                    FileName = PowerShellExe,
                    Arguments = args.ToString(),
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };

                using (var proc = Process.Start(psi))
                {
                    // Drain BOTH streams while the child runs. The pipeline's Write-Host banners
                    // land on stderr in a redirected, non-interactive context; if stderr were
                    // never read, a child that filled the stderr buffer would block on write and
                    // never exit, and the stdout read below would hang the GUI with no reason.
                    // Waiting with a timeout BEFORE consuming the streams is also what makes the
                    // 20 s bound real - reading to the end first only returns once the child has
                    // already exited, so a timeout checked afterwards can never fire.
                    var stdoutTask = proc.StandardOutput.ReadToEndAsync();
                    var stderrTask = proc.StandardError.ReadToEndAsync();
                    if (!proc.WaitForExit(timeoutMs))
                    {
                        KillProcessTree(proc);
                        return null;
                    }
                    stdoutTask.Wait();
                    stderrTask.Wait();
                    if (proc.ExitCode != 0) return null;
                    return stdoutTask.Result;
                }
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// QueryPipeline with -Json: the pipeline answers with one line of JSON, and this returns
        /// it as a dictionary, or null if the question could not be answered. The answer is the
        /// LAST stdout line that starts with "{" - anything else on stdout is noise - so a stray
        /// line cannot be mistaken for a verdict the way it could in the old text protocol, where
        /// the first line was the verdict word and indentation carried meaning.
        /// </summary>
        private Dictionary<string, object> QueryPipelineJson(string queryArgs, string driverPath, bool isExe, bool prune, int timeoutMs = 20000)
        {
            string stdout = QueryPipeline(queryArgs + " -Json", driverPath, isExe, prune, timeoutMs);
            if (stdout == null) return null;
            string[] lines = stdout.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            for (int i = lines.Length - 1; i >= 0; i--)
            {
                string candidate = lines[i].Trim();
                if (!candidate.StartsWith("{", StringComparison.Ordinal)) continue;
                try
                {
                    var parsed = new JavaScriptSerializer().DeserializeObject(candidate) as Dictionary<string, object>;
                    if (parsed != null) return parsed;
                }
                catch
                {
                    // Not JSON after all: keep looking further up.
                }
            }
            return null;
        }

        /// <summary>A string property of a pipeline answer, or "" when it is absent.</summary>
        private static string JsonString(Dictionary<string, object> reply, string key)
        {
            object value;
            if (reply == null || !reply.TryGetValue(key, out value) || value == null) return "";
            return value as string ?? Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
        }

        /// <summary>A list-of-strings property of a pipeline answer; empty when absent.</summary>
        private static List<string> JsonStrings(Dictionary<string, object> reply, string key)
        {
            var result = new List<string>();
            object value;
            if (reply == null || !reply.TryGetValue(key, out value) || value == null) return result;
            var single = value as string;
            if (single != null) { result.Add(single); return result; }
            var many = value as IEnumerable;
            if (many == null) return result;
            foreach (object item in many)
            {
                if (item != null) result.Add(Convert.ToString(item, System.Globalization.CultureInfo.InvariantCulture));
            }
            return result;
        }

        /// <summary>
        /// Asks the pipeline where it would put its output. The naming rule, including the GPU tag
        /// a pruned build gets, lives only in the pipeline; this keeps the GUI in step with it
        /// rather than maintaining a second copy that drifts.
        ///
        /// Falls back to the plain "_Patched" name if the query fails for any reason. Getting a
        /// slightly less descriptive folder is a far better failure than refusing to patch.
        /// </summary>
        private async Task<string> ResolveOutputPathAsync(string driverPath, bool isExe, bool prune)
        {
            string fallback = isExe
                ? Path.Combine(Path.GetDirectoryName(driverPath), Path.GetFileNameWithoutExtension(driverPath) + "_Patched")
                : driverPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + "_Patched";

            // Off the UI thread: the query starts powershell.exe and reads WMI, which can take
            // several seconds, and the window would show "Not responding" for all of it.
            Dictionary<string, object> reply = await Task.Run(() => QueryPipelineJson("-ShowOutputPath", driverPath, isExe, prune));
            string answered = JsonString(reply, "outputPath").Trim();
            try
            {
                if (answered.Length > 0 && Path.IsPathRooted(answered)) return answered;
            }
            catch (ArgumentException)
            {
                // Illegal characters in the answer: fall back.
            }
            return fallback;
        }

        /// <summary>
        /// True when <paramref name="outputPath"/> is a folder the pipeline could have created for
        /// this source: a leaf ending in "_Patched" or containing "_Patched_", not the source
        /// itself, and either in the source's own parent folder or - for the Downloads output of
        /// an NVIDIA App source - recognisably a driver package.
        /// </summary>
        private static bool IsPlausibleOutputFolder(string outputPath, string driverPath)
        {
            try
            {
                string outFull = Path.GetFullPath(outputPath).TrimEnd('\\');
                string srcFull = Path.GetFullPath(driverPath).TrimEnd('\\');
                if (string.Equals(outFull, srcFull, StringComparison.OrdinalIgnoreCase)) return false;
                string outParent = Path.GetDirectoryName(outFull);
                string srcParent = Path.GetDirectoryName(srcFull);
                if (outParent == null) return false;   // a drive root is never an output folder
                string leaf = Path.GetFileName(outFull);
                bool named = leaf.EndsWith("_Patched", StringComparison.OrdinalIgnoreCase) ||
                             leaf.IndexOf("_Patched_", StringComparison.OrdinalIgnoreCase) >= 0;
                if (!named) return false;
                if (string.Equals(outParent, srcParent, StringComparison.OrdinalIgnoreCase)) return true;

                // Not beside the source: the one case the pipeline does that is a package NVIDIA
                // App staged, whose output goes to the user's Downloads. A name alone is not
                // enough to allow a recursive delete somewhere else, so the folder also has to
                // look like what the pipeline writes - a driver package - and must not contain
                // the source.
                if (srcFull.StartsWith(outFull + "\\", StringComparison.OrdinalIgnoreCase)) return false;
                return Directory.Exists(Path.Combine(outFull, "Display.Driver")) &&
                       File.Exists(Path.Combine(outFull, "setup.cfg"));
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// "Build for this PC only" strips out every display INF that cannot match this machine.
        /// If none of this machine's GPUs is one whitelist.json unlocks, that build has nothing
        /// left to unlock: it would spend the whole run re-signing a driver the GPU here already
        /// runs. The pipeline refuses such a run in its preflight; this asks the same question
        /// first, so the answer arrives as a choice rather than as a failed run.
        ///
        /// A universal build is never questioned. Building one on a machine whose GPU needs no
        /// unlock is the ordinary case - the package is for the machine that does.
        ///
        /// Returns false only if the user wants to stop. "Yes" switches the checkbox off and
        /// carries on, so the header, the arguments and the output folder all follow the choice
        /// that was actually made.
        /// </summary>
        private async Task<bool> ConfirmPrunedBuildIsWorthItAsync()
        {
            if (!chkPruneInfs.Checked) return true;

            Dictionary<string, object> reply = await Task.Run(() => QueryPipelineJson("-CheckLocalGpuSupport", null, false, false));
            if (closing || IsDisposed) return false;
            if (reply == null) return true;   // Unanswerable: leave the decision to the pipeline.
            if (JsonString(reply, "verdict") != "UNSUPPORTED") return true;   // SUPPORTED, or nothing detectable to judge.

            var detail = new StringBuilder();
            foreach (string line in JsonStrings(reply, "detail")) detail.AppendLine(line.TrimEnd());

            var answer = MessageBox.Show(
                this,
                "No GPU in this PC is one this patcher unlocks:\n\n" +
                detail.ToString() +
                "\n\"Build for this PC only\" cuts the package down to what can match THIS machine, " +
                "so it would produce NVIDIA's own driver for a GPU that already works, re-signed " +
                "with a certificate Windows does not trust yet - a long run for no unlock.\n\n" +
                "Build the portable package instead? It keeps every whitelist entry and installs " +
                "on the machine that has the locked GPU.\n\n" +
                "Yes - build the portable package (recommended)\n" +
                "No - stop, change nothing\n\n" +
                "(To force the for-this-PC-only build anyway, run Invoke-DriverPatchPipeline.ps1 " +
                "with -AllowUnsupportedGpu.)",
                "Nothing to unlock on this PC",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);

            if (answer != DialogResult.Yes) return false;

            chkPruneInfs.Checked = false;
            return true;
        }

        /// <summary>
        /// Recognises the pipeline's "the .pfx password is required, but none was supplied and
        /// prompting is disabled" error, which both Invoke-DriverPatchPipeline.ps1 and
        /// Sign-DriverPackage.ps1 raise when the signing key is not on this PC. Keep the phrase in
        /// step with those two messages.
        /// </summary>
        private void NotePfxPasswordRequired(string line)
        {
            if (line.IndexOf("none was supplied and prompting is disabled", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                pfxPasswordWasRequired = true;
            }
        }

        private Task<int> RunPipelineAsync(string arguments, string password)
        {
            var tcs = new TaskCompletionSource<int>();

            var psi = new ProcessStartInfo
            {
                FileName = PowerShellExe,
                Arguments = arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            // An environment variable on the child process, NOT stdin: Read-Host -AsSecureString
            // does not reliably read from a redirected stdin pipe when there's no real attached
            // console (confirmed: it just hangs). The pipeline reads this variable before
            // prompting, so a password reaches it without ever appearing on a command line or in
            // a log line. Only set when the user actually supplied one - the normal store-signing
            // path needs no password, and an empty variable would be pointless noise.
            if (!string.IsNullOrEmpty(password))
            {
                psi.EnvironmentVariables["DRIVER_PATCH_PFX_PASSWORD"] = password;
            }

            var process = new Process { StartInfo = psi, EnableRaisingEvents = true };

            process.OutputDataReceived += (s, e) =>
            {
                if (e.Data == null) return;
                NotePfxPasswordRequired(e.Data);
                // Write to the file from THIS thread, before marshalling to the UI. If the UI
                // thread is busy or wedged, or the app is killed mid-run, the log still has
                // everything the child emitted up to that moment - which is the whole point of
                // having a log rather than just the details panel.
                LogLine("     ", e.Data);
                PostToUi(() =>
                {
                    AppendLog(e.Data);
                    var m = StepRegex.Match(e.Data);
                    if (m.Success)
                    {
                        int current = int.Parse(m.Groups[1].Value);
                        int total = int.Parse(m.Groups[2].Value);
                        progressBar.Value = Math.Min(100, (int)(100.0 * current / total));
                        lblStep.Text = "Step " + current + "/" + total + ": " + m.Groups[3].Value;
                    }
                });
            };
            process.ErrorDataReceived += (s, e) =>
            {
                if (e.Data == null) return;
                NotePfxPasswordRequired(e.Data);
                LogLine("[err]", e.Data);
                PostToUi(() => AppendLog("[stderr] " + e.Data));
            };
            process.Exited += (s, e) =>
            {
                // Exited can fire while the last lines of the redirected streams are still queued -
                // and those are usually the error message, plus the phrase that sets
                // pfxPasswordWasRequired. The parameterless WaitForExit returns only once both
                // asynchronous readers have reached end of stream.
                try { process.WaitForExit(); } catch { }
                int code = -1;
                try { code = process.ExitCode; } catch { }
                LogLine("[exit]", "child process exited with code " + code);
                tcs.TrySetResult(code);
            };

            try
            {
                process.Start();
            }
            catch (Exception ex)
            {
                // powershell.exe missing or blocked. Previously this threw out of an async void
                // handler and took the app down with no explanation; now it lands in the log and
                // is reported as an ordinary failure.
                LogLine("[err]", "could not start powershell.exe: " + ex.Message);
                PostToUi(() => AppendLog("[stderr] Could not start powershell.exe: " + ex.Message));
                tcs.TrySetResult(-1);
                return tcs.Task;
            }

            pipelineProcess = process;
            LogLine("[proc]", "powershell.exe started, pid " + process.Id);
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            return tcs.Task;
        }
    }
}
