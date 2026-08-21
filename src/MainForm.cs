using System.Text;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace BackupS3Manager;

public sealed class MainForm : Form
{
    private readonly WebView2 _web = new() { Dock = DockStyle.Fill };
    private readonly ToolStripButton _reloadButton = new("Обновить Dashboard") { Enabled = false };
    private readonly ToolStrip _toolsStrip;
    private ApiBridge? _bridge;
    private bool _webReady;
    private bool _interfaceShown;
    private readonly SplashForm? _splash;
    private readonly System.Windows.Forms.Timer _schedulerTimer = new() { Interval = 1000 };
    private bool _schedulerTickRunning;
    private readonly NotifyIcon _trayIcon;
    private readonly bool _startBackground;
    private bool _allowExit;
    private readonly ToolStripMenuItem _traySummary = new("Сводка загружается…") { Enabled = false };
    private readonly ToolStripMenuItem _trayLastCheck = new("Последняя проверка: —") { Enabled = false };
    private readonly ToolStripMenuItem _trayAutomation = new("Автопроверка: —") { Enabled = false };
    private readonly ToolStripMenuItem _trayNextCheck = new("Следующая проверка: —") { Enabled = false };
    private readonly ToolStripMenuItem _trayStorage = new("Копии: —") { Enabled = false };
    private readonly ToolStripMenuItem _trayMode = new("Режим: —") { Enabled = false };
    private readonly ContextMenuStrip _trayMenu = new();

    internal MainForm(SplashForm? splash = null, bool startInBackground = false)
    {
        _splash = splash;
        _startBackground = startInBackground;
        _schedulerTimer.Tick += async (_, _) => await RunDueSchedulerAsync();
        Text = "Backup S3 Manager";
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
        Width = 1550;
        Height = 940;
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(1100, 700);
        if (_splash is not null || _startBackground)
        {
            Opacity = 0;
            ShowInTaskbar = false;
        }
        _trayMenu.Renderer = new BackupS3TrayRenderer();
        _trayMenu.BackColor = Color.FromArgb(17, 22, 29);
        _trayMenu.ForeColor = Color.FromArgb(225, 235, 247);
        _trayMenu.Font = new Font("Segoe UI", 10F, FontStyle.Regular);
        _trayMenu.Padding = new Padding(8, 7, 8, 7);
        _trayMenu.ShowImageMargin = true;
        _trayMenu.ShowCheckMargin = false;
        _trayMenu.Items.Add(new ToolStripMenuItem("BS3  ·  BackupS3 Manager")
        {
            Enabled = false,
            Font = new Font("Segoe UI Semibold", 11F, FontStyle.Bold),
            ForeColor = Color.FromArgb(66, 180, 255)
        });
        _trayMenu.Items.Add(new ToolStripSeparator());
        _trayMenu.Items.Add(_traySummary);
        _trayMenu.Items.Add(_trayStorage);
        _trayMenu.Items.Add(_trayLastCheck);
        _trayMenu.Items.Add(_trayAutomation);
        _trayMenu.Items.Add(_trayNextCheck);
        _trayMenu.Items.Add(_trayMode);
        foreach (var item in new[] { _traySummary, _trayStorage, _trayLastCheck, _trayAutomation, _trayNextCheck, _trayMode })
            item.ForeColor = Color.FromArgb(214, 228, 244);
        _trayMenu.Items.Add(new ToolStripSeparator());
        _trayMenu.Items.Add("Открыть BackupS3", CreateTrayGlyph(Color.FromArgb(66, 180, 255), "↗"), (_, _) => RestoreFromTray());
        _trayMenu.Items.Add("Проверить сейчас", CreateTrayGlyph(Color.FromArgb(65, 201, 142), "↻"), async (_, _) =>
        {
            if (_bridge is not null) await _bridge.HandleAsync("POST", new Uri("https://app.local/api/refresh"), "");
        });
        _trayMenu.Items.Add("Проверить обновления", CreateTrayGlyph(Color.FromArgb(126, 165, 255), "↓"), async (_, _) =>
        {
            if (_bridge is null) return;
            try
            {
                var result = await _bridge.HandleAsync("GET", new Uri("https://app.local/api/update/check"), "");
                var json = System.Text.Json.Nodes.JsonNode.Parse(result.Body)?.AsObject();
                var message = json?["message"]?.ToString() ?? json?["error"]?.ToString() ?? "Не удалось проверить обновления.";
                var available = json?["updateAvailable"]?.GetValue<bool>() == true;
                _trayIcon!.ShowBalloonTip(4000, available ? "Доступно обновление BackupS3" : "Обновления BackupS3", message,
                    available ? ToolTipIcon.Info : ToolTipIcon.None);
            }
            catch (Exception ex)
            {
                _trayIcon!.ShowBalloonTip(4000, "Ошибка проверки обновлений", ex.Message, ToolTipIcon.Warning);
            }
        });
        _trayMenu.Items.Add(new ToolStripSeparator());
        _trayMenu.Items.Add("Выход", CreateTrayGlyph(Color.FromArgb(255, 100, 112), "×"), (_, _) => { _allowExit = true; Close(); });
        _trayMenu.Opening += (_, _) => UpdateTraySummary();
        _trayIcon = new NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!),
            Text = "BS3 · BackupS3 Manager",
            Visible = true
        };
        _trayIcon.DoubleClick += (_, _) => RestoreFromTray();
        _trayIcon.MouseUp += (_, e) =>
        {
            if (e.Button != MouseButtons.Right) return;
            UpdateTraySummary();
            _trayMenu.Show(Cursor.Position, ToolStripDropDownDirection.AboveLeft);
        };
        _toolsStrip = new ToolStrip
        {
            GripStyle = ToolStripGripStyle.Hidden,
            Dock = DockStyle.Top,
            BackColor = Color.FromArgb(24, 30, 38),
            ForeColor = Color.Gainsboro,
            Padding = new Padding(6, 3, 6, 3),
            Visible = false
        };

        var diagnosticsButton = new ToolStripButton("Диагностика");
        diagnosticsButton.Click += (_, _) =>
        {
            using var dialog = new DiagnosticsForm(startupMode: false);
            dialog.ShowDialog(this);
        };

        _reloadButton.Click += async (_, _) =>
        {
            try
            {
                _reloadButton.Enabled = false;
                await RefreshDashboardAsync();
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Ошибка обновления",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                _reloadButton.Enabled = _webReady;
            }
        };

        _toolsStrip.Items.Add(diagnosticsButton);
        _toolsStrip.Items.Add(_reloadButton);

        Controls.Add(_web);
        Controls.Add(_toolsStrip);
        _toolsStrip.BringToFront();

        Load += async (_,_) =>
        {
            try
            {
                await InitializeAsync();
            }
            catch (Exception ex)
            {
                await RevealInterfaceAsync();
                Text = "Backup S3 Manager — ошибка запуска WebView2";
                MessageBox.Show(
                    "Не удалось инициализировать интерфейс WebView2.\r\n\r\n" + ex.Message +
                    "\r\n\r\nПроверьте наличие папки WebView2Runtime рядом с EXE " +
                    "или установленного Microsoft Edge WebView2 Runtime.",
                    "Ошибка WebView2", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        };
        FormClosing += (_, e) =>
        {
            if (!_allowExit && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                HideToTray(showNotice: true);
            }
        };
        FormClosed += (_,_) => { _schedulerTimer.Dispose(); _trayIcon.Visible = false; _trayIcon.Dispose(); _trayMenu.Dispose(); };
    }

    private static Bitmap CreateTrayGlyph(Color color, string text)
    {
        var bitmap = new Bitmap(24, 24);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using var background = new SolidBrush(Color.FromArgb(42, color));
        using var foreground = new SolidBrush(color);
        graphics.FillEllipse(background, 1, 1, 22, 22);
        using var font = new Font("Segoe UI Symbol", 11F, FontStyle.Bold, GraphicsUnit.Pixel);
        var size = graphics.MeasureString(text, font);
        graphics.DrawString(text, font, foreground, (24 - size.Width) / 2F, (24 - size.Height) / 2F - 1F);
        return bitmap;
    }

    private sealed class BackupS3TrayRenderer : ToolStripProfessionalRenderer
    {
        public BackupS3TrayRenderer() : base(new BackupS3TrayColors()) { RoundedEdges = true; }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            if (!e.Item.Enabled)
            {
                TextRenderer.DrawText(e.Graphics, e.Text, e.Item.Font, e.TextRectangle,
                    e.Item.ForeColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
                return;
            }
            base.OnRenderItemText(e);
        }
    }

    private sealed class BackupS3TrayColors : ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground => Color.FromArgb(17, 22, 29);
        public override Color ImageMarginGradientBegin => Color.FromArgb(17, 22, 29);
        public override Color ImageMarginGradientMiddle => Color.FromArgb(17, 22, 29);
        public override Color ImageMarginGradientEnd => Color.FromArgb(17, 22, 29);
        public override Color MenuItemSelected => Color.FromArgb(27, 63, 88);
        public override Color MenuItemBorder => Color.FromArgb(55, 143, 197);
        public override Color SeparatorDark => Color.FromArgb(47, 59, 73);
        public override Color SeparatorLight => Color.FromArgb(47, 59, 73);
        public override Color ToolStripBorder => Color.FromArgb(52, 66, 82);
    }

    private void RestoreFromTray()
    {
        Show();
        ShowInTaskbar = true;
        WindowState = FormWindowState.Normal;
        Opacity = 1;
        Activate();
        BringToFront();
    }

    private void HideToTray(bool showNotice)
    {
        ShowInTaskbar = false;
        Hide();
        if (showNotice)
            _trayIcon.ShowBalloonTip(2500, "BackupS3 работает в фоне", "Открыть приложение можно двойным щелчком по значку BS3.", ToolTipIcon.Info);
    }

    private void UpdateTraySummary()
    {
        try
        {
            var state = File.Exists(AppPaths.StatePath)
                ? System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(AppPaths.StatePath))?.AsObject()
                : null;
            var jobs = state?["Jobs"]?.AsArray();
            var total = jobs?.Count ?? 0;
            var errors = jobs?.Count(x => x?["Status"]?.ToString() == "ERROR") ?? 0;
            var running = File.Exists(AppPaths.ControllerStatePath) ? " · идёт проверка" : "";
            _traySummary.Text = $"Баз: {total} · ошибок: {errors}{running}";
            _traySummary.ForeColor = errors > 0 ? Color.FromArgb(255, 132, 142) : Color.FromArgb(95, 224, 157);
            var localFiles = jobs?.Sum(x => int.TryParse(x?["LocalFileCount"]?.ToString(), out var value) ? value : 0) ?? 0;
            var s3Objects = jobs?.Sum(x => int.TryParse(x?["S3ObjectCount"]?.ToString(), out var value) ? value : 0) ?? 0;
            _trayStorage.Text = $"Копии: локально {localFiles} · в S3 {s3Objects}";
            _trayStorage.ForeColor = Color.FromArgb(105, 195, 255);
            var generatedAt = state?["GeneratedAt"]?.ToString();
            _trayLastCheck.Text = DateTimeOffset.TryParse(generatedAt, out var checkedAt)
                ? $"Последняя проверка: {checkedAt.LocalDateTime:dd.MM.yyyy HH:mm}"
                : "Последняя проверка: ещё не выполнялась";
            _trayLastCheck.ForeColor = Color.FromArgb(201, 216, 235);

            var settings = File.Exists(AppPaths.SettingsPath)
                ? System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(AppPaths.SettingsPath))?.AsObject()
                : null;
            var automatic = settings?["AutoSchedulerEnabled"]?.GetValue<bool>() == true;
            var interval = settings?["AutoSchedulerIntervalMinutes"]?.GetValue<int>() ?? 2;
            _trayAutomation.Text = automatic ? $"Автопроверка: каждые {interval} мин." : "Автопроверка: выключена";
            _trayAutomation.ForeColor = automatic ? Color.FromArgb(102, 222, 158) : Color.FromArgb(244, 193, 92);
            _trayMode.Text = settings?["SafeMode"]?.GetValue<bool>() == false
                ? "Режим: рабочий · загрузка разрешена"
                : "Режим: безопасный";
            _trayMode.ForeColor = settings?["SafeMode"]?.GetValue<bool>() == false
                ? Color.FromArgb(255, 143, 151) : Color.FromArgb(105, 195, 255);

            var scheduler = File.Exists(AppPaths.SchedulerStatePath)
                ? System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(AppPaths.SchedulerStatePath))?.AsObject()
                : null;
            _trayNextCheck.Text = automatic && DateTimeOffset.TryParse(scheduler?["nextRunAt"]?.ToString(), out var nextRun)
                ? $"Следующая проверка: {nextRun.LocalDateTime:dd.MM.yyyy HH:mm}"
                : "Следующая проверка: не запланирована";
            _trayNextCheck.ForeColor = automatic ? Color.FromArgb(239, 204, 118) : Color.FromArgb(161, 177, 198);

            var tooltip = $"BS3 · баз {total}, ошибок {errors}" + running;
            _trayIcon.Text = tooltip[..Math.Min(63, tooltip.Length)];
        }
        catch { _traySummary.Text = "Сводка временно недоступна"; }
    }

    private async Task InitializeAsync()
    {
        AppLog.Info("Инициализация WebView2 и Dashboard");
        var userData = Path.Combine(AppPaths.DataRoot, "WebView2");
        Directory.CreateDirectory(userData);

        // Prefer the bundled Fixed Version Runtime so the portable build does
        // not depend on a separately installed Evergreen WebView2 Runtime.
        var browserExecutableFolder = AppPaths.BundledWebView2RuntimeOrNull;
        var env = await CoreWebView2Environment.CreateAsync(browserExecutableFolder, userData);
        await _web.EnsureCoreWebView2Async(env);

        _bridge = new ApiBridge(BrowseFolderAsync);
        _schedulerTimer.Start();

        _web.CoreWebView2.Settings.AreDevToolsEnabled = false;
        _web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
        _web.CoreWebView2.Settings.IsStatusBarEnabled = false;

        _web.CoreWebView2.SetVirtualHostNameToFolderMapping(
            "app.local",
            AppPaths.WebDir,
            CoreWebView2HostResourceAccessKind.Allow);

        // v23.05: /api/* no longer uses WebResourceRequested.
        // WebView2 fetch requests are bridged through chrome.webview.postMessage,
        // so there is no TCP listener, no localhost and no "Failed to fetch".
        await _web.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(ApiFetchShim);
        _web.CoreWebView2.WebMessageReceived += WebMessageReceived;

        _web.CoreWebView2.DownloadStarting += (_, e) =>
        {
            var downloads = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "Downloads");
            Directory.CreateDirectory(downloads);
            var name = Path.GetFileName(e.ResultFilePath);
            e.ResultFilePath = Path.Combine(downloads, name);
        };

        _web.CoreWebView2.NavigationCompleted += async (_, e) =>
        {
            if (!e.IsSuccess)
            {
                Text = $"Backup S3 Manager — ошибка WebView2: {e.WebErrorStatus}";
                AppLog.Warn($"Навигация WebView2 завершилась с ошибкой: {e.WebErrorStatus}");
            }
            else
            {
                Text = "Backup S3 Manager";
                AppLog.Info("Dashboard загружен и готов к работе");
                await RevealInterfaceAsync();
            }
        };

        _webReady = true;
        _reloadButton.Enabled = true;
        NavigateHome();
    }

    private async Task RunDueSchedulerAsync()
    {
        if (_schedulerTickRunning || _bridge is null) return;
        _schedulerTickRunning = true;
        try
        {
            if (!File.Exists(AppPaths.SettingsPath) || !File.Exists(AppPaths.SchedulerStatePath)) return;
            var settings = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(AppPaths.SettingsPath))?.AsObject();
            if (settings?["AutoSchedulerEnabled"]?.GetValue<bool>() != true) return;
            var state = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(AppPaths.SchedulerStatePath))?.AsObject();
            if (!DateTimeOffset.TryParse(state?["nextRunAt"]?.ToString(), out var next) || next > DateTimeOffset.Now) return;
            AppLog.Info("Наступило время встроенной автоматической проверки");
            await _bridge.HandleAsync("POST", new Uri("https://app.local/api/scheduler/run"), "");
        }
        catch (Exception ex)
        {
            AppLog.Warn("Ошибка встроенного планировщика: " + ex.Message);
        }
        finally { _schedulerTickRunning = false; }
    }

    private async Task RevealInterfaceAsync()
    {
        if (_interfaceShown) return;
        _interfaceShown = true;
        if (_startBackground)
        {
            Opacity = 1;
            HideToTray(showNotice: false);
            AppLog.Info("BackupS3 Manager запущен в фоновом режиме");
            return;
        }
        if (_splash is not null && !_splash.IsDisposed)
            await _splash.WaitForMinimumDisplayAsync();
        Opacity = 1;
        ShowInTaskbar = true;
        Activate();
        if (_splash is not null && !_splash.IsDisposed) _splash.Close();
    }

    private async Task RefreshDashboardAsync()
    {
        if (!_webReady || _web.CoreWebView2 is null)
            throw new InvalidOperationException("Интерфейс WebView2 ещё загружается. Повторите обновление через несколько секунд.");

        await Task.Run(AppPaths.GenerateDashboard);
        _web.Source = new Uri($"https://app.local/index.html?t={DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
    }

    private void NavigateHome()
    {
        AppPaths.GenerateDashboard();
        _web.Source = new Uri("https://app.local/index.html");
    }

    private const string ApiFetchShim = """
(() => {
    if (window.__backupS3DesktopFetchInstalled) return;
    window.__backupS3DesktopFetchInstalled = true;

    const nativeFetch = window.fetch.bind(window);
    const pending = new Map();
    let sequence = 0;

    function base64ToBytes(base64) {
        if (!base64) return new Uint8Array(0);
        const bin = atob(base64);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        return bytes;
    }

    window.__backupS3ApiResolve = function(message) {
        const item = pending.get(message.id);
        if (!item) return;
        pending.delete(message.id);

        try {
            const headers = new Headers(message.headers || {});
            const response = new Response(base64ToBytes(message.bodyBase64 || ''), {
                status: Number(message.status || 500),
                statusText: message.reason || '',
                headers
            });
            item.resolve(response);
        } catch (e) {
            item.reject(e);
        }
    };

    window.__backupS3ApiReject = function(id, error) {
        const item = pending.get(id);
        if (!item) return;
        pending.delete(id);
        item.reject(new Error(error || 'Desktop API error'));
    };

    window.fetch = function(input, init) {
        init = init || {};

        let url;
        let method = String(init.method || 'GET').toUpperCase();
        let body = init.body == null ? '' : String(init.body);

        if (input instanceof Request) {
            url = input.url;
            method = String(init.method || input.method || 'GET').toUpperCase();
        } else {
            url = new URL(String(input), window.location.href).href;
        }

        const parsed = new URL(url);
        if (parsed.origin !== window.location.origin ||
            !parsed.pathname.startsWith('/api/')) {
            return nativeFetch(input, init);
        }

        const id = `${Date.now()}-${++sequence}-${Math.random().toString(16).slice(2)}`;

        return new Promise((resolve, reject) => {
            pending.set(id, { resolve, reject });
            try {
                chrome.webview.postMessage({
                    type: 'api',
                    id,
                    method,
                    url: parsed.pathname + parsed.search,
                    body
                });
            } catch (e) {
                pending.delete(id);
                reject(e);
            }
        });
    };
})();
""";

    private async void WebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (_bridge is null) return;

        string id = "";
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(e.WebMessageAsJson);
            var root = doc.RootElement;

            if (root.TryGetProperty("type", out var commandType) &&
                string.Equals(commandType.GetString(), "toggle-tools", StringComparison.Ordinal))
            {
                _toolsStrip.Visible = !_toolsStrip.Visible;
                AppLog.Info(_toolsStrip.Visible ? "Служебная панель открыта" : "Служебная панель скрыта");
                return;
            }

            if (!root.TryGetProperty("type", out var typeElement) ||
                !string.Equals(typeElement.GetString(), "api", StringComparison.Ordinal))
                return;

            id = root.GetProperty("id").GetString() ?? "";
            var method = root.GetProperty("method").GetString() ?? "GET";
            var relativeUrl = root.GetProperty("url").GetString() ?? "/api/health";
            var body = root.TryGetProperty("body", out var bodyElement)
                ? bodyElement.GetString() ?? ""
                : "";

            var uri = new Uri(new Uri("https://app.local"), relativeUrl);
            var result = await _bridge.HandleAsync(method, uri, body);
            if (!method.Equals("GET", StringComparison.OrdinalIgnoreCase))
                AppLog.Info($"API {method} {uri.AbsolutePath} → HTTP {result.StatusCode}");

            var responseHeaders = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase)
            {
                ["Content-Type"] = result.ContentType,
                ["Cache-Control"] = "no-store"
            };

            if (!string.IsNullOrWhiteSpace(result.ExtraHeaders))
            {
                foreach (var line in result.ExtraHeaders
                    .Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
                {
                    var pos = line.IndexOf(':');
                    if (pos > 0)
                        responseHeaders[line[..pos].Trim()] = line[(pos + 1)..].Trim();
                }
            }

            var payload = System.Text.Json.JsonSerializer.Serialize(new
            {
                id,
                status = result.StatusCode,
                reason = result.Reason,
                headers = responseHeaders,
                bodyBase64 = Convert.ToBase64String(result.Body)
            });

            await _web.CoreWebView2.ExecuteScriptAsync(
                $"window.__backupS3ApiResolve({payload});");

            if (result.StatusCode is >= 200 and < 300 &&
                !string.Equals(method, "GET", StringComparison.OrdinalIgnoreCase) &&
                !uri.AbsolutePath.Equals("/api/cancel", StringComparison.OrdinalIgnoreCase))
            {
                _ = Task.Run(() =>
                {
                    try { AppPaths.GenerateDashboard(); } catch { }
                });
            }
        }
        catch (Exception ex)
        {
            AppLog.Error("Ошибка обработки запроса desktop API", ex);
            if (!string.IsNullOrWhiteSpace(id))
            {
                var idJson = System.Text.Json.JsonSerializer.Serialize(id);
                var errorJson = System.Text.Json.JsonSerializer.Serialize(ex.Message);
                try
                {
                    await _web.CoreWebView2.ExecuteScriptAsync(
                        $"window.__backupS3ApiReject({idJson},{errorJson});");
                }
                catch { }
            }
        }
    }

    private Task<string?> BrowseFolderAsync(string? initial)
    {
        var tcs = new TaskCompletionSource<string?>();
        BeginInvoke(() =>
        {
            using var dlg = new FolderBrowserDialog
            {
                Description = "Выберите локальную папку backup",
                UseDescriptionForTitle = true,
                SelectedPath = Directory.Exists(initial) ? initial : AppPaths.DataRoot,
                ShowNewFolderButton = false
            };
            tcs.SetResult(dlg.ShowDialog(this) == DialogResult.OK ? dlg.SelectedPath : null);
        });
        return tcs.Task;
    }
}
