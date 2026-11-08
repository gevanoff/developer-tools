// DroidRun dashboard view: dark theme, owner-drawn status list, and layout.
//
// Compiled at run time by Add-Type from DroidRunTheme.ps1 under Windows
// PowerShell 5.1, so this file must stay within C# 5 (no string interpolation,
// expression-bodied members, or null-conditional operators) and use only
// .NET Framework 4.x Windows Forms APIs. Behaviour (processes, Git, ADB, saved
// projects) stays in PowerShell; this file only builds and draws controls.
// The palette matches DroidRunPresentation.ps1 and the Linux theme.py.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace DroidRun
{
    internal static class NativeMethods
    {
        [DllImport("dwmapi.dll")]
        internal static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        internal static extern int SetWindowTheme(IntPtr hwnd, string appName, string idList);
    }

    public static class Theme
    {
        private static bool? enabledOverride;

        // High contrast keeps the system colours so Windows' contrast themes still apply.
        public static bool Enabled
        {
            get { return enabledOverride.HasValue ? enabledOverride.Value : !SystemInformation.HighContrast; }
        }

        public static void OverrideEnabled(bool enabled) { enabledOverride = enabled; }

        public static Color Hex(string value) { return ColorTranslator.FromHtml(value); }

        public static Color Bg { get { return Enabled ? Hex("#0E1726") : SystemColors.Control; } }
        public static Color Surface { get { return Enabled ? Hex("#142238") : SystemColors.Window; } }
        public static Color Raised { get { return Enabled ? Hex("#1B2C46") : SystemColors.Control; } }
        public static Color Select { get { return Enabled ? Hex("#22395C") : SystemColors.Highlight; } }
        public static Color Border { get { return Enabled ? Hex("#2A3D5C") : SystemColors.ControlDark; } }
        public static Color ConsoleBack { get { return Enabled ? Hex("#0A111D") : SystemColors.Window; } }
        public static Color Text { get { return Enabled ? Hex("#E8EEF6") : SystemColors.WindowText; } }
        public static Color SelectedText { get { return Enabled ? Hex("#E8EEF6") : SystemColors.HighlightText; } }
        public static Color Muted { get { return Enabled ? Hex("#9FB0C8") : SystemColors.WindowText; } }
        public static Color Disabled { get { return Enabled ? Hex("#7D8DA6") : SystemColors.GrayText; } }
        public static Color Lime { get { return Enabled ? Hex("#B8F526") : SystemColors.Highlight; } }
        public static Color LimeHover { get { return Hex("#CCFF4D"); } }
        public static Color LimePressed { get { return Hex("#A3DB1F"); } }
        public static Color LimeMuted { get { return Hex("#3C4A2A"); } }
        public static Color OnLime { get { return Enabled ? Hex("#142238") : SystemColors.HighlightText; } }
        public static Color OnLimeMuted { get { return Hex("#A9B88F"); } }

        public static Color ToneText(string tone)
        {
            if (!Enabled) { return SystemColors.WindowText; }
            switch (tone)
            {
                case "ok": return Hex("#5EE0A0");
                case "action": return Hex("#7CC4FF");
                case "warn": return Hex("#FFC857");
                case "error": return Hex("#FF8A80");
                default: return Hex("#9FB0C8");
            }
        }

        public static Color ToneBackground(string tone)
        {
            if (!Enabled) { return SystemColors.Window; }
            return Mix(ToneText(tone), Hex("#142238"), 0.16);
        }

        public static Color Mix(Color foreground, Color background, double alpha)
        {
            return Color.FromArgb(
                (int)Math.Round(foreground.R * alpha + background.R * (1 - alpha), MidpointRounding.AwayFromZero),
                (int)Math.Round(foreground.G * alpha + background.G * (1 - alpha), MidpointRounding.AwayFromZero),
                (int)Math.Round(foreground.B * alpha + background.B * (1 - alpha), MidpointRounding.AwayFromZero));
        }

        public static GraphicsPath Rounded(Rectangle bounds, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            int diameter = Math.Max(1, Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height)));
            path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
            path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
            path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure();
            return path;
        }

        // Dark title bar on Windows 10 1809+ / 11. Harmless elsewhere.
        public static void ApplyWindowChrome(Form form)
        {
            if (!Enabled) { return; }
            form.HandleCreated += delegate(object sender, EventArgs args)
            {
                try
                {
                    int dark = 1;
                    if (NativeMethods.DwmSetWindowAttribute(form.Handle, 20, ref dark, 4) != 0)
                    {
                        NativeMethods.DwmSetWindowAttribute(form.Handle, 19, ref dark, 4);
                    }
                }
                catch (Exception) { }
            };
        }

        public static void DarkScrollBars(Control control)
        {
            if (!Enabled) { return; }
            EventHandler apply = delegate(object sender, EventArgs args)
            {
                try { NativeMethods.SetWindowTheme(control.Handle, "DarkMode_Explorer", null); }
                catch (Exception) { }
            };
            if (control.IsHandleCreated) { apply(control, EventArgs.Empty); }
            control.HandleCreated += apply;
        }

        public static void ApplyForm(Form form)
        {
            form.BackColor = Bg;
            form.ForeColor = Text;
            ApplyWindowChrome(form);
        }

        public static void StyleInput(TextBox box)
        {
            if (!Enabled) { return; }
            box.BackColor = ConsoleBack;
            box.ForeColor = Text;
            box.BorderStyle = BorderStyle.FixedSingle;
        }

        public static void StyleCheckBox(CheckBox box)
        {
            if (!Enabled) { return; }
            box.FlatStyle = FlatStyle.Flat;
            box.FlatAppearance.BorderColor = Hex("#4A6288");
            box.FlatAppearance.CheckedBackColor = Hex("#2C4A12");
            box.BackColor = Color.Transparent;
            box.ForeColor = Text;
        }

        public static Label NewLabel(string text, float points, FontStyle style, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.AutoSize = false;
            label.AutoEllipsis = true;
            label.UseMnemonic = false;
            label.ForeColor = color;
            label.BackColor = Color.Transparent;
            label.Font = new Font("Segoe UI", points, style);
            label.TextAlign = ContentAlignment.MiddleLeft;
            return label;
        }
    }

    public enum ButtonKind { Secondary, Primary, Quiet }

    // Fully painted button so primary, hover, focus, and disabled states are legible on
    // the dark surfaces. Falls back to the system button in high contrast.
    public class ThemedButton : Button
    {
        private bool hover;
        private bool pressed;
        private ButtonKind kind;

        public ThemedButton(string text, ButtonKind kind)
        {
            Text = text;
            this.kind = kind;
            UseVisualStyleBackColor = !Theme.Enabled;
            if (Theme.Enabled)
            {
                SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                         ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
                FlatStyle = FlatStyle.Flat;
            }
            Font = new Font("Segoe UI", 9f, kind == ButtonKind.Primary ? FontStyle.Bold : FontStyle.Regular);
            Cursor = Cursors.Hand;
        }

        public ButtonKind Kind
        {
            get { return kind; }
            set { kind = value; Invalidate(); }
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { pressed = e.Button == MouseButtons.Left; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (!Theme.Enabled) { base.OnPaint(e); return; }
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Color parentBack = Parent != null ? Parent.BackColor : Theme.Bg;
            using (SolidBrush clear = new SolidBrush(parentBack)) { g.FillRectangle(clear, ClientRectangle); }

            Color fill, border, text;
            if (kind == ButtonKind.Primary)
            {
                fill = !Enabled ? Theme.LimeMuted : pressed ? Theme.LimePressed : hover ? Theme.LimeHover : Theme.Lime;
                border = fill;
                text = Enabled ? Theme.OnLime : Theme.OnLimeMuted;
            }
            else if (kind == ButtonKind.Quiet)
            {
                fill = !Enabled ? parentBack : pressed ? Theme.Border : hover ? Theme.Raised : parentBack;
                border = hover && Enabled ? Theme.Border : fill;
                text = Enabled ? Theme.Text : Theme.Disabled;
            }
            else
            {
                fill = !Enabled ? Theme.Surface : pressed ? Theme.Border : hover ? Theme.Select : Theme.Raised;
                border = Enabled ? (hover ? Theme.Hex("#3A5480") : Theme.Border) : Theme.Raised;
                text = Enabled ? Theme.Text : Theme.Disabled;
            }

            Rectangle box = new Rectangle(0, 0, Width - 1, Height - 1);
            int radius = Math.Max(4, (int)Math.Round(6 * DeviceScale(this)));
            using (GraphicsPath path = Theme.Rounded(box, radius))
            using (SolidBrush brush = new SolidBrush(fill))
            using (Pen pen = new Pen(border))
            {
                g.FillPath(brush, path);
                g.DrawPath(pen, path);
            }
            if (Focused && ShowFocusCues)
            {
                Rectangle ring = new Rectangle(1, 1, Width - 3, Height - 3);
                using (GraphicsPath path = Theme.Rounded(ring, radius))
                using (Pen pen = new Pen(kind == ButtonKind.Primary ? Theme.Text : Theme.Lime, 2f))
                {
                    g.DrawPath(pen, path);
                }
            }
            TextFormatFlags flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
                                    TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis;
            if (!ShowKeyboardCues) { flags |= TextFormatFlags.HidePrefix; }
            TextRenderer.DrawText(g, Text, Font, new Rectangle(6, 0, Width - 12, Height), text, flags);
        }

        public static float DeviceScale(Control control)
        {
            try
            {
                using (Graphics g = control.CreateGraphics()) { return Math.Max(1f, g.DpiX / 96f); }
            }
            catch (Exception) { return 1f; }
        }
    }

    // A rounded surface with a 1px border; child controls sit on Theme.Surface.
    public class CardPanel : Panel
    {
        public CardPanel()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            BackColor = Theme.Surface;
            ForeColor = Theme.Text;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Color outside = Parent != null ? Parent.BackColor : Theme.Bg;
            using (SolidBrush clear = new SolidBrush(outside)) { e.Graphics.FillRectangle(clear, ClientRectangle); }
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle box = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = Theme.Rounded(box, 8))
            using (SolidBrush brush = new SolidBrush(Theme.Surface))
            using (Pen pen = new Pen(Theme.Border))
            {
                e.Graphics.FillPath(brush, path);
                e.Graphics.DrawPath(pen, path);
            }
        }
    }

    // Panel used as a 1px border around a borderless child (console, list).
    public class BorderHost : Panel
    {
        public BorderHost(Control child)
        {
            BackColor = Theme.Border;
            Padding = new Padding(1);
            child.Dock = DockStyle.Fill;
            Controls.Add(child);
        }
    }

    // Rounded status pill such as "Running" or "Failed".
    public class Badge : Control
    {
        private string tone = "neutral";

        public Badge()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.UserPaint | ControlStyles.SupportsTransparentBackColor, true);
            Font = new Font("Segoe UI", 9f, FontStyle.Bold);
        }

        public string Tone
        {
            get { return tone; }
            set { tone = value ?? "neutral"; Invalidate(); }
        }

        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Color outside = Parent != null ? Parent.BackColor : Theme.Surface;
            using (SolidBrush clear = new SolidBrush(outside)) { e.Graphics.FillRectangle(clear, ClientRectangle); }
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle box = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = Theme.Rounded(box, Height / 2))
            using (SolidBrush brush = new SolidBrush(Theme.ToneBackground(tone)))
            {
                e.Graphics.FillPath(brush, path);
                if (!Theme.Enabled)
                {
                    using (Pen pen = new Pen(SystemColors.WindowText)) { e.Graphics.DrawPath(pen, path); }
                }
            }
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, Theme.ToneText(tone),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        }
    }

    // Thin indeterminate progress bar; native ProgressBar colours cannot be themed.
    public class ActivityBar : Control
    {
        private readonly Timer timer = new Timer();
        private int offset;

        public ActivityBar()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            timer.Interval = 30;
            timer.Tick += delegate(object sender, EventArgs args)
            {
                offset = (offset + Math.Max(4, Width / 80)) % Math.Max(1, Width + Width / 3);
                Invalidate();
            };
            TabStop = false;
        }

        public bool Running
        {
            get { return timer.Enabled; }
            set
            {
                // Respect "Show animations in Windows" (reduced motion): show a static bar.
                timer.Enabled = value && SystemInformation.UIEffectsEnabled;
                Visible = value;
                Invalidate();
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Theme.Raised);
            int segment = Math.Max(20, Width / 3);
            int left = timer.Enabled ? offset - segment : 0;
            using (SolidBrush brush = new SolidBrush(Theme.Lime))
            {
                e.Graphics.FillRectangle(brush, new Rectangle(left, 0, timer.Enabled ? segment : Width, Height));
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) { timer.Dispose(); }
            base.Dispose(disposing);
        }
    }

    // Per-cell display data, stored in ListViewSubItem.Tag by the PowerShell side.
    public sealed class ChipCell
    {
        public ChipCell(string tone, string prefix) { Tone = tone; Prefix = prefix; }
        public string Tone { get; private set; }
        public string Prefix { get; private set; }
    }

    public enum CellKind { Text, Muted, Project, Chip }

    internal static class Tags
    {
        // Values assigned from PowerShell can arrive wrapped in a PSObject. Read its
        // BaseObject by reflection so this file needs no PowerShell assembly reference.
        internal static object Unwrap(object value)
        {
            if (value == null) { return null; }
            System.Reflection.PropertyInfo baseObject = value.GetType().GetProperty("BaseObject");
            if (baseObject != null && value.GetType().FullName == "System.Management.Automation.PSObject")
            {
                return baseObject.GetValue(value, null);
            }
            return value;
        }

        internal static string Text(object value)
        {
            object unwrapped = Unwrap(value);
            return unwrapped == null ? string.Empty : unwrapped.ToString();
        }
    }

    // Details-view list with a dark header, two-line project rows, and status chips.
    // Column.Tag holds a CellKind. A Project cell shows the item text with the
    // item's Tag (the project path) beneath it.
    public class StatusListView : ListView
    {
        private ImageList rowHeightList;

        public StatusListView()
        {
            View = View.Details;
            FullRowSelect = true;
            HideSelection = false;
            MultiSelect = false;
            GridLines = false;
            BorderStyle = BorderStyle.None;
            OwnerDraw = Theme.Enabled;
            DoubleBuffered = true;
            BackColor = Theme.Surface;
            ForeColor = Theme.Text;
            Font = new Font("Segoe UI", 9f);
            Theme.DarkScrollBars(this);
        }

        // ListView row height follows its small image height.
        public int RowHeight
        {
            get { return rowHeightList == null ? 0 : rowHeightList.ImageSize.Height; }
            set
            {
                ImageList old = rowHeightList;
                rowHeightList = new ImageList();
                rowHeightList.ImageSize = new Size(1, Math.Max(16, Math.Min(256, value)));
                SmallImageList = rowHeightList;
                if (old != null) { old.Dispose(); }
            }
        }

        public ColumnHeader AddColumn(string text, int width, CellKind kind)
        {
            ColumnHeader column = Columns.Add(text, width);
            column.Tag = kind;
            return column;
        }

        protected override void OnDrawColumnHeader(DrawListViewColumnHeaderEventArgs e)
        {
            using (SolidBrush brush = new SolidBrush(Theme.Raised)) { e.Graphics.FillRectangle(brush, e.Bounds); }
            using (Pen pen = new Pen(Theme.Border))
            {
                e.Graphics.DrawLine(pen, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
            }
            using (Font bold = new Font(Font, FontStyle.Bold))
            {
                Rectangle text = Rectangle.FromLTRB(e.Bounds.Left + 10, e.Bounds.Top, e.Bounds.Right - 4, e.Bounds.Bottom);
                TextRenderer.DrawText(e.Graphics, e.Header.Text, bold, text, Theme.Muted,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
            }
        }

        protected override void OnDrawItem(DrawListViewItemEventArgs e)
        {
            // Sub-items draw the whole row; drawing here as well causes flicker.
            e.DrawDefault = false;
        }

        protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e)
        {
            Graphics g = e.Graphics;
            bool selected = e.Item.Selected;
            Rectangle bounds = e.Bounds;
            using (SolidBrush back = new SolidBrush(selected ? Theme.Select : Theme.Surface)) { g.FillRectangle(back, bounds); }
            using (Pen line = new Pen(Theme.Border)) { g.DrawLine(line, bounds.Left, bounds.Bottom - 1, bounds.Right, bounds.Bottom - 1); }
            if (e.ColumnIndex == 0 && selected)
            {
                using (SolidBrush bar = new SolidBrush(Theme.Lime)) { g.FillRectangle(bar, bounds.Left, bounds.Top, 3, bounds.Height - 1); }
            }

            CellKind kind = e.Header != null && e.Header.Tag is CellKind ? (CellKind)e.Header.Tag : CellKind.Text;
            Rectangle area = Rectangle.FromLTRB(bounds.Left + 10, bounds.Top, bounds.Right - 6, bounds.Bottom);
            string text = e.SubItem != null ? e.SubItem.Text : string.Empty;
            TextFormatFlags single = TextFormatFlags.VerticalCenter | TextFormatFlags.Left |
                                     TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix;

            if (kind == CellKind.Project)
            {
                string subtitle = Tags.Text(e.Item.Tag);
                int half = bounds.Height / 2;
                using (Font bold = new Font(Font, FontStyle.Bold))
                using (Font small = new Font(Font.FontFamily, Math.Max(7f, Font.SizeInPoints - 0.5f)))
                {
                    TextRenderer.DrawText(g, e.Item.Text, bold,
                        Rectangle.FromLTRB(area.Left, bounds.Top + 3, area.Right, bounds.Top + half + 1), Theme.Text,
                        TextFormatFlags.Bottom | TextFormatFlags.Left | TextFormatFlags.SingleLine |
                        TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
                    TextRenderer.DrawText(g, subtitle, small,
                        Rectangle.FromLTRB(area.Left, bounds.Top + half + 1, area.Right, bounds.Bottom - 3), Theme.Muted,
                        TextFormatFlags.Top | TextFormatFlags.Left | TextFormatFlags.SingleLine |
                        TextFormatFlags.PathEllipsis | TextFormatFlags.NoPrefix);
                }
                return;
            }

            ChipCell chip = e.SubItem != null ? Tags.Unwrap(e.SubItem.Tag) as ChipCell : null;
            if (kind == CellKind.Chip && chip != null)
            {
                int left = area.Left;
                if (!string.IsNullOrEmpty(chip.Prefix))
                {
                    int width = Math.Min(TextRenderer.MeasureText(g, chip.Prefix, Font, Size.Empty, TextFormatFlags.NoPrefix).Width + 2,
                                         Math.Max(40, area.Width / 2));
                    TextRenderer.DrawText(g, chip.Prefix, Font, new Rectangle(left, bounds.Top, width, bounds.Height),
                        selected ? Theme.SelectedText : Theme.Text, single | TextFormatFlags.EndEllipsis);
                    left += width + 6;
                }
                DrawChip(g, Rectangle.FromLTRB(left, bounds.Top, area.Right, bounds.Bottom), text, chip.Tone, Font);
                return;
            }

            Color color = kind == CellKind.Muted ? Theme.Muted : (selected ? Theme.SelectedText : Theme.Text);
            TextRenderer.DrawText(g, text, Font, area, color, single | TextFormatFlags.EndEllipsis);
        }

        public static void DrawChip(Graphics g, Rectangle area, string text, string tone, Font font)
        {
            if (area.Width < 12) { return; }
            Size size = TextRenderer.MeasureText(g, text, font, Size.Empty, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            int height = size.Height + 6;
            int width = Math.Min(area.Width, size.Width + 16);
            Rectangle box = new Rectangle(area.Left, area.Top + (area.Height - height) / 2, width, height);
            SmoothingMode previous = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = Theme.Rounded(box, height / 2))
            using (SolidBrush brush = new SolidBrush(Theme.ToneBackground(tone)))
            {
                g.FillPath(brush, path);
            }
            g.SmoothingMode = previous;
            TextRenderer.DrawText(g, text, font, Rectangle.Inflate(box, -6, 0), Theme.ToneText(tone),
                TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.SingleLine |
                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        }

        // Keep the last column filling the remaining width so no unpainted (system
        // coloured) header strip appears to its right, including when a scroll bar
        // appears. -2 is LVSCW_AUTOSIZE_USEHEADER.
        public void FillLastColumn()
        {
            if (Columns.Count > 0 && IsHandleCreated) { Columns[Columns.Count - 1].Width = -2; }
        }

        protected override void OnClientSizeChanged(EventArgs e)
        {
            base.OnClientSizeChanged(e);
            FillLastColumn();
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            // Owner-drawn ListView can repaint the first cell with default drawing on hover.
            ListViewItem item = GetItemAt(e.X, e.Y);
            if (item != null && OwnerDraw) { Invalidate(item.Bounds); }
            base.OnMouseMove(e);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && rowHeightList != null) { rowHeightList.Dispose(); rowHeightList = null; }
            base.Dispose(disposing);
        }
    }

    // All controls of the main dashboard and their layout. PowerShell wires events.
    public class DashboardView
    {
        private readonly Form form;
        private float scale = 1f;

        public Panel Header;
        public PictureBox Logo;
        public Label AppName;
        public Label Subtitle;
        public Label StatusTimestamp;
        public ThemedButton Scan;
        public ThemedButton Reports;
        public ThemedButton Refresh;

        public Label ProjectsTitle;
        public ThemedButton Add;
        public StatusListView Projects;
        public BorderHost ProjectsFrame;
        public Label EmptyMessage;

        public CardPanel Details;
        public Label DetailName;
        public Label DetailPath;
        public Label DetailPlan;
        public Label DetailFix;
        public Label DetailSettings;
        public ThemedButton Sync;
        public ThemedButton Build;
        public ThemedButton GitPull;
        public ThemedButton InstallApk;
        public ThemedButton Settings;
        public ThemedButton Remove;

        public CardPanel Operation;
        public Badge OperationBadge;
        public Label OperationTitle;
        public Label OperationStatus;
        public ThemedButton CopyOutput;
        public ThemedButton CancelOperation;
        public ActivityBar OperationProgress;
        public RichTextBox OperationOutput;
        public BorderHost OperationOutputFrame;

        public DashboardView(Form form, Image logo)
        {
            this.form = form;
            Theme.ApplyForm(form);
            form.Font = new Font("Segoe UI", 9f);

            Header = new Panel();
            Header.BackColor = Theme.Surface;
            Header.Paint += delegate(object sender, PaintEventArgs e)
            {
                using (Pen pen = new Pen(Theme.Border)) { e.Graphics.DrawLine(pen, 0, Header.Height - 1, Header.Width, Header.Height - 1); }
            };
            Logo = new PictureBox();
            Logo.SizeMode = PictureBoxSizeMode.Zoom;
            Logo.Image = logo;
            Logo.BackColor = Color.Transparent;
            AppName = Theme.NewLabel("DroidRun", 14f, FontStyle.Bold, Theme.Text);
            Subtitle = Theme.NewLabel("Build, install, and launch Android projects", 9f, FontStyle.Regular, Theme.Muted);
            StatusTimestamp = Theme.NewLabel("Status not checked.", 9f, FontStyle.Regular, Theme.Muted);
            StatusTimestamp.TextAlign = ContentAlignment.MiddleRight;
            Scan = new ThemedButton("Scan &Device...", ButtonKind.Secondary);
            Reports = new ThemedButton("Re&ports...", ButtonKind.Secondary);
            Refresh = new ThemedButton("Re&fresh Status", ButtonKind.Secondary);
            Header.Controls.AddRange(new Control[] { Logo, AppName, Subtitle, StatusTimestamp, Scan, Reports, Refresh });

            ProjectsTitle = Theme.NewLabel("Projects", 11f, FontStyle.Bold, Theme.Text);
            Add = new ThemedButton("&Add Project...", ButtonKind.Quiet);
            Projects = new StatusListView();
            Projects.ShowItemToolTips = true;
            Projects.AccessibleName = "Projects";
            Projects.AddColumn("Project", 220, CellKind.Project);
            Projects.AddColumn("Git", 250, CellKind.Chip);
            Projects.AddColumn("Local build", 150, CellKind.Chip);
            Projects.AddColumn("Device", 150, CellKind.Chip);
            Projects.AddColumn("Checked", 90, CellKind.Muted);
            ProjectsFrame = new BorderHost(Projects);
            EmptyMessage = Theme.NewLabel("No projects yet. Choose Add Project... to pick an Android repository or project folder, or drag a folder onto Build-And-Install-Android.bat.",
                10f, FontStyle.Regular, Theme.Muted);
            EmptyMessage.TextAlign = ContentAlignment.MiddleCenter;
            EmptyMessage.BackColor = Theme.Surface;
            EmptyMessage.Visible = false;

            Details = new CardPanel();
            DetailName = Theme.NewLabel("No project selected", 12f, FontStyle.Bold, Theme.Text);
            DetailPath = Theme.NewLabel(string.Empty, 9f, FontStyle.Regular, Theme.Muted);
            DetailPlan = Theme.NewLabel(string.Empty, 9.5f, FontStyle.Bold, Theme.Muted);
            DetailPlan.AccessibleName = "Sync and Run preview";
            DetailFix = Theme.NewLabel(string.Empty, 9f, FontStyle.Regular, Theme.Muted);
            DetailSettings = Theme.NewLabel(string.Empty, 9f, FontStyle.Regular, Theme.Muted);
            Build = new ThemedButton("&Build && Install", ButtonKind.Secondary);
            Sync = new ThemedButton("&Sync && Run", ButtonKind.Primary);
            GitPull = new ThemedButton("&Git Pull", ButtonKind.Quiet);
            InstallApk = new ThemedButton("Install &APK...", ButtonKind.Quiet);
            Settings = new ThemedButton("Se&ttings...", ButtonKind.Quiet);
            Remove = new ThemedButton("&Remove...", ButtonKind.Quiet);
            Details.Controls.AddRange(new Control[] { DetailName, DetailPath, DetailPlan, DetailFix, DetailSettings,
                                                      Build, Sync, GitPull, InstallApk, Settings, Remove });

            Operation = new CardPanel();
            OperationBadge = new Badge();
            OperationBadge.Text = "Idle";
            OperationTitle = Theme.NewLabel("Ready", 10.5f, FontStyle.Bold, Theme.Text);
            OperationTitle.AccessibleName = "Operation status";
            OperationStatus = Theme.NewLabel("Output from the next operation appears here.", 9f, FontStyle.Regular, Theme.Muted);
            CopyOutput = new ThemedButton("&Copy Output", ButtonKind.Quiet);
            CancelOperation = new ThemedButton("&Cancel", ButtonKind.Secondary);
            OperationProgress = new ActivityBar();
            OperationProgress.Visible = false;
            OperationOutput = new RichTextBox();
            OperationOutput.ReadOnly = true;
            OperationOutput.BorderStyle = BorderStyle.None;
            OperationOutput.BackColor = Theme.ConsoleBack;
            OperationOutput.ForeColor = Theme.Enabled ? Theme.Hex("#D5DEEA") : SystemColors.WindowText;
            OperationOutput.Font = new Font("Consolas", 9f);
            OperationOutput.WordWrap = false;
            OperationOutput.DetectUrls = false;
            OperationOutput.HideSelection = false;
            OperationOutput.AccessibleName = "Operation output";
            Theme.DarkScrollBars(OperationOutput);
            OperationOutputFrame = new BorderHost(OperationOutput);
            Operation.Controls.AddRange(new Control[] { OperationBadge, OperationTitle, OperationStatus, CopyOutput,
                                                        CancelOperation, OperationProgress, OperationOutputFrame });

            form.Controls.AddRange(new Control[] { Header, ProjectsTitle, Add, ProjectsFrame, EmptyMessage, Details, Operation });

            // Keyboard order: projects, primary actions, secondary actions, operation, header.
            int tab = 0;
            foreach (Control control in new Control[] { ProjectsFrame, Details, Operation, Add, Header })
            {
                control.TabIndex = tab++;
            }
            tab = 0;
            foreach (Control control in new Control[] { Sync, Build, GitPull, InstallApk, Settings, Remove })
            {
                control.TabIndex = tab++;
            }
            tab = 0;
            foreach (Control control in new Control[] { OperationOutputFrame, CopyOutput, CancelOperation })
            {
                control.TabIndex = tab++;
            }
            tab = 0;
            foreach (Control control in new Control[] { Refresh, Scan, Reports })
            {
                control.TabIndex = tab++;
            }
            SetOperationState("idle", "Ready", "Output from the next operation appears here.");
            SetMinimumClientSize(900, 680);
            form.Resize += delegate(object sender, EventArgs e) { LayoutDashboard(); };
        }

        private int S(double value) { return (int)Math.Round(value * scale); }

        // The layout is drawn in 96-dpi units scaled by the display, so the minimum
        // window size must scale too or buttons overlap at 125-200% scaling.
        public void SetMinimumClientSize(int width, int height)
        {
            scale = ThemedButton.DeviceScale(form);
            Size chrome = form.Size - form.ClientSize;
            form.MinimumSize = new Size(S(width) + chrome.Width, S(height) + chrome.Height);
            if (form.ClientSize.Width < S(width) || form.ClientSize.Height < S(height))
            {
                form.ClientSize = new Size(Math.Max(form.ClientSize.Width, S(width)), Math.Max(form.ClientSize.Height, S(height)));
            }
        }

        public void SetDetails(string name, string path, string plan, string planTone, string fix, string settings)
        {
            DetailName.Text = name ?? string.Empty;
            DetailPath.Text = path ?? string.Empty;
            DetailPlan.Text = plan ?? string.Empty;
            DetailPlan.ForeColor = string.IsNullOrEmpty(planTone) ? Theme.Muted : Theme.ToneText(planTone);
            DetailFix.Text = fix ?? string.Empty;
            DetailSettings.Text = settings ?? string.Empty;
            LayoutDashboard();
        }

        // state: idle, running, success, failed, cancelled, cancelling
        public void SetOperationState(string state, string title, string detail)
        {
            string tone = "neutral";
            string word = "Idle";
            switch (state)
            {
                case "running": tone = "action"; word = "Running"; break;
                case "cancelling": tone = "warn"; word = "Stopping"; break;
                case "success": tone = "ok"; word = "Done"; break;
                case "failed": tone = "error"; word = "Failed"; break;
                case "cancelled": tone = "warn"; word = "Cancelled"; break;
            }
            OperationBadge.Tone = tone;
            OperationBadge.Text = word;
            OperationBadge.AccessibleName = word;
            OperationTitle.Text = title ?? string.Empty;
            OperationStatus.Text = detail ?? string.Empty;
            OperationStatus.ForeColor = state == "failed" ? Theme.ToneText("error") : Theme.Muted;
            bool running = state == "running" || state == "cancelling";
            OperationProgress.Running = running;
            CancelOperation.Visible = running;
            LayoutDashboard();
        }

        public void ShowEmpty(bool empty)
        {
            EmptyMessage.Visible = empty;
            ProjectsFrame.Visible = !empty;
        }

        public void LayoutDashboard()
        {
            scale = ThemedButton.DeviceScale(form);
            int width = form.ClientSize.Width;
            int height = form.ClientSize.Height;
            if (width <= 0 || height <= 0) { return; }
            int margin = S(16);
            int gap = S(10);
            int buttonHeight = S(32);
            int inner = width - 2 * margin;

            // Header
            Header.SetBounds(0, 0, width, S(62));
            Logo.SetBounds(margin, S(14), S(34), S(34));
            AppName.SetBounds(Logo.Right + S(10), S(9), S(220), S(26));
            Subtitle.SetBounds(Logo.Right + S(10), S(34), S(300), S(18));
            int right = width - margin;
            foreach (ThemedButton button in new ThemedButton[] { Refresh, Reports, Scan })
            {
                int buttonWidth = S(button == Refresh ? 116 : 104);
                button.SetBounds(right - buttonWidth, S(15), buttonWidth, buttonHeight);
                right = button.Left - S(8);
            }
            StatusTimestamp.SetBounds(Subtitle.Right + gap, S(15), Math.Max(S(60), right - Subtitle.Right - 2 * gap), buttonHeight);

            // Projects title row
            int top = Header.Bottom + S(10);
            ProjectsTitle.SetBounds(margin, top, S(260), S(28));
            Add.SetBounds(width - margin - S(116), top - S(1), S(116), S(30));
            int listTop = ProjectsTitle.Bottom + S(6);

            // Bottom-up: operation card, then details card, then the list takes the rest.
            int operationHeight = Math.Max(S(168), (int)((height - listTop) * 0.34));
            int operationTop = height - margin - operationHeight;
            int detailsHeight = S(DetailFix.Text.Length > 0 ? 134 : 116);
            int detailsTop = operationTop - gap - detailsHeight;
            int listHeight = Math.Max(S(120), detailsTop - gap - listTop);
            ProjectsFrame.SetBounds(margin, listTop, inner, listHeight);
            EmptyMessage.SetBounds(margin, listTop, inner, listHeight);
            Projects.RowHeight = S(44);
            // Project takes the spare width; Checked (last) absorbs rounding and the scroll bar.
            int[] widths = { 0, inner < S(1000) ? 210 : 250, 150, 150, 90 };
            int fixedColumns = 0;
            for (int index = 1; index < Projects.Columns.Count - 1; index++)
            {
                Projects.Columns[index].Width = S(widths[index]);
                fixedColumns += S(widths[index]);
            }
            int scrollReserve = SystemInformation.VerticalScrollBarWidth;
            Projects.Columns[0].Width = Math.Max(S(160), inner - 2 - fixedColumns - S(widths[4]) - scrollReserve);
            Projects.FillLastColumn();

            // Details card
            Details.SetBounds(margin, detailsTop, inner, detailsHeight);
            int pad = S(14);
            int actionsWidth = S(400);
            int infoWidth = Math.Max(S(200), inner - 2 * pad - actionsWidth - gap);
            DetailName.SetBounds(pad, S(10), infoWidth, S(26));
            DetailPath.SetBounds(pad, DetailName.Bottom, infoWidth, S(18));
            DetailPlan.SetBounds(pad, DetailPath.Bottom + S(8), infoWidth, S(20));
            DetailFix.Visible = DetailFix.Text.Length > 0;
            DetailFix.SetBounds(pad, DetailPlan.Bottom, infoWidth, DetailFix.Visible ? S(18) : 0);
            DetailSettings.SetBounds(pad, (DetailFix.Visible ? DetailFix.Bottom : DetailPlan.Bottom) + S(2), infoWidth, S(18));

            int actionRight = inner - pad;
            Sync.SetBounds(actionRight - S(140), S(14), S(140), S(36));
            Build.SetBounds(Sync.Left - S(8) - S(140), S(14), S(140), S(36));
            int quietRight = actionRight;
            foreach (ThemedButton button in new ThemedButton[] { Remove, Settings, InstallApk, GitPull })
            {
                int buttonWidth = S(button == InstallApk ? 104 : 88);
                button.SetBounds(quietRight - buttonWidth, Sync.Bottom + S(10), buttonWidth, S(30));
                quietRight = button.Left - S(2);
            }

            // Operation card
            Operation.SetBounds(margin, operationTop, inner, operationHeight);
            OperationBadge.SetBounds(pad, S(13), S(84), S(24));
            Size titleSize = TextRenderer.MeasureText(OperationTitle.Text, OperationTitle.Font);
            OperationTitle.SetBounds(OperationBadge.Right + S(10), S(10), Math.Min(titleSize.Width + S(6), S(320)), S(30));
            CancelOperation.SetBounds(inner - pad - S(90), S(9), S(90), buttonHeight);
            int copyRight = CancelOperation.Visible ? CancelOperation.Left - S(6) : inner - pad;
            CopyOutput.SetBounds(copyRight - S(110), S(9), S(110), buttonHeight);
            OperationStatus.SetBounds(OperationTitle.Right + S(6), S(10), Math.Max(S(40), CopyOutput.Left - OperationTitle.Right - S(12)), S(30));
            OperationProgress.SetBounds(pad, S(46), inner - 2 * pad, S(3));
            int outputTop = S(54);
            OperationOutputFrame.SetBounds(pad, outputTop, inner - 2 * pad, Math.Max(S(40), operationHeight - outputTop - pad));
            Header.Invalidate();
        }
    }
}
