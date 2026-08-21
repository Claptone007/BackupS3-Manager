using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BackupS3Manager;

internal enum CheckLevel
{
    Ok,
    Warning,
    Error
}

internal sealed record DiagnosticItem(
    string Name,
    CheckLevel Level,
    string Message,
    string? Details = null);

internal sealed class DiagnosticReport
{
    public List<DiagnosticItem> Items { get; } = new();

    public int Errors => Items.Count(x => x.Level == CheckLevel.Error);
    public int Warnings => Items.Count(x => x.Level == CheckLevel.Warning);
    public int Ok => Items.Count(x => x.Level == CheckLevel.Ok);
    public bool HasFatalErrors => Errors > 0;

    public string ToPlainText()
    {
        var sb = new StringBuilder();
        sb.AppendLine("Backup S3 Manager v23.14 — диагностика");
        sb.AppendLine($"Время: {DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}");
        sb.AppendLine($"Computer: {Environment.MachineName}");
        sb.AppendLine($"User: {Environment.UserDomainName}\\{Environment.UserName}");
        sb.AppendLine($"ProgramData: {AppPaths.DataRoot}");
        sb.AppendLine();

        foreach (var i in Items)
        {
            var mark = i.Level switch
            {
                CheckLevel.Ok => "OK",
                CheckLevel.Warning => "WARN",
                _ => "ERROR"
            };
            sb.AppendLine($"[{mark}] {i.Name}: {i.Message}");
            if (!string.IsNullOrWhiteSpace(i.Details))
                sb.AppendLine("    " + i.Details.Replace(Environment.NewLine, Environment.NewLine + "    "));
        }

        sb.AppendLine();
        sb.AppendLine($"Итого: OK={Ok}; WARN={Warnings}; ERROR={Errors}");
        return sb.ToString();
    }
}

internal static class StartupDiagnostics
{
    public static async Task<DiagnosticReport> RunAsync()
    {
        var r = new DiagnosticReport();

        CheckDirectory(r, "Каталог данных", AppPaths.DataRoot, mustWrite: true);
        CheckDirectory(r, "State", AppPaths.StateDir, mustWrite: true);
        CheckDirectory(r, "Logs", AppPaths.LogsDir, mustWrite: true);
        CheckDirectory(r, "Web", AppPaths.WebDir, mustWrite: true);

        CheckFile(r, "BackupS3.ps1", AppPaths.BackupScript, fatal: true);
        CheckFile(r, "Manual-Upload.ps1", AppPaths.ManualUploadScript, fatal: false);
        CheckFile(r, "Generate-Dashboard.ps1", AppPaths.GenerateDashboardScript, fatal: true);
        CheckFile(r, "AutoScheduler.ps1", AppPaths.AutoSchedulerScript, fatal: false);
        CheckFile(r, "BackupJobs.psd1", AppPaths.ConfigPath, fatal: true);

        var ps = AppPaths.PowerShellExe();
        if (File.Exists(ps))
            r.Items.Add(new("Windows PowerShell", CheckLevel.Ok, ps));
        else
            r.Items.Add(new("Windows PowerShell", CheckLevel.Error, "powershell.exe не найден", ps));

        var aws = FindExecutable("aws.exe") ?? FindExecutable("aws");
        if (aws is null)
        {
            r.Items.Add(new("AWS CLI", CheckLevel.Error,
                "AWS CLI не найден. Проверка/загрузка S3 работать не будет.",
                "Установи AWS CLI v2 или добавь aws.exe в PATH."));
        }
        else
        {
            var ver = await RunAsync(aws, new[] { "--version" }, AppPaths.DataRoot, 15000);
            r.Items.Add(new(
                "AWS CLI",
                ver.ExitCode == 0 ? CheckLevel.Ok : CheckLevel.Error,
                ver.ExitCode == 0 ? ver.Output.Trim() : "aws --version завершился ошибкой",
                ver.ExitCode == 0 ? aws : ver.Output));
        }

        await CheckPowerShellConfigAsync(r);
        CheckJson(r, "settings.json", AppPaths.SettingsPath, required: false);
        CheckJson(r, "managed-jobs.json", AppPaths.ManagedJobsPath, required: false);
        CheckJson(r, "state.json", AppPaths.StatePath, required: false);

        await CheckDashboardGenerationAsync(r);
        await CheckSchedulerAsync(r);
        await CheckS3ConnectionsAsync(r);

        return r;
    }

    private static void CheckDirectory(DiagnosticReport r, string name, string path, bool mustWrite)
    {
        try
        {
            Directory.CreateDirectory(path);
            if (mustWrite)
            {
                var test = Path.Combine(path, ".write-test-" + Guid.NewGuid().ToString("N") + ".tmp");
                File.WriteAllText(test, "ok");
                File.Delete(test);
            }
            r.Items.Add(new(name, CheckLevel.Ok, path));
        }
        catch (Exception ex)
        {
            r.Items.Add(new(name, CheckLevel.Error, "Нет доступа к каталогу", $"{path}\n{ex.Message}"));
        }
    }

    private static void CheckFile(DiagnosticReport r, string name, string path, bool fatal)
    {
        if (File.Exists(path))
            r.Items.Add(new(name, CheckLevel.Ok, path));
        else
            r.Items.Add(new(name, fatal ? CheckLevel.Error : CheckLevel.Warning, "Файл не найден", path));
    }

    private static void CheckJson(DiagnosticReport r, string name, string path, bool required)
    {
        if (!File.Exists(path))
        {
            r.Items.Add(new(name, required ? CheckLevel.Error : CheckLevel.Warning,
                required ? "Файл отсутствует" : "Файл ещё не создан", path));
            return;
        }

        try
        {
            JsonNode.Parse(File.ReadAllText(path, Encoding.UTF8));
            r.Items.Add(new(name, CheckLevel.Ok, "JSON корректен", path));
        }
        catch (Exception ex)
        {
            r.Items.Add(new(name, CheckLevel.Error, "JSON повреждён", $"{path}\n{ex.Message}"));
        }
    }

    private static async Task CheckPowerShellConfigAsync(DiagnosticReport r)
    {
        if (!File.Exists(AppPaths.ConfigPath)) return;

        const string script =
            "$ErrorActionPreference='Stop';" +
            "$c=Import-PowerShellDataFile -Path $env:BACKUPS3_DIAG_CONFIG;" +
            "$count=@($c.Jobs).Count;" +
            "$endpoint=[string]$c.Global.EndpointUrl;" +
            "Write-Output ('JOBS='+$count);" +
            "Write-Output ('ENDPOINT='+$endpoint)";

        var psi = new ProcessStartInfo
        {
            FileName = AppPaths.PowerShellExe(),
            WorkingDirectory = AppPaths.DataRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var x in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script })
            psi.ArgumentList.Add(x);
        psi.Environment["BACKUPS3_DIAG_CONFIG"] = AppPaths.ConfigPath;

        var res = await RunAsync(psi, 20000);
        if (res.ExitCode == 0)
        {
            r.Items.Add(new("Конфигурация баз", CheckLevel.Ok,
                "BackupJobs.psd1 читается успешно", res.StdOut.Trim()));
        }
        else
        {
            r.Items.Add(new("Конфигурация баз", CheckLevel.Error,
                "BackupJobs.psd1 не удалось прочитать", res.Output));
        }
    }

    private static async Task CheckDashboardGenerationAsync(DiagnosticReport r)
    {
        try
        {
            await Task.Run(AppPaths.GenerateDashboard);
            var index = Path.Combine(AppPaths.WebDir, "index.html");
            if (!File.Exists(index))
            {
                r.Items.Add(new("Dashboard", CheckLevel.Error,
                    "Generate-Dashboard.ps1 завершился, но index.html не найден", index));
                return;
            }

            var fi = new FileInfo(index);
            r.Items.Add(new("Dashboard", CheckLevel.Ok,
                $"index.html создан, {fi.Length:N0} байт", index));
        }
        catch (Exception ex)
        {
            r.Items.Add(new("Dashboard", CheckLevel.Error,
                "Не удалось сформировать Dashboard", ex.Message));
        }
    }

    private static async Task CheckSchedulerAsync(DiagnosticReport r)
    {
        bool enabled = false;
        int interval = 0;

        try
        {
            if (File.Exists(AppPaths.SettingsPath))
            {
                var o = JsonNode.Parse(File.ReadAllText(AppPaths.SettingsPath, Encoding.UTF8))?.AsObject();
                enabled = o?["AutoSchedulerEnabled"]?.GetValue<bool>() ?? false;
                interval = o?["AutoSchedulerIntervalMinutes"]?.GetValue<int>() ?? 0;
            }
        }
        catch { }

        var schtasks = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32", "schtasks.exe");
        if (!File.Exists(schtasks)) schtasks = "schtasks.exe";

        var res = await RunAsync(
            schtasks,
            new[] { "/Query", "/TN", "BackupS3 Auto Scheduler", "/FO", "LIST" },
            AppPaths.DataRoot,
            15000);

        if (enabled)
        {
            if (res.ExitCode == 0)
                r.Items.Add(new("Автоматическая проверка", CheckLevel.Ok,
                    $"Task Scheduler включён, интервал {interval} мин."));
            else
                r.Items.Add(new("Автоматическая проверка", CheckLevel.Error,
                    "В настройках включена, но задача Windows отсутствует",
                    "Открой Настройки и нажми Сохранить ещё раз."));
        }
        else
        {
            if (res.ExitCode == 0)
                r.Items.Add(new("Автоматическая проверка", CheckLevel.Warning,
                    "Выключена в настройках, но старая задача Windows ещё существует",
                    "Открой Настройки, оставь автопроверку выключенной и нажми Сохранить, чтобы удалить задачу."));
            else
                r.Items.Add(new("Автоматическая проверка", CheckLevel.Ok, "Выключена"));
        }
    }

    private static async Task CheckS3ConnectionsAsync(DiagnosticReport r)
    {
        var aws = FindExecutable("aws.exe") ?? FindExecutable("aws");
        if (aws is null || !File.Exists(AppPaths.ConfigPath)) return;

        // Obtain effective Bucket/Profile/Endpoint pairs using hidden PowerShell.
        const string script =
            "$ErrorActionPreference='Stop';" +
            "$c=Import-PowerShellDataFile -Path $env:BACKUPS3_DIAG_CONFIG;" +
            "$ep=[string]$c.Global.EndpointUrl;" +
            "$items=@($c.Jobs|ForEach-Object{[pscustomobject]@{Bucket=[string]$_.Bucket;Profile=[string]$_.AwsProfile}}|" +
            "Where-Object{$_.Bucket}|Sort-Object Bucket,Profile -Unique);" +
            "[pscustomobject]@{Endpoint=$ep;Items=$items}|ConvertTo-Json -Depth 5 -Compress";

        var psi = new ProcessStartInfo
        {
            FileName = AppPaths.PowerShellExe(),
            WorkingDirectory = AppPaths.DataRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var x in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script })
            psi.ArgumentList.Add(x);
        psi.Environment["BACKUPS3_DIAG_CONFIG"] = AppPaths.ConfigPath;

        var cfg = await RunAsync(psi, 20000);
        if (cfg.ExitCode != 0 || string.IsNullOrWhiteSpace(cfg.StdOut))
        {
            r.Items.Add(new("S3 подключения", CheckLevel.Warning,
                "Не удалось получить список S3 для диагностики", cfg.Output));
            return;
        }

        JsonObject? obj;
        try { obj = JsonNode.Parse(cfg.StdOut.Trim())?.AsObject(); }
        catch (Exception ex)
        {
            r.Items.Add(new("S3 подключения", CheckLevel.Warning,
                "Не удалось разобрать список S3", ex.Message));
            return;
        }

        var endpoint = obj?["Endpoint"]?.ToString() ?? "";
        var itemsNode = obj?["Items"];
        var items = new List<JsonObject>();

        if (itemsNode is JsonArray arr)
            items.AddRange(arr.OfType<JsonObject>());
        else if (itemsNode is JsonObject one)
            items.Add(one);

        if (items.Count == 0)
        {
            r.Items.Add(new("S3 подключения", CheckLevel.Warning, "В конфигурации нет Bucket."));
            return;
        }

        foreach (var item in items)
        {
            var bucket = item["Bucket"]?.ToString() ?? "";
            var profile = item["Profile"]?.ToString() ?? "";
            var args = new List<string>();

            if (!string.IsNullOrWhiteSpace(endpoint))
            {
                args.Add("--endpoint-url");
                args.Add(endpoint);
            }
            if (!string.IsNullOrWhiteSpace(profile))
            {
                args.Add("--profile");
                args.Add(profile);
            }
            args.AddRange(new[] { "s3api", "list-objects-v2", "--bucket", bucket, "--max-keys", "1", "--output", "json" });

            var s3 = await RunAsync(aws, args, AppPaths.DataRoot, 20000);
            r.Items.Add(new(
                $"S3 {bucket}" + (string.IsNullOrWhiteSpace(profile) ? "" : $" [{profile}]"),
                s3.ExitCode == 0 ? CheckLevel.Ok : CheckLevel.Error,
                s3.ExitCode == 0 ? "Подключение доступно" : "AWS CLI вернул ошибку",
                s3.ExitCode == 0 ? endpoint : s3.Output));
        }
    }

    private static string? FindExecutable(string exe)
    {
        try
        {
            if (Path.IsPathRooted(exe) && File.Exists(exe)) return exe;
            var path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (var dir in path.Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    var candidate = Path.Combine(dir.Trim(), exe);
                    if (File.Exists(candidate)) return candidate;
                }
                catch { }
            }
        }
        catch { }
        return null;
    }

    private static async Task<(int ExitCode, string StdOut, string StdErr, string Output)> RunAsync(
        string exe, IEnumerable<string> args, string cwd, int timeoutMs)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            WorkingDirectory = cwd,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        return await RunAsync(psi, timeoutMs);
    }

    private static async Task<(int ExitCode, string StdOut, string StdErr, string Output)> RunAsync(
        ProcessStartInfo psi, int timeoutMs)
    {
        using var p = new Process { StartInfo = psi };
        p.Start();

        var so = p.StandardOutput.ReadToEndAsync();
        var se = p.StandardError.ReadToEndAsync();

        using var cts = new CancellationTokenSource(timeoutMs);
        try
        {
            await p.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            try { p.Kill(true); } catch { }
            return (-1, await so, await se, $"Timeout {timeoutMs / 1000} sec");
        }

        var stdout = await so;
        var stderr = await se;
        var output = string.Join(Environment.NewLine,
            new[] { stdout.Trim(), stderr.Trim() }.Where(x => x.Length > 0));

        return (p.ExitCode, stdout, stderr, output);
    }
}
