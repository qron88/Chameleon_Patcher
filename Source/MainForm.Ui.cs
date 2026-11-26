// The window itself: controls, layout, browse buttons, closing mid-run, enabling and disabling inputs.
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
        private void BuildUi()
        {
            // Version in the title bar, from the same assembly attribute the log header uses, so
            // a screenshot of the window is enough to tell which build someone is running.
            Text = "Chameleon Patcher " + ReportVersion();

            // Reuse the icon already embedded in this executable by csc's /win32icon, so the
            // window and taskbar match the file icon without shipping a separate .ico alongside
            // the .exe. Purely cosmetic, so a failure here must never stop the app starting.
            try
            {
                Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            }
            catch
            {
            }

            ClientSize = new System.Drawing.Size(560, 458);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;

            var grpDriver = new GroupBox { Text = "Driver package", Left = 15, Top = 15, Width = 530, Height = 100 };
            // Explicit height: a Label defaults to 23 px, which would reach down to y=45 and, being
            // added first (so on top), clip the top edge of the "Select .exe..." button at y=43.
            var lblDriverHint = new Label
            {
                Text = "Downloaded driver installer (.exe), or an already-unpacked folder:",
                Left = 10,
                Top = 22,
                Width = 500,
                Height = 18
            };
            txtDriverPath = new TextBox { Name = "txtDriverPath", Left = 10, Top = 45, Width = 400 };
            var btnBrowseExe = new Button { Text = "Select .exe...", Left = 415, Top = 43, Width = 100 };
            btnBrowseExe.Click += (s, e) => BrowseFile(txtDriverPath, "NVIDIA driver installer (*.exe)|*.exe");
            var btnBrowseFolder = new Button { Text = "Or select an unpacked folder...", Left = 10, Top = 70, Width = 505 };
            btnBrowseFolder.Click += (s, e) => BrowseFolder(txtDriverPath);
            grpDriver.Controls.AddRange(new Control[] { lblDriverHint, txtDriverPath, btnBrowseExe, btnBrowseFolder });

            // The .pfx fields are hidden unless asked for. The normal case needs neither: the
            // pipeline signs with the key already in Cert:\CurrentUser\My, finds it there even if
            // the Certificates folder is gone, and mints one on a PC that has none - all with no
            // password. A .pfx only matters for signing with an EXISTING certificate exported from
            // another PC (e.g. one the target machines already trust) instead of the one here or a
            // new one. The label says that rather than "for a PC without the key": a PC without a
            // key needs nothing ticked, since the pipeline mints a certificate for it.
            // An always-visible password box suggested a password was needed when it almost never is.
            chkUsePfx = new CheckBox
            {
                Text = "Sign with an existing certificate from a .pfx file",
                Left = 20,
                Top = 123,
                Width = 525
            };
            chkUsePfx.CheckedChanged += (s, e) =>
            {
                // Unticking discards the password rather than keeping it out of sight. The path
                // can stay - it is ignored while the box is unticked and harmless to keep.
                if (!chkUsePfx.Checked) txtPassword.Clear();
                LayoutForm();
            };

            grpCert = new GroupBox { Text = "Signing certificate (.pfx)", Left = 15, Width = 530, Height = 116, Visible = false };
            var lblCertHintTicked = new Label
            {
                Text = "Ticked: the certificate in the .pfx file below is used - its password is needed.",
                Left = 10,
                Top = 18,
                Width = 505,
                Height = 18
            };
            var lblCertHintUnticked = new Label
            {
                Text = "Unticked: the key on this PC is used, or a new certificate is created.",
                Left = 10,
                Top = 36,
                Width = 505,
                Height = 18
            };
            txtCertPath = new TextBox { Name = "txtCertPath", Left = 10, Top = 58, Width = 400 };
            var btnBrowseCert = new Button { Text = "Browse...", Left = 415, Top = 56, Width = 100 };
            btnBrowseCert.Click += (s, e) => BrowseFile(txtCertPath, "PFX certificate (*.pfx)|*.pfx");
            var lblPassword = new Label { Text = "Password:", Left = 10, Top = 89, Width = 120, Height = 18 };
            txtPassword = new TextBox { Name = "txtPassword", Left = 135, Top = 86, Width = 280, PasswordChar = '*' };
            grpCert.Controls.AddRange(new Control[] { lblCertHintTicked, lblCertHintUnticked, txtCertPath, btnBrowseCert, lblPassword, txtPassword });

            chkAddInstallerOption = new CheckBox
            {
                Text = "Add a certificate-trust checkbox to the installer, ticked by default (recommended)",
                Left = 20,
                Width = 525,
                Checked = true
            };
            // Off by default, matching the pipeline's own default. Ticking it makes the run about
            // seven times faster by dropping the ~41 OEM display INFs that cannot match this PC,
            // at the cost of a package that only installs here.
            chkPruneInfs = new CheckBox
            {
                Text = "Build for this PC only - much faster, but not portable to other machines",
                Left = 20,
                Width = 525
            };
            chkOverwrite = new CheckBox
            {
                Text = "Delete the output folder first if it already exists",
                Left = 20,
                Width = 525
            };

            btnStart = new Button
            {
                Name = "btnStart",
                Text = "Start Patching",
                Left = 20,
                Width = 525,
                Height = 34,
                Font = new System.Drawing.Font(Font, System.Drawing.FontStyle.Bold)
            };
            btnStart.Click += BtnStart_Click;

            progressBar = new ProgressBar { Left = 20, Width = 525, Height = 20, Minimum = 0, Maximum = 100 };
            lblStep = new Label { Text = "Ready.", Left = 20, Width = 525, Height = 18 };

            btnToggleDetails = new Button { Text = "▼ Show details", Left = 20, Width = 150, FlatStyle = FlatStyle.Flat };
            btnToggleDetails.FlatAppearance.BorderSize = 0;
            btnToggleDetails.Click += (s, e) => ToggleDetails();

            btnOpenLog = new Button
            {
                Text = "Open log folder",
                Left = 175,
                Width = 150,
                FlatStyle = FlatStyle.Flat,
                Enabled = false
            };
            btnOpenLog.FlatAppearance.BorderSize = 0;
            btnOpenLog.Click += (s, e) => OpenLogLocation();

            detailsPanel = new Panel { Left = 20, Width = 525, Height = DetailsPanelHeight, Visible = false };
            txtLog = new TextBox
            {
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Vertical,
                Dock = DockStyle.Fill,
                Font = new System.Drawing.Font("Consolas", 8f),
                BackColor = System.Drawing.Color.Black,
                ForeColor = System.Drawing.Color.LightGray
            };
            detailsPanel.Controls.Add(txtLog);

            // Its own status row BELOW the "Show details" / "Open log folder" buttons, placed by
            // LayoutForm. Not anchored to ClientSize.Height: the window grows when details expand,
            // and a bottom-anchored label would then land inside the log panel.
            lblStatus = new Label
            {
                Text = "",
                Left = 20,
                Width = 525,
                Height = 20,
                ForeColor = System.Drawing.Color.DarkRed
            };

            Controls.AddRange(new Control[]
            {
                grpDriver, chkUsePfx, grpCert, chkAddInstallerOption, chkPruneInfs, chkOverwrite,
                btnStart, progressBar, lblStep, btnToggleDetails, btnOpenLog, detailsPanel, lblStatus
            });

            LayoutForm();
            FormClosing += MainForm_FormClosing;
        }

        /// <summary>
        /// Places everything below the .pfx checkbox in one top-to-bottom pass and sizes the
        /// window to fit, so showing or hiding the .pfx fields or the log panel moves the rest
        /// instead of leaving a gap or overlapping it. Each row starts where the previous one
        /// ends, which also rules out the kind of overlap that clipped the "Select .exe..." button.
        /// </summary>
        private void LayoutForm()
        {
            SuspendLayout();

            int y = chkUsePfx.Bottom;
            grpCert.Visible = chkUsePfx.Checked;
            if (grpCert.Visible)
            {
                grpCert.Top = y + 3;
                y = grpCert.Bottom + 8;
            }

            chkAddInstallerOption.Top = y;
            chkPruneInfs.Top = chkAddInstallerOption.Bottom;
            chkOverwrite.Top = chkPruneInfs.Bottom;

            btnStart.Top = chkOverwrite.Bottom + 8;
            progressBar.Top = btnStart.Bottom + 10;
            lblStep.Top = progressBar.Bottom + 4;
            btnToggleDetails.Top = lblStep.Bottom + 4;
            btnOpenLog.Top = btnToggleDetails.Top;
            lblStatus.Top = btnToggleDetails.Bottom + 3;

            detailsPanel.Top = lblStatus.Bottom + 4;
            int height = detailsPanel.Visible ? detailsPanel.Bottom + 26 : lblStatus.Bottom;
            ClientSize = new System.Drawing.Size(ClientSize.Width, height);

            ResumeLayout();
        }

        private void ToggleDetails()
        {
            detailsPanel.Visible = !detailsPanel.Visible;
            btnToggleDetails.Text = detailsPanel.Visible ? "▲ Hide details" : "▼ Show details";
            LayoutForm();
        }

        private void BrowseFile(TextBox target, string filter)
        {
            using (var dlg = new OpenFileDialog { Filter = filter })
            {
                if (dlg.ShowDialog(this) == DialogResult.OK)
                {
                    target.Text = dlg.FileName;
                }
            }
        }

        private void BrowseFolder(TextBox target)
        {
            using (var dlg = new FolderBrowserDialog())
            {
                if (dlg.ShowDialog(this) == DialogResult.OK)
                {
                    target.Text = dlg.SelectedPath;
                }
            }
        }

        private void MainForm_FormClosing(object sender, FormClosingEventArgs e)
        {
            if (running)
            {
                var result = MessageBox.Show(
                    this,
                    "Patching is still running. Closing now will abort it partway through. Close anyway?",
                    "Patching in progress",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning);
                if (result != DialogResult.Yes)
                {
                    e.Cancel = true;
                    return;
                }

                // Going down mid-run. Stop the whole child tree - powershell.exe and whatever it
                // started (7z, Inf2Cat, signtool) - then record that explicitly, so the log ends
                // with a reason instead of just stopping and looking like a hang or a crash.
                closing = true;
                LogLine("[abort]", "window closed by the user while the patch was still running - stopping the pipeline");
                bool stopped = KillProcessTree(pipelineProcess);
                LogLine("[abort]", stopped ? "pipeline process tree stopped" : "could not confirm the pipeline process tree stopped");
                FinishLog(-1, "ABORTED - window closed mid-run; the unfinished work is in the .partial folder beside the output");
            }

            // The form is going away: detach the static crash handlers from it so a late crash
            // reports a dialog only, rather than writing into a disposed form's log.
            if (Live == this) Live = null;
        }

        /// <summary>
        /// Runs an action on the UI thread unless the window is already going down. The child's
        /// output callbacks arrive on threadpool threads and can outlive the form by a moment.
        /// </summary>
        private void PostToUi(Action action)
        {
            if (closing || IsDisposed || !IsHandleCreated) return;
            try
            {
                BeginInvoke((MethodInvoker)delegate
                {
                    if (!closing && !IsDisposed) action();
                });
            }
            catch (InvalidOperationException)
            {
                // Includes ObjectDisposedException: the handle went away between the check and the post.
            }
        }

        private void SetRunning(bool value)
        {
            running = value;
            SetInputsEnabled(!value);
        }

        private void SetInputsEnabled(bool enabled)
        {
            btnStart.Enabled = enabled;
            txtDriverPath.Enabled = enabled;
            chkUsePfx.Enabled = enabled;
            txtCertPath.Enabled = enabled;
            txtPassword.Enabled = enabled;
            chkAddInstallerOption.Enabled = enabled;
            chkPruneInfs.Enabled = enabled;
            chkOverwrite.Enabled = enabled;
        }
    }
}
