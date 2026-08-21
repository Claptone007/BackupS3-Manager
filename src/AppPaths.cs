using System.Diagnostics;

namespace BackupS3Manager;

internal static class AppPaths
{
    public static string InstallRoot => AppContext.BaseDirectory;
    public static string TemplateRoot => Path.Combine(InstallRoot, "BackendTemplate");
    public static string BundledWebView2Runtime => Path.Combine(InstallRoot, "WebView2Runtime");
    public static string? BundledWebView2RuntimeOrNull
    {
        get
        {
            if (!Directory.Exists(BundledWebView2Runtime)) return null;
            var exe = Directory.EnumerateFiles(
                BundledWebView2Runtime,
                "msedgewebview2.exe",
                SearchOption.AllDirectories).FirstOrDefault();
            return exe is null ? null : Path.GetDirectoryName(exe);
        }
    }
    public static string DataRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "BackupS3Manager");

    public static string ConfigPath => Path.Combine(DataRoot, "BackupJobs.psd1");
    public static string StateDir => Path.Combine(DataRoot, "State");
    public static string LogsDir => Path.Combine(DataRoot, "Logs");
    public static string WebDir => Path.Combine(DataRoot, "Web");
    public static string StatePath => Path.Combine(StateDir, "state.json");
    public static string ProgressPath => Path.Combine(StateDir, "progress.json");
    public static string SettingsPath => Path.Combine(StateDir, "settings.json");
    public static string ManagedJobsPath => Path.Combine(StateDir, "managed-jobs.json");
    public static string UiSettingsPath => Path.Combine(StateDir, "ui-settings.json");
    public static string MaintenancePath => Path.Combine(StateDir, "maintenance.json");
    public static string HistoryPath => Path.Combine(StateDir, "history.jsonl");
    public static string ControllerStatePath => Path.Combine(StateDir, "controller.json");
    public static string SchedulerStatePath => Path.Combine(StateDir, "scheduler-state.json");
    public static string CancelFlagPath => Path.Combine(StateDir, "cancel.flag");
    public static string ManualUploadsDir => Path.Combine(StateDir, "ManualUploads");
    public static string UploadProgressDir => Path.Combine(StateDir, "UploadProgress");
    public static string ProfilesDir => Path.Combine(StateDir, "Profiles");
    public static string AwsDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".aws");
    public static string AwsCredentialsPath => Path.Combine(AwsDir, "credentials");
    public static string AwsConfigPath => Path.Combine(AwsDir, "config");

    public static string BackupScript => Path.Combine(DataRoot, "BackupS3.ps1");
    public static string ManualUploadScript => Path.Combine(DataRoot, "Manual-Upload.ps1");
    public static string GenerateDashboardScript => Path.Combine(DataRoot, "Generate-Dashboard.ps1");
    public static string AutoSchedulerScript => Path.Combine(DataRoot, "AutoScheduler.ps1");

    public static void Initialize()
    {
        Directory.CreateDirectory(DataRoot);
        Directory.CreateDirectory(StateDir);
        Directory.CreateDirectory(LogsDir);
        Directory.CreateDirectory(WebDir);
        Directory.CreateDirectory(ManualUploadsDir);
        Directory.CreateDirectory(UploadProgressDir);
        Directory.CreateDirectory(ProfilesDir);

        SyncTemplateFiles();
        CreateDailyConfigurationSnapshot();
        GenerateDashboard();
    }

    private static void CreateDailyConfigurationSnapshot()
    {
        try
        {
            var root = Path.Combine(StateDir, "AutomaticBackups");
            var today = Path.Combine(root, DateTime.Today.ToString("yyyy-MM-dd"));
            Directory.CreateDirectory(today);

            foreach (var source in new[] { ConfigPath, ManagedJobsPath, SettingsPath, UiSettingsPath })
            {
                if (!File.Exists(source)) continue;
                var destination = Path.Combine(today, Path.GetFileName(source));
                if (!File.Exists(destination)) File.Copy(source, destination);
            }

            foreach (var directory in Directory.EnumerateDirectories(root)
                         .OrderByDescending(Path.GetFileName).Skip(14))
                Directory.Delete(directory, true);
        }
        catch (Exception ex) { AppLog.Warn("Не удалось создать автоматическую копию конфигурации: " + ex.Message); }
    }

    private static void SyncTemplateFiles()
    {
        if (!Directory.Exists(TemplateRoot))
            throw new DirectoryNotFoundException($"BackendTemplate not found: {TemplateRoot}");

        foreach (var src in Directory.EnumerateFiles(TemplateRoot, "*", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(TemplateRoot, src);
            if (rel.Equals("Start-DashboardServer.ps1", StringComparison.OrdinalIgnoreCase))
                continue;

            var dst = Path.Combine(DataRoot, rel);
            Directory.CreateDirectory(Path.GetDirectoryName(dst)!);

            // Preserve user configuration and persistent state.
            var persistent =
                rel.Equals("BackupJobs.psd1", StringComparison.OrdinalIgnoreCase) ||
                rel.StartsWith("State" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                rel.StartsWith("Logs" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

            if (persistent && File.Exists(dst))
                continue;

            File.Copy(src, dst, true);
        }
    }

    public static void GenerateDashboard()
    {
        if (!File.Exists(GenerateDashboardScript) || !File.Exists(ConfigPath))
            return;

        var psi = new ProcessStartInfo
        {
            FileName = PowerShellExe(),
            WorkingDirectory = DataRoot,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-NonInteractive");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-File");
        psi.ArgumentList.Add(GenerateDashboardScript);
        psi.ArgumentList.Add("-ConfigPath");
        psi.ArgumentList.Add(ConfigPath);

        using var p = Process.Start(psi);
        if (p is null)
            throw new InvalidOperationException("Не удалось запустить Generate-Dashboard.ps1");

        if (!p.WaitForExit(30000))
        {
            try { p.Kill(true); } catch { }
            throw new TimeoutException("Generate-Dashboard.ps1 не завершился за 30 секунд.");
        }

        if (p.ExitCode != 0)
            throw new InvalidOperationException($"Generate-Dashboard.ps1 завершился с кодом {p.ExitCode}.");

        var index = Path.Combine(WebDir, "index.html");
        if (!File.Exists(index))
            throw new FileNotFoundException("Dashboard не был создан.", index);
    }

    public static string PowerShellExe()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        return File.Exists(path) ? path : "powershell.exe";
    }
}
