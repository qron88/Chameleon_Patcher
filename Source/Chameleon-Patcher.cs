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

// Version metadata. csc.exe folds these into the PE's Win32 version resource, so the number shows
// up in Explorer's Details tab and in Get-Item ....VersionInfo without a separate .rc file. That
// matters more than usual here: a patched driver package carries no trace of which build of this
// tool produced it, so a bug report is only actionable if the log says. ReportVersion below puts
// the same number in every log header, and it reads it back out of the assembly rather than
// repeating the literal, so the two can never drift apart.
//
// AssemblyVersion is the binding identity and stays at x.y.0.0 across patch releases; the file
// and informational versions carry the precise one. Keep all three in step on a release.
[assembly: AssemblyTitle("Chameleon Patcher")]
[assembly: AssemblyProduct("Project Chameleon")]
[assembly: AssemblyDescription("NVIDIA driver GPU-unlock patcher")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.1.0")]
[assembly: AssemblyInformationalVersion("1.2.1")]

namespace ChameleonPatcherGui
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            // Last-resort handlers. Without these, an exception that escapes an `async void`
            // handler (BtnStart_Click is one) is rethrown on the Windows message loop and takes
            // the whole app down as a raw Win32 crash - no message, and the run's log stops
            // without recording why. The log is the primary diagnostic artifact for this tool, so
            // a crash that leaves it silent is the worst failure mode available. Both handlers
            // write to the log when a run is in progress and show one readable dialog.
            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
                MainForm.ReportCrash("unhandled exception", e.ExceptionObject as Exception);
            Application.ThreadException += (s, e) =>
                MainForm.ReportCrash("UI thread exception", e.Exception);
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);

            Application.Run(new MainForm());
        }
    }

    // One class, several files: this one holds the entry point, the fields, start-up and the
    // embedded-script unpacking; MainForm.Ui.cs, MainForm.Dialogs.cs, MainForm.Pipeline.cs,
    // MainForm.Log.cs and MainForm.Run.cs hold the rest. Source\Build.ps1 compiles every .cs here.
    public partial class MainForm : Form
    {
        // Height of the live log panel shown by "Show details". Every vertical position, and the
        // window height, is computed by LayoutForm from the controls actually visible.
        private const int DetailsPanelHeight = 218;

        private TextBox txtDriverPath;
        private CheckBox chkUsePfx;
        private GroupBox grpCert;
        private TextBox txtCertPath;
        private TextBox txtPassword;
        private CheckBox chkAddInstallerOption;
        private CheckBox chkOverwrite;
        private CheckBox chkPruneInfs;
        private Button btnStart;
        private Button btnToggleDetails;
        private ProgressBar progressBar;
        private Label lblStep;
        private Label lblStatus;
        private TextBox txtLog;
        private Panel detailsPanel;
        private Button btnOpenLog;

        private readonly string scriptsDir;
        private bool running;

        // The pipeline's powershell.exe while a run is in progress. Held so that closing the
        // window can actually stop it: the child runs with no window of its own, so a child left
        // behind keeps unpacking, patching and signing invisibly.
        private Process pipelineProcess;

        // Set once the window is going down mid-run, so late callbacks from the child's output
        // streams and the run's own continuation stop touching a form that no longer exists.
        private bool closing;

        // The live form, so the static crash handlers in Program can reach the log writer. Set in
        // the MainForm constructor and cleared when the window is gone; a crash before the form
        // exists, or after it is disposed, falls back to a dialog with no log write.
        internal static MainForm Live;

        private const string PreparingText = "Checking...";

        // Full path, never a bare "powershell.exe": with UseShellExecute=false, CreateProcess looks in
        // this application's own folder first, so a powershell.exe dropped next to the patcher would
        // run instead of Windows' own. This process is x64, so SystemDirectory is the real System32.
        private static readonly string PowerShellExe =
            Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");

        /// <summary>
        /// Records a crash that escaped a handler and shows one readable dialog. Called by the
        /// AppDomain and UI-thread handlers in Program. Writes to the run log when a run is in
        /// progress, so a crash mid-patch leaves a trace instead of a silent log.
        /// </summary>
        internal static void ReportCrash(string context, Exception ex)
        {
            string text = ex == null ? "(no exception object)" : ex.ToString();
            MainForm form = Live;
            try
            {
                if (form != null && !form.IsDisposed && form.runLogOpen)
                {
                    form.LogLine("[crash]", context + ": " + text);
                }
            }
            catch
            {
                // A log write failing must not replace the crash report with a second crash.
            }
            try
            {
                MessageBox.Show(
                    "Chameleon Patcher hit an unexpected error (" + context + ").\n\n" + text +
                    (form != null && form.runLogOpen ? "\n\nThe run log was updated with this." : ""),
                    "Unexpected error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            catch
            {
            }
        }

        // Set from the child's output callbacks (threadpool threads) when the pipeline stops
        // because the signing key is not on this PC and a .pfx password is needed. The failure
        // dialog then points at the hidden .pfx fields instead of leaving the user to find them.
        private volatile bool pfxPasswordWasRequired;

        // Logging state. The writer is touched from the two redirected-stream callbacks, which run
        // on separate threadpool threads, so every write goes through logLock.
        private string logPath;
        private StreamWriter logWriter;
        private readonly object logLock = new object();
        private Stopwatch runClock;

        // True while a run log is open, so the crash handlers know a log write is meaningful.
        internal bool runLogOpen;

        public MainForm()
        {
            // The pipeline scripts are embedded in this exe (see Build.ps1) and unpacked to
            // DataDir\Scripts. The scripts keep Certificates in the folder next to Scripts, so
            // DataDir\Certificates is where signing keys live - it persists across versions.
#if STANDALONE
            scriptsDir = Path.Combine(DataDir, "Scripts");
            try { ExtractEmbeddedScripts(scriptsDir); }
            catch (Exception ex)
            {
                // Remembered, not just shown: whatever is in Scripts\ now is a mix of this build's
                // files and an older build's (or nothing), and running that mix is how a new GUI
                // ends up talking to an old pipeline. Start refuses until a clean start succeeds.
                scriptsError = ex.Message;
                MessageBox.Show("Could not unpack the embedded scripts to " + scriptsDir + ":\n" + ex.Message +
                    "\n\nPatching is disabled until this is fixed - close any program holding files in that folder and start Chameleon Patcher again.",
                    "Chameleon Patcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
#else
            // Overlay build: this exe lives at the project root; the pipeline scripts live in .\Scripts.
            scriptsDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Scripts");
#endif
            Live = this;
            BuildUi();

            // Once the window has painted, ask the pipeline whether NVIDIA App has already staged
            // a driver download (newest, verified against the pipeline's own package-root rule)
            // and offer it as this run's source. It is an offer, not a decision: accepting only
            // fills the source box; the known run flow (source verification, tool check, output
            // naming) still happens when the user presses Start. Declining leaves the window
            // exactly as it was before.
            Shown += delegate { OfferStagedNvAppDriverAsync(); };
        }

        // Why the embedded scripts could not be unpacked at start (standalone build), or null.
        // While set, nothing is run from Scripts\: see the constructor.
        private string scriptsError = null;

        // The startup offer appears once per window, not on every event pass.
        private bool nvAppOfferShown;

        /// <summary>
        /// Asks the pipeline about a driver NVIDIA App has already downloaded (-CheckNvAppStaged)
        /// and, if there is one and no source has been typed yet, offers it. Verdict word on the
        /// first stdout line, like the GUI's other pipeline queries; a query that cannot be
        /// answered is treated as "nothing staged" - the user can still pick the source by hand.
        /// </summary>
        private async void OfferStagedNvAppDriverAsync()
        {
            if (nvAppOfferShown) return;
            nvAppOfferShown = true;
            if (txtDriverPath.Text.Trim().Length > 0) return;   // never overwrite what the user typed

            if (scriptsError != null) return;
            Dictionary<string, object> reply = await Task.Run(() => QueryPipelineJson("-CheckNvAppStaged", null, false, false, 30000));
            if (closing || IsDisposed || reply == null) return;
            if (JsonString(reply, "verdict") != "NVAPP_STAGED") return;

            string path = JsonString(reply, "path");
            string version = JsonString(reply, "version");
            string staged = JsonString(reply, "staged");
            if (path.Length == 0 || !Directory.Exists(path)) return;

            // The message box wraps wherever its own width runs out, and it treats the spaces
            // inside "NVIDIA Corporation\NVIDIA App" as places to wrap: the first version of this
            // text came out with its opening sentence broken two words before the end and the
            // folder cut in the middle of a folder name. So the facts get one short line each
            // and the folder is broken here, only after a backslash. The prose is left to the
            // box, which fills its own width evenly; prose pre-wrapped here came out ragged.
            var text = new StringBuilder();
            text.Append("NVIDIA App has already downloaded a driver.\n\n");
            if (version.Length > 0) text.Append("Version:  ").Append(version).Append('\n');
            if (staged.Length > 0) text.Append("Staged:   ").Append(staged).Append('\n');
            text.Append("Folder:\n").Append(BreakPath(path, OfferTextWidth)).Append("\n\n");
            text.Append("Use it as the driver source for this run?\n\n");
            text.Append(
                "The patcher works on a copy and never touches NVIDIA App's own files. The driver " +
                "files and installer programs in the copy are checked against NVIDIA's signatures, " +
                "then it is patched and re-signed. The result goes to your Downloads folder.\n\n");
            text.Append("Choose No to pick a driver .exe or folder yourself.");
            var answer = MessageBox.Show(
                this,
                text.ToString(),
                "Driver already downloaded",
                MessageBoxButtons.YesNo, MessageBoxIcon.Question,
                MessageBoxDefaultButton.Button1);
            if (answer != DialogResult.Yes || closing || IsDisposed) return;

            txtDriverPath.Text = path;
            lblStatus.ForeColor = System.Drawing.Color.DarkRed;
            lblStatus.Text = "Source set from NVIDIA App's download - press Start to patch.";
        }

        // Characters per folder line in the startup offer. A message box fits about 57 of the
        // system font's average characters before it wraps on its own; a path is mostly wide
        // characters, so the limit stays under that.
        private const int OfferTextWidth = 50;

        /// <summary>
        /// A path on as few lines as fit <paramref name="width"/>, broken only AFTER a backslash,
        /// never at a space and never inside a folder name. A single component longer than the
        /// width (a 32-character hash folder is not, a long file name can be) keeps its own line.
        /// </summary>
        internal static string BreakPath(string path, int width)
        {
            var result = new StringBuilder();
            var line = new StringBuilder();
            int start = 0;
            while (start < path.Length)
            {
                int cut = path.IndexOf('\\', start);
                string piece = cut < 0 ? path.Substring(start) : path.Substring(start, cut - start + 1);
                if (line.Length > 0 && line.Length + piece.Length > width)
                {
                    result.Append(line).Append('\n');
                    line.Length = 0;
                }
                line.Append(piece);
                start += piece.Length;
            }
            result.Append(line);
            return result.ToString();
        }

        // Per-user, writable, survives upgrades of the exe. Scripts\ below it is rewritten from the
        // embedded copy; Certificates\ is created by the scripts and never touched here.
#if STANDALONE
        internal static readonly string DataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ChameleonPatcher");
#else
        // Overlay build: Scripts\ and Certificates\ sit next to the exe.
        internal static readonly string DataDir = AppDomain.CurrentDomain.BaseDirectory;
#endif

#if STANDALONE
        /// <summary>
        /// Writes every embedded "Scripts/..." resource under <paramref name="target"/>, byte for
        /// byte. Runs on every start and rewrites only files that are missing or differ, so edited
        /// or damaged copies are repaired and an unchanged install costs a few file reads. A named
        /// mutex keeps two instances from writing the same files at once.
        /// </summary>
        private static void ExtractEmbeddedScripts(string target)
        {
            const string prefix = "Scripts/";
            Assembly asm = Assembly.GetExecutingAssembly();
            bool owned = false;
            using (var mutex = new Mutex(false, @"Local\ChameleonPatcherScriptExtract"))
            {
                try
                {
                    try { owned = mutex.WaitOne(TimeSpan.FromSeconds(30)); }
                    catch (AbandonedMutexException) { owned = true; }

                    var shipped = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    foreach (string name in asm.GetManifestResourceNames())
                    {
                        if (!name.StartsWith(prefix, StringComparison.Ordinal)) continue;
                        string rel = name.Substring(prefix.Length).Replace('/', Path.DirectorySeparatorChar);
                        string dest = Path.Combine(target, rel);
                        shipped.Add(Path.GetFullPath(dest));

                        byte[] data;
                        using (Stream s = asm.GetManifestResourceStream(name))
                        using (var ms = new MemoryStream())
                        {
                            s.CopyTo(ms);
                            data = ms.ToArray();
                        }

                        if (File.Exists(dest))
                        {
                            byte[] current = null;
                            try { current = File.ReadAllBytes(dest); } catch { }
                            if (current != null && current.Length == data.Length)
                            {
                                bool same = true;
                                for (int i = 0; i < data.Length; i++)
                                    if (current[i] != data[i]) { same = false; break; }
                                if (same) continue;
                            }
                        }
                        Directory.CreateDirectory(Path.GetDirectoryName(dest));
                        // Atomic: write beside the target, then swap it in, so a crash or a full
                        // disk never leaves a half-written script behind. File.Replace is one
                        // operation for an existing file; delete-then-move had a moment with no
                        // script at all, and a crash in it left the script missing.
                        string tmp = dest + ".tmp-" + Process.GetCurrentProcess().Id;
                        try
                        {
                            File.WriteAllBytes(tmp, data);
                            if (File.Exists(dest)) File.Replace(tmp, dest, null);
                            else File.Move(tmp, dest);
                        }
                        finally
                        {
                            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
                        }
                    }

                    // Files this build does not ship: a script an older build unpacked and a newer
                    // one dropped or renamed. Left behind, it stays runnable by name and can still
                    // be dot-sourced by accident. Only inside Scripts\ - Certificates\ and the logs
                    // are siblings of it and are never touched from here. Best-effort: a file that
                    // cannot be removed is not worth refusing to start over.
                    if (Directory.Exists(target))
                    {
                        foreach (string existing in Directory.GetFiles(target, "*", SearchOption.AllDirectories))
                        {
                            if (shipped.Contains(Path.GetFullPath(existing))) continue;
                            try { File.Delete(existing); } catch { }
                        }
                    }
                }
                finally
                {
                    if (owned) mutex.ReleaseMutex();
                }
            }
        }

#endif
    }
}
