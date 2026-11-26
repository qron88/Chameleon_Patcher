// The per-run patch log: where it goes, its header, writing, finishing and pruning old logs.
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
        private void AppendLog(string line)
        {
            if (line == null) return;
            txtLog.AppendText(line + Environment.NewLine);
        }

        // ---------------------------------------------------------------------------------------
        // Event log
        //
        // The on-screen details panel is lost the moment the window closes, which is exactly when
        // a failed patch needs looking at. Everything the child process emits is therefore also
        // written to a timestamped file, incrementally and with AutoFlush on, so the log survives
        // a crash, a kill, or a hang partway through - not just a clean failure.
        //
        // Nothing secret goes in here. The password never appears on the child's command line (it
        // travels in an environment variable, see RunPipelineAsync), so logging the full argument
        // string is safe; the header records only WHETHER one was supplied.
        // ---------------------------------------------------------------------------------------

        private const int LogsToKeep = 20;

        private static string[] CandidateLogDirs()
        {
            // Portable-tool first: a Logs folder beside the .exe is where someone will look. Fall
            // back to per-user locations for the case where the app sits somewhere unwritable.
            return new string[]
            {
                Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Logs"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Chameleon Patcher", "Logs"),
                Path.Combine(Path.GetTempPath(), "Chameleon Patcher Logs")
            };
        }

        private void StartLog(string driverPath, string outputPath, string certPath, string arguments, bool passwordSupplied)
        {
            runClock = Stopwatch.StartNew();
            logPath = null;
            logWriter = null;

            string name = "patch-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log";
            foreach (string dir in CandidateLogDirs())
            {
                try
                {
                    Directory.CreateDirectory(dir);
                    string candidate = Path.Combine(dir, name);
                    var writer = new StreamWriter(candidate, false, new UTF8Encoding(false));
                    writer.AutoFlush = true;
                    logWriter = writer;
                    logPath = candidate;
                    break;
                }
                catch
                {
                    // Try the next location.
                }
            }

            if (logWriter == null)
            {
                AppendLog("[warn] Could not open a log file in any of the candidate locations; this run is not being logged to disk.");
                return;
            }
            runLogOpen = true;

            bool elevated = false;
            try
            {
                var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
                elevated = new System.Security.Principal.WindowsPrincipal(identity)
                    .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
            catch
            {
            }

            WriteRaw("=== Chameleon Patcher - patch log ===");
            WriteRaw("started        : " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss zzz"));
            WriteRaw("version        : " + ReportVersion());
            WriteRaw("executable     : " + Application.ExecutablePath);
            WriteRaw("scripts folder : " + scriptsDir);
            WriteRaw("log file       : " + logPath);
            WriteRaw("machine / user : " + Environment.MachineName + " / " + Environment.UserName);
            WriteRaw("os             : " + DescribeOs());
            WriteRaw("clr            : " + Environment.Version);
            WriteRaw("elevated       : " + elevated);
            WriteRaw("");
            WriteRaw("driver input   : " + driverPath);
            WriteRaw("output folder  : " + outputPath);
            WriteRaw("installer opt  : " + (chkAddInstallerOption.Checked ? "add cert-trust checkbox" : "skipped"));
            WriteRaw("overwrite      : " + chkOverwrite.Checked);
            WriteRaw("prune OEM INFs : " + (chkPruneInfs.Checked ? "yes - package will be specific to this PC" : "no - all INFs kept, portable"));
            WriteRaw("cert file      : " + (certPath.Length == 0 ? "(none - sign from the certificate store)" : certPath));
            WriteRaw("password given : " + (passwordSupplied ? "yes (value never logged)" : "no"));
            WriteRaw("");
            WriteRaw("child command  : powershell.exe " + arguments);
            WriteRaw("");
            WriteRaw("Elapsed times below are from the start of the child process. The pipeline's own");
            WriteRaw("'=== N/M: ... ===' banners mark each step, so the gap between two banners is how");
            WriteRaw("long that step took - useful because the catalog rebuild normally dominates.");
            WriteRaw("");
            WriteRaw("--------------------------------------------------------------------------------");
        }

        private static string ReportVersion()
        {
            // Read back from the assembly rather than hardcoding, so bumping the attributes above
            // is the only edit a release needs. Informational version is preferred because it
            // carries the plain "x.y.z" rather than the four-part file version.
            try
            {
                Assembly asm = Assembly.GetExecutingAssembly();
                var info = (AssemblyInformationalVersionAttribute[])asm.GetCustomAttributes(
                    typeof(AssemblyInformationalVersionAttribute), false);
                if (info.Length > 0 && !string.IsNullOrEmpty(info[0].InformationalVersion))
                {
                    return info[0].InformationalVersion;
                }
                return asm.GetName().Version.ToString();
            }
            catch
            {
                return "(unknown)";
            }
        }

        private static string DescribeOs()
        {
            // Environment.OSVersion is useless here: without an application compatibility
            // manifest Windows reports 6.2.9200 (Windows 8) to every process, so a log from
            // Windows 11 would claim to be Windows 8. For a driver-signing tool the real build is
            // one of the first things you want to know, since Test Signing behaviour and driver
            // signature policy vary by build, so read it from the registry instead.
            string arch = Environment.Is64BitOperatingSystem ? "64-bit" : "32-bit";
            try
            {
                using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    if (key != null)
                    {
                        string product = key.GetValue("ProductName") as string;
                        string display = key.GetValue("DisplayVersion") as string;
                        string build = key.GetValue("CurrentBuild") as string;
                        object ubr = key.GetValue("UBR");

                        // Windows 11 still reports ProductName "Windows 10 ..."; build 22000+ is
                        // the real dividing line.
                        int buildNum;
                        if (product != null && build != null &&
                            int.TryParse(build, out buildNum) && buildNum >= 22000 &&
                            product.IndexOf("Windows 10", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            product = product.Replace("Windows 10", "Windows 11");
                        }

                        var sb = new StringBuilder();
                        sb.Append(product ?? "Windows");
                        if (!string.IsNullOrEmpty(display)) sb.Append(" ").Append(display);
                        if (!string.IsNullOrEmpty(build))
                        {
                            sb.Append(" (build ").Append(build);
                            if (ubr != null) sb.Append(".").Append(ubr);
                            sb.Append(")");
                        }
                        sb.Append(" ").Append(arch);
                        return sb.ToString();
                    }
                }
            }
            catch
            {
            }
            return Environment.OSVersion.VersionString + " " + arch + " (registry unavailable; this figure is unreliable)";
        }

        private void WriteRaw(string text)
        {
            lock (logLock)
            {
                if (logWriter == null) return;
                try
                {
                    logWriter.WriteLine(text);
                }
                catch
                {
                    // A logging failure must never take the run down with it.
                }
            }
        }

        private void LogLine(string tag, string text)
        {
            if (text == null) return;
            TimeSpan t = runClock == null ? TimeSpan.Zero : runClock.Elapsed;
            WriteRaw(string.Format("[{0:00}:{1:00}:{2:00}.{3:000}] {4} {5}",
                (int)t.TotalHours, t.Minutes, t.Seconds, t.Milliseconds, tag, text));
        }

        private void FinishLog(int exitCode, string outcome)
        {
            TimeSpan t = runClock == null ? TimeSpan.Zero : runClock.Elapsed;
            WriteRaw("--------------------------------------------------------------------------------");
            WriteRaw("");
            WriteRaw("finished  : " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss zzz"));
            WriteRaw("duration  : " + string.Format("{0:00}:{1:00}:{2:00}", (int)t.TotalHours, t.Minutes, t.Seconds));
            WriteRaw("exit code : " + exitCode);
            WriteRaw("outcome   : " + outcome);
            if (exitCode != 0)
            {
                WriteRaw("");
                WriteRaw("To diagnose: find the last '=== N/M: ... ===' banner above - that is the step that");
                WriteRaw("failed - then read forward for the first [stderr] line or thrown message. A failure");
                WriteRaw("at the verification step means the patch did not apply and signing was refused on");
                WriteRaw("purpose; see 'The verification gate' in README.md.");
            }

            lock (logLock)
            {
                if (logWriter != null)
                {
                    try
                    {
                        logWriter.Flush();
                        logWriter.Dispose();
                    }
                    catch
                    {
                    }
                    logWriter = null;
                }
                runLogOpen = false;
            }

            PruneOldLogs();
        }

        private void PruneOldLogs()
        {
            // Keep the log folder from growing without bound. Only files this app names are
            // considered, so nothing else in the folder is ever touched.
            if (logPath == null) return;
            try
            {
                var dir = new DirectoryInfo(Path.GetDirectoryName(logPath));
                FileInfo[] logs = dir.GetFiles("patch-*.log");
                if (logs.Length <= LogsToKeep) return;
                Array.Sort(logs, (a, b) => b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc));
                for (int i = LogsToKeep; i < logs.Length; i++)
                {
                    try
                    {
                        logs[i].Delete();
                    }
                    catch
                    {
                    }
                }
            }
            catch
            {
            }
        }

        private void OpenLogLocation()
        {
            if (logPath == null || !File.Exists(logPath))
            {
                MessageBox.Show(this, "No log file from this session yet - run a patch first.",
                    "No log", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            try
            {
                // Open Explorer with the log already selected, rather than just the folder.
                Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + logPath + "\"") { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Couldn't open the log folder:\n" + ex.Message + "\n\nThe log is at:\n" + logPath,
                    "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void OpenLogFile()
        {
            if (logPath == null || !File.Exists(logPath)) return;
            try
            {
                Process.Start(new ProcessStartInfo(logPath) { UseShellExecute = true });
            }
            catch
            {
                OpenLogLocation();
            }
        }
    }
}
