using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BackupS3Agent;

internal sealed class SetupForm : Form
{
    private readonly TextBox _manager = new() { PlaceholderText = "http://ITL-MPC8:17831" };
    private readonly TextBox _name = new() { Text = Environment.MachineName };
    private readonly TextBox _code = new() { CharacterCasing = CharacterCasing.Upper };
    private readonly Label _status = new() { AutoSize = true, ForeColor = Color.FromArgb(147, 168, 190) };
    private readonly Button _test = new() { Text = "Проверить соединение", AutoSize = true };
    private readonly Button _install = new() { Text = "Подключить и установить", AutoSize = true };
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(8) };

    public SetupForm()
    {
        Text = "BackupS3 Agent — подключение сервера";
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
        BackColor = Color.FromArgb(11, 15, 21); ForeColor = Color.FromArgb(232, 241, 251); Font = new Font("Segoe UI", 10F);
        ClientSize = new Size(650, 535); MinimumSize = new Size(620, 520); StartPosition = FormStartPosition.CenterScreen;
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(28), ColumnCount = 1, AutoScroll = true, BackColor = BackColor };
        root.Controls.Add(new Label { Text = "BS3   BackupS3 Agent", AutoSize = true, Font = new Font("Segoe UI Semibold", 19F, FontStyle.Bold), ForeColor = Color.FromArgb(74, 188, 255), Margin = new Padding(0, 0, 0, 6) });
        root.Controls.Add(new Label { Text = "Подключение этого сервера к BackupS3 Manager", AutoSize = true, ForeColor = Color.FromArgb(164, 183, 204), Margin = new Padding(0, 0, 0, 18) });
        AddField(root, "Адрес BackupS3 Manager", _manager, "Например: http://192.168.1.20:17831");
        AddField(root, "Название этого сервера", _name, "Если оставить пустым, будет использован Host: " + Environment.MachineName);
        AddField(root, "Код подключения", _code, "Скопируйте код из раздела «Агенты» в Manager.");
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 16, 0, 9) };
        StyleButton(_test, false); StyleButton(_install, true); buttons.Controls.Add(_test); buttons.Controls.Add(_install); root.Controls.Add(buttons); root.Controls.Add(_status);
        Controls.Add(root); AcceptButton = _install;
        _test.Click += async (_, _) => await TestAsync(); _install.Click += async (_, _) => await InstallAsync();
        var embedded = EmbeddedConfiguration.Read();
        if (embedded is not null)
        {
            _manager.Text = embedded.ManagerUrl;
            _name.Text = embedded.DisplayName;
            _code.Text = embedded.EnrollmentCode;
            _status.Text = "Персональный агент подготовлен Manager. Проверьте данные и нажмите «Подключить и установить».";
        }
    }

    private static void AddField(TableLayoutPanel root, string label, Control input, string hint)
    {
        root.Controls.Add(new Label { Text = label, AutoSize = true, Font = new Font("Segoe UI Semibold", 10F, FontStyle.Bold), Margin = new Padding(0, 8, 0, 6) });
        input.Dock = DockStyle.Top; input.Height = 35; input.BackColor = Color.FromArgb(18, 25, 33); input.ForeColor = Color.FromArgb(235, 244, 255); input.Margin = new Padding(0, 0, 0, 4); root.Controls.Add(input);
        root.Controls.Add(new Label { Text = hint, AutoSize = true, ForeColor = Color.FromArgb(127, 149, 173), Margin = new Padding(0, 0, 0, 8) });
    }

    private static void StyleButton(Button button, bool primary)
    {
        button.FlatStyle = FlatStyle.Flat; button.Padding = new Padding(12, 6, 12, 6); button.Margin = new Padding(0, 0, 10, 0); button.BackColor = primary ? Color.FromArgb(25, 84, 122) : Color.FromArgb(24, 32, 42); button.ForeColor = Color.White; button.FlatAppearance.BorderColor = primary ? Color.FromArgb(62, 150, 205) : Color.FromArgb(60, 75, 91);
    }

    private AgentConfiguration ReadConfiguration()
    {
        var manager = _manager.Text.Trim().TrimEnd('/');
        if (!Uri.TryCreate(manager, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")) throw new InvalidDataException("Укажите корректный адрес Manager.");
        if (string.IsNullOrWhiteSpace(_code.Text)) throw new InvalidDataException("Введите код подключения.");
        var embedded = EmbeddedConfiguration.Read();
        return new AgentConfiguration { ManagerUrl = manager, EnrollmentCode = _code.Text.Trim(), DisplayName = string.IsNullOrWhiteSpace(_name.Text) ? Environment.MachineName : _name.Text.Trim(), PollSeconds = 15, ListenPort = embedded?.ListenPort ?? 17832 };
    }

    private async Task TestAsync()
    {
        try { var config = ReadConfiguration(); SetBusy(true, "Проверяю соединение…"); using var response = await _http.GetAsync(config.ManagerUrl + "/agent/health"); response.EnsureSuccessStatusCode(); _status.ForeColor = Color.FromArgb(76, 211, 146); _status.Text = "✓ Manager доступен. Можно устанавливать агент."; }
        catch (Exception ex) { _status.ForeColor = Color.FromArgb(255, 112, 124); _status.Text = "Ошибка: " + ex.Message; }
        finally { SetBusy(false, _status.Text); }
    }

    private async Task InstallAsync()
    {
        try { var config = ReadConfiguration(); SetBusy(true, "Проверяю код и регистрирую агент…"); await EnrollAsync(config); _status.Text = "Код принят. Запрашиваю права администратора…"; AgentInstaller.RequestElevatedInstall(config); _status.ForeColor = Color.FromArgb(76, 211, 146); _status.Text = "✓ Агент установлен. Он появится в Manager в течение 15 секунд."; }
        catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223) { _status.Text = "Установка отменена пользователем."; }
        catch (Exception ex) { _status.ForeColor = Color.FromArgb(255, 112, 124); _status.Text = "Ошибка: " + ex.Message; }
        finally { SetBusy(false, _status.Text); }
    }

    private async Task EnrollAsync(AgentConfiguration config)
    {
        var payload = new { enrollmentCode = config.EnrollmentCode, host = Environment.MachineName, displayName = config.DisplayName, version = "1.0.0" };
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload));
        using var content = new ByteArrayContent(bytes); content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json") { CharSet = "utf-8" };
        using var response = await _http.PostAsync(config.ManagerUrl + "/agent/enroll", content);
        var text = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode) { try { text = JsonNode.Parse(text)?["error"]?.ToString() ?? text; } catch { } throw new InvalidOperationException(text); }
        var result = JsonNode.Parse(text)?.AsObject() ?? throw new InvalidDataException("Manager вернул пустой ответ.");
        config.AgentId = result["agentId"]?.ToString() ?? throw new InvalidDataException("Manager не вернул ID агента.");
        config.Token = result["token"]?.ToString() ?? throw new InvalidDataException("Manager не вернул токен агента.");
        // Код сохраняется для автоматического восстановления регистрации, если Manager
        // был переустановлен или его файл agents.json восстановили из резервной копии.
    }

    private void SetBusy(bool busy, string text) { _test.Enabled = !busy; _install.Enabled = !busy; _status.Text = text; Application.DoEvents(); }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); try { var enabled = 1; DwmSetWindowAttribute(Handle, 20, ref enabled, 4); var caption = 0x0015100B; DwmSetWindowAttribute(Handle, 35, ref caption, 4); } catch { } }
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}
