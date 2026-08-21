using System.Diagnostics;

namespace BackupS3Manager;

internal sealed class DiagnosticsForm : Form
{
    private readonly ListView _list = new()
    {
        Dock = DockStyle.Fill,
        View = View.Details,
        FullRowSelect = true,
        GridLines = false,
        HideSelection = false
    };

    private readonly Label _summary = new()
    {
        Dock = DockStyle.Top,
        Height = 58,
        Padding = new Padding(14, 12, 14, 8),
        Font = new Font("Segoe UI", 10, FontStyle.Bold)
    };

    private readonly Button _retry = new() { Text = "Проверить снова", AutoSize = true };
    private readonly Button _copy = new() { Text = "Копировать отчёт", AutoSize = true };
    private readonly Button _logs = new() { Text = "Открыть Logs", AutoSize = true };
    private readonly Button _continue = new() { Text = "Продолжить", AutoSize = true };
    private readonly Button _exit = new() { Text = "Выход", AutoSize = true };

    private DiagnosticReport? _report;
    private readonly bool _startupMode;

    public bool ContinueRequested { get; private set; }

    public DiagnosticsForm(bool startupMode)
    {
        _startupMode = startupMode;

        Text = startupMode ? "Backup S3 Manager — проверка запуска" : "Backup S3 Manager — диагностика";
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
        Width = 980;
        Height = 650;
        MinimumSize = new Size(760, 480);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(17, 21, 27);
        ForeColor = Color.Gainsboro;
        Font = new Font("Segoe UI", 9F);

        _list.BackColor = Color.FromArgb(24, 30, 38);
        _list.ForeColor = Color.Gainsboro;
        _list.BorderStyle = BorderStyle.FixedSingle;
        _list.HeaderStyle = ColumnHeaderStyle.Nonclickable;
        _list.Columns.Add("Статус", 90);
        _list.Columns.Add("Проверка", 240);
        _list.Columns.Add("Результат", 570);

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            Height = 54,
            FlowDirection = FlowDirection.RightToLeft,
            Padding = new Padding(10),
            WrapContents = false
        };

        buttons.Controls.Add(_continue);
        if (startupMode) buttons.Controls.Add(_exit);
        buttons.Controls.Add(_retry);
        buttons.Controls.Add(_copy);
        buttons.Controls.Add(_logs);
        buttons.BackColor = Color.FromArgb(18, 23, 29);

        foreach (var button in new[] { _retry, _copy, _logs, _continue, _exit })
        {
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderColor = Color.FromArgb(62, 82, 101);
            button.BackColor = Color.FromArgb(27, 49, 67);
            button.ForeColor = Color.FromArgb(225, 239, 250);
            button.Padding = new Padding(8, 4, 8, 4);
        }
        _continue.BackColor = Color.FromArgb(24, 83, 116);
        _continue.FlatAppearance.BorderColor = Color.FromArgb(64, 143, 191);
        _exit.BackColor = Color.FromArgb(75, 36, 42);

        Controls.Add(_list);
        Controls.Add(_summary);
        Controls.Add(buttons);

        _retry.Click += async (_, _) => await RefreshChecksAsync();
        _copy.Click += (_, _) =>
        {
            if (_report is not null) Clipboard.SetText(_report.ToPlainText());
        };
        _logs.Click += (_, _) =>
        {
            Directory.CreateDirectory(AppPaths.LogsDir);
            Process.Start(new ProcessStartInfo("explorer.exe", AppPaths.LogsDir) { UseShellExecute = true });
        };
        _continue.Click += (_, _) =>
        {
            ContinueRequested = true;
            DialogResult = DialogResult.OK;
            Close();
        };
        _exit.Click += (_, _) =>
        {
            ContinueRequested = false;
            DialogResult = DialogResult.Cancel;
            Close();
        };

        Shown += async (_, _) => await RefreshChecksAsync();
    }

    private async Task RefreshChecksAsync()
    {
        ToggleButtons(false);
        _summary.Text = "Выполняю автоматическую диагностику…";
        _list.Items.Clear();

        try
        {
            _report = await StartupDiagnostics.RunAsync();

            foreach (var item in _report.Items)
            {
                var status = item.Level switch
                {
                    CheckLevel.Ok => "ГОТОВО",
                    CheckLevel.Warning => "ВНИМАНИЕ",
                    _ => "ОШИБКА"
                };

                var row = new ListViewItem(status);
                row.SubItems.Add(item.Name);
                row.SubItems.Add(item.Message + (string.IsNullOrWhiteSpace(item.Details) ? "" : "  |  " + item.Details));
                row.ForeColor = item.Level switch
                {
                    CheckLevel.Ok => Color.LightGreen,
                    CheckLevel.Warning => Color.Khaki,
                    _ => Color.LightCoral
                };
                _list.Items.Add(row);
            }

            _summary.Text =
                $"Диагностика завершена: готово {_report.Ok} · предупреждений {_report.Warnings} · ошибок {_report.Errors}" +
                (_report.Errors == 0
                    ? " — приложение готово к запуску."
                    : " — ошибки выделены красным.");

            // We allow Continue even with errors because missing K:\ paths or AWS
            // credentials may be intentional on a test PC. The user sees all of them first.
            _continue.Enabled = true;

            try
            {
                Directory.CreateDirectory(AppPaths.LogsDir);
                File.WriteAllText(
                    Path.Combine(AppPaths.LogsDir, "startup-diagnostics.txt"),
                    _report.ToPlainText(),
                    new System.Text.UTF8Encoding(true));
            }
            catch { }
        }
        catch (Exception ex)
        {
            _summary.Text = "Диагностика завершилась внутренней ошибкой: " + ex.Message;
            _continue.Enabled = true;
        }
        finally
        {
            ToggleButtons(true);
        }
    }

    private void ToggleButtons(bool enabled)
    {
        _retry.Enabled = enabled;
        _copy.Enabled = enabled;
        _logs.Enabled = enabled;
        if (enabled) _continue.Enabled = true;
    }
}
