using System.Diagnostics;
using System.Drawing.Drawing2D;

namespace BackupS3Manager;

internal sealed class SplashForm : Form
{
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 16 };
    private readonly Stopwatch _watch = Stopwatch.StartNew();
    private readonly Bitmap _logo;

    public SplashForm()
    {
        var logoPath = Path.Combine(AppContext.BaseDirectory, "Assets", "BackupS3-Login.png");
        using (var loaded = Image.FromFile(logoPath)) _logo = new Bitmap(loaded);

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(520, 540);
        BackColor = Color.Black;
        ShowInTaskbar = false;
        TopMost = true;
        DoubleBuffered = true;

        Region = Region.FromHrgn(CreateRoundRectRgn(0, 0, Width + 1, Height + 1, 30, 30));
        _timer.Tick += (_, _) => Invalidate();
        Shown += (_, _) => _timer.Start();
        FormClosed += (_, _) => { _timer.Dispose(); _logo.Dispose(); };
    }

    public async Task WaitForMinimumDisplayAsync()
    {
        var remaining = 1450 - (int)_watch.ElapsedMilliseconds;
        if (remaining > 0) await Task.Delay(remaining);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        g.DrawImage(_logo, new Rectangle(20, 5, 480, 480));

        // The only animation: a cyan loading pulse follows the icon's inner frame.
        var frame = new RectangleF(55, 40, 410, 410);
        const float radius = 42f;
        var perimeter = 2f * (frame.Width + frame.Height - 4f * radius) + 2f * MathF.PI * radius;
        var head = (float)(_watch.Elapsed.TotalSeconds * 235d % perimeter);
        for (var index = 20; index >= 0; index--)
        {
            var distance = head - index * 5.2f;
            while (distance < 0) distance += perimeter;
            var point = PointOnRoundedFrame(frame, radius, distance);
            var strength = 1f - index / 21f;
            var alpha = (int)(20 + 210 * strength * strength);
            var diameter = 3.5f + 5.5f * strength;
            using var glow = new SolidBrush(Color.FromArgb(alpha, 55, 205, 255));
            g.FillEllipse(glow, point.X - diameter / 2, point.Y - diameter / 2, diameter, diameter);
        }

        using var statusFont = new Font("Segoe UI", 10.5f, FontStyle.Regular, GraphicsUnit.Point);
        using var statusBrush = new SolidBrush(Color.FromArgb(151, 178, 205));
        const string status = "Загрузка BackupS3…";
        var size = g.MeasureString(status, statusFont);
        g.DrawString(status, statusFont, statusBrush, (Width - size.Width) / 2f, 497);
    }

    private static PointF PointOnRoundedFrame(RectangleF r, float radius, float distance)
    {
        var horizontal = r.Width - 2 * radius;
        var vertical = r.Height - 2 * radius;
        var arc = MathF.PI * radius / 2f;
        var sections = new[] { horizontal, arc, vertical, arc, horizontal, arc, vertical, arc };
        var d = distance;
        var section = 0;
        while (section < sections.Length - 1 && d > sections[section]) d -= sections[section++];

        return section switch
        {
            0 => new PointF(r.Left + radius + d, r.Top),
            1 => ArcPoint(r.Right - radius, r.Top + radius, radius, -90 + 90 * d / arc),
            2 => new PointF(r.Right, r.Top + radius + d),
            3 => ArcPoint(r.Right - radius, r.Bottom - radius, radius, 90 * d / arc),
            4 => new PointF(r.Right - radius - d, r.Bottom),
            5 => ArcPoint(r.Left + radius, r.Bottom - radius, radius, 90 + 90 * d / arc),
            6 => new PointF(r.Left, r.Bottom - radius - d),
            _ => ArcPoint(r.Left + radius, r.Top + radius, radius, 180 + 90 * d / arc)
        };
    }

    private static PointF ArcPoint(float cx, float cy, float radius, float degrees)
    {
        var radians = degrees * MathF.PI / 180f;
        return new PointF(cx + radius * MathF.Cos(radians), cy + radius * MathF.Sin(radians));
    }

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);
}
