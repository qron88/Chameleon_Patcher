// The "required tools missing" window and the text helpers that lay its message out.
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
        /// The refused-run window. A MessageBox cannot carry a button of its own, and a user who has
        /// to retype an install command is a user who mistypes it, so this window is laid out like the
        /// MessageBox it replaces - error icon at the left, the system message font, nothing in its
        /// title bar, buttons along the bottom right - and carries one button more: it opens the
        /// download page of whatever is missing in the default browser, both pages when both tools are
        /// missing, because this message is read on machines that may not have a terminal open. The
        /// message itself is plain
        /// labels on the face of the window, not a field to fill in: nothing is selected, nothing has
        /// to be scrolled, nothing blinks, and no line is cut at the edge, because every line gets a
        /// label exactly as wide and as tall as the text it holds.
        /// </summary>
        private void ShowMissingToolsDialog(string message, string linksText)
        {
            using (Form dialog = new Form())
            {
                dialog.Text = "Required tools missing";
                dialog.FormBorderStyle = FormBorderStyle.FixedDialog;
                dialog.MaximizeBox = false;
                dialog.MinimizeBox = false;
                dialog.ShowInTaskbar = false;
                dialog.StartPosition = FormStartPosition.CenterParent;
                dialog.ShowIcon = false;   // a MessageBox has nothing in its title bar either
                // Everything below is positioned in pixels measured at this window's own DPI, so the
                // form must not scale those pixels a second time on a scaled display.
                dialog.AutoScaleMode = System.Windows.Forms.AutoScaleMode.None;

                System.Drawing.Font textFont = System.Drawing.SystemFonts.MessageBoxFont;

                PictureBox icon = new PictureBox();
                // An Icon is not an Image - it is its own thing - so the system error icon is handed
                // to the picture box as a bitmap.
                icon.Image = System.Drawing.SystemIcons.Error.ToBitmap();
                icon.SizeMode = PictureBoxSizeMode.CenterImage;
                icon.Left = 12;
                icon.Top = 14;
                icon.Width = 32;
                icon.Height = 32;
                icon.TabStop = false;
                dialog.Controls.Add(icon);

                // One label per line, which is what a MessageBox actually paints: plain text on the
                // face of the window, with no field around it, nothing selected, nothing to scroll and
                // no caret sitting in the middle of the message. Each label is left to size itself to
                // its own text, so the window grows to fit the widest line instead of clipping it, and
                // the download address is never split across a window edge. Blank lines of the message
                // are paragraph breaks, and a label with no text has no height at all, so they carry a
                // single space to hold the gap open.
                int textLeft = 56;
                int y = 14;
                int widestRight = textLeft;
                foreach (string line in message.Replace("\r\n", "\n").Split('\n'))
                {
                    Label textLine = new Label();
                    textLine.Font = textFont;
                    textLine.AutoSize = true;
                    textLine.Margin = new System.Windows.Forms.Padding(0);
                    textLine.Text = line.Length > 0 ? line : " ";
                    textLine.Left = textLeft;
                    textLine.Top = y;
                    dialog.Controls.Add(textLine);
                    y = textLine.Bottom;
                    if (textLine.Right > widestRight) widestRight = textLine.Right;
                }
                int textBottom = y;

                // The button opens the page the guidance named. Handing over an address to copy is the
                // wrong shape for this message: the run is being refused on a machine that may not have
                // a terminal open, and the fix is a download, not something to type.
                Button openButton = null;
                int linkCount = 0;
                if (linksText.Length > 0)
                {
                    foreach (string line in linksText.Replace("\r\n", "\n").Split('\n'))
                    {
                        if (line.Trim().Length > 0) linkCount++;
                    }
                    openButton = new Button();
                    openButton.Text = OpenButtonText(linksText, linkCount);
                    openButton.AutoSize = true;
                    openButton.Margin = new System.Windows.Forms.Padding(0);
                    openButton.Top = textBottom + 14;
                    openButton.Left = 0;   // set below, once OK has its place
                    openButton.Click += delegate
                    {
                        int opened = 0;
                        foreach (string line in linksText.Replace("\r\n", "\n").Split('\n'))
                        {
                            string url = line.Trim();
                            if (url.Length == 0) continue;
                            // The text comes from the child's stdout; only ever hand the shell a web
                            // address, never a path or a command that happens to sit on that line.
                            if (!url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) continue;
                            try
                            {
                                // A URL handed to Process.Start goes through the shell, so whatever the
                                // user set as their browser answers here.
                                Process.Start(url);
                                opened++;
                            }
                            catch (Exception ex)
                            {
                                MessageBox.Show(dialog,
                                    "Couldn't open that page in your browser:\n" + url + "\n\n" + ex.Message +
                                    "\n\nType the address into any browser yourself.",
                                    "Couldn't open the page", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                            }
                        }
                        if (opened > 0) openButton.Text = "Opened in your browser";
                    };
                    dialog.Controls.Add(openButton);
                }

                Button okButton = new Button();
                okButton.Text = "OK";
                okButton.AutoSize = true;
                okButton.Margin = new System.Windows.Forms.Padding(0);
                okButton.DialogResult = DialogResult.OK;
                // A MessageBox runs its buttons along the bottom right, the main action last. Same
                // here, so this reads like the window it replaced and the copy button is one more
                // thing beside the answer rather than a different kind of window.
                int rightEdge = widestRight + 12;
                okButton.Top = textBottom + 14;
                okButton.Left = rightEdge - okButton.PreferredSize.Width;
                if (openButton != null)
                {
                    openButton.Left = okButton.Left - 10 - openButton.PreferredSize.Width;
                    if (openButton.Left < 12) openButton.Left = 12;
                }
                dialog.Controls.Add(okButton);
                dialog.AcceptButton = okButton;
                dialog.CancelButton = okButton;   // Escape closes it, as it closed the MessageBox
                dialog.ActiveControl = okButton;  // OK holds the focus, as it does in a MessageBox
                dialog.ClientSize = new System.Drawing.Size(rightEdge + 12, okButton.Bottom + 12);

                dialog.ShowDialog(this);
            }
        }

        /// <summary>
        /// The width the refused-run dialog is wrapped to. A MessageBox picks its own width and
        /// breaks long lines wherever it likes, which is how a folder path or a winget command used
        /// to end up cut in half in the middle of the text the user was supposed to act on. Wrapping
        /// here means every line is short enough that the dialog keeps the breaks this code chose.
        /// </summary>
        private const int DialogTextWidth = 50;

        /// <summary>
        /// The tool identifiers the pipeline reports (Inf2Cat.exe, 7z) as the names a person is
        /// looking for on an install screen.
        /// </summary>
        private static string HumanToolName(string tool)
        {
            if (tool == "Inf2Cat.exe" || tool == "Inf2Cat") return "Inf2Cat (rebuilds the driver catalog)";
            if (tool == "signtool.exe" || tool == "signtool") return "signtool (signs the rebuilt catalog)";
            if (tool == "7z") return "a 7z-compatible CLI (7-Zip or NanaZip)";
            return tool;
        }

        // The found tools are only listed, not explained: what a name means is already stated for
        // the tools that are missing, and repeating it stretches the message for no reason.
        // The button names the page it is about to bring up, so it never reads as a generic "open"
        // that might open the wrong thing.
        private static string OpenButtonText(string linksText, int linkCount)
        {
            if (linkCount > 1) return "Open both download pages";
            if (linksText.IndexOf("7-zip.org", StringComparison.OrdinalIgnoreCase) >= 0) return "Open the 7-Zip download page";
            if (linksText.IndexOf("windows-sdk", StringComparison.OrdinalIgnoreCase) >= 0) return "Open the Windows SDK download page";
            return "Open the download page";
        }

        private static string ShortToolName(string tool)
        {
            if (tool == "Inf2Cat.exe" || tool == "Inf2Cat") return "Inf2Cat";
            if (tool == "signtool.exe" || tool == "signtool") return "signtool";
            if (tool == "7z") return "a 7z-compatible CLI";
            return tool;
        }

        private static string AppendName(string existing, string addition)
        {
            if (existing.Length == 0) return addition;
            return existing + ", " + addition;
        }

        /// <summary>
        /// Word-wrap. A word longer than the width gets a line to itself rather than being split,
        /// so a URL or a path is never broken across two lines.
        /// </summary>
        private static string WrapText(string text, int width)
        {
            var result = new StringBuilder();
            var line = new StringBuilder();
            foreach (string word in text.Split(' '))
            {
                if (word.Length == 0) continue;
                if (line.Length > 0 && line.Length + 1 + word.Length > width)
                {
                    result.AppendLine(line.ToString());
                    line.Length = 0;
                }
                if (line.Length > 0) line.Append(' ');
                line.Append(word);
            }
            if (line.Length > 0) result.Append(line.ToString());
            return result.ToString();
        }

        /// <summary>
        /// Wraps whatever prose was collected as one paragraph and appends it, so a paragraph that
        /// the pipeline happened to break into eight short lines still arrives as full-width text.
        /// </summary>
        private static void FlushProse(StringBuilder prose, StringBuilder guidance)
        {
            if (prose.Length == 0) return;
            guidance.AppendLine(WrapText(prose.ToString().Trim(), DialogTextWidth).TrimEnd());
            prose.Length = 0;
        }

        private static string IndentLines(string wrapped, int indent)
        {
            if (indent <= 0) return wrapped;
            string pad = new string(' ', indent);
            var sb = new StringBuilder();
            foreach (string line in wrapped.Replace("\r\n", "\n").Split('\n'))
            {
                if (line.Length > 0) sb.Append(pad);
                sb.AppendLine(line);
            }
            return sb.ToString().TrimEnd('\n');
        }
    }
}
