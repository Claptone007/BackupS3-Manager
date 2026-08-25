using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using Microsoft.Extensions.Hosting;
using Microsoft.Win32;

namespace BackupS3Agent;

internal static class Program
{
    [STAThread]
    private static async Task Main(string[] args)
    {
        if (args.Length == 2 && args[0].Equals("--install-config", StringComparison.OrdinalIgnoreCase))
        {
            AgentInstaller.InstallFromTemporaryConfiguration(args[1]);
            return;
        }
        var background = args.Contains("--background", StringComparer.OrdinalIgnoreCase);
        var service = args.Contains("--service", StringComparer.OrdinalIgnoreCase);
        if (Environment.UserInteractive && !service && !background)
        {
            ApplicationConfiguration.Initialize();
            Application.Run(new SetupForm());
            return;
        }
        var builder = Host.CreateApplicationBuilder(args);
        if (service) builder.Services.AddWindowsService(options => options.ServiceName = AgentInstaller.ServiceDisplayName);
        builder.Services.AddSingleton<AgentConfigurationStore>();
        builder.Services.AddHostedService<AgentWorker>();
        await builder.Build().RunAsync();
    }
}

internal static class AgentInstaller
{
    public const string ServiceName = "BackupS3Agent";
    public const string ServiceDisplayName = "BackupS3 Agent";
    public const string TaskName = "BackupS3 Agent (User Session)";
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, TypeInfoResolver = new DefaultJsonTypeInfoResolver() };

    public static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    public static void RequestElevatedInstall(AgentConfiguration configuration)
    {
        var temporary = Path.Combine(Path.GetTempPath(), $"BackupS3Agent-install-{Guid.NewGuid():N}.json");
        File.WriteAllText(temporary, JsonSerializer.Serialize(configuration, JsonOptions));
        var start = new ProcessStartInfo { FileName = Environment.ProcessPath!, UseShellExecute = true, Verb = "runas" };
        start.ArgumentList.Add("--install-config"); start.ArgumentList.Add(temporary);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Не удалось запустить установку с правами администратора.");
        process.WaitForExit();
        if (process.ExitCode != 0) throw new InvalidOperationException("BackupS3 Agent не был запущен. Подробности показаны в окне установки.");
    }

    public static void InstallFromTemporaryConfiguration(string temporaryPath)
    {
        try
        {
            var configuration = JsonSerializer.Deserialize<AgentConfiguration>(File.ReadAllText(temporaryPath), JsonOptions) ?? throw new InvalidDataException("Installation configuration is empty.");
            Install(configuration);
            MessageBox.Show("BackupS3 Agent установлен и запущен в пользовательском сеансе.\r\nОн автоматически прочитает локальную конфигурацию BackupS3 и увидит подключённые диски.\r\n\r\nHost: " + Environment.MachineName, "BackupS3 Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception ex) { Environment.ExitCode = 1; MessageBox.Show(ex.Message, "Ошибка установки BackupS3 Agent", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        finally { try { File.Delete(temporaryPath); } catch { } }
    }

    private static void Install(AgentConfiguration configuration)
    {
        if (!IsAdministrator()) throw new UnauthorizedAccessException("Для установки агента требуются права администратора.");
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "BackupS3 Agent");
        Directory.CreateDirectory(directory);
        var installedExe = Path.Combine(directory, "BackupS3Agent.exe");
        var currentExe = Environment.ProcessPath ?? throw new InvalidOperationException("Не удалось определить путь агента.");
        RunSc(true, "stop", ServiceName); RunSc(true, "delete", ServiceName);
        StopInteractiveTask();
        StopInstalledAgentProcesses(installedExe);
        if (!string.Equals(Path.GetFullPath(currentExe), Path.GetFullPath(installedExe), StringComparison.OrdinalIgnoreCase))
            CopyExecutableWithRetry(currentExe, installedExe);
        new AgentConfigurationStore().Save(configuration);
        var bundleDirectory = Path.Combine(AgentConfigurationStore.Root, "Bundle");
        Directory.CreateDirectory(bundleDirectory);
        RunFirewallRule(configuration.ListenPort);
        InstallInteractiveTask(installedExe, bundleDirectory);
    }

    private static void StopInteractiveTask()
    {
        var escapedTask = TaskName.Replace("'", "''");
        var command = "$ErrorActionPreference='SilentlyContinue';" +
                      "Stop-ScheduledTask -TaskName '" + escapedTask + "';" +
                      "Unregister-ScheduledTask -TaskName '" + escapedTask + "' -Confirm:$false";
        var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        var start = new ProcessStartInfo(powershell) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command })
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start);
        process?.WaitForExit(10000);
    }

    private static void StopInstalledAgentProcesses(string installedExe)
    {
        var expected = Path.GetFullPath(installedExe);
        foreach (var process in Process.GetProcessesByName("BackupS3Agent"))
        {
            using (process)
            {
                if (process.Id == Environment.ProcessId) continue;
                try
                {
                    var executable = process.MainModule?.FileName;
                    if (string.IsNullOrWhiteSpace(executable) ||
                        !string.Equals(Path.GetFullPath(executable), expected, StringComparison.OrdinalIgnoreCase)) continue;
                    process.Kill(true);
                    process.WaitForExit(10000);
                }
                catch { }
            }
        }
    }

    private static void CopyExecutableWithRetry(string source, string destination)
    {
        Exception? lastError = null;
        for (var attempt = 1; attempt <= 20; attempt++)
        {
            try { File.Copy(source, destination, true); return; }
            catch (IOException ex) { lastError = ex; Thread.Sleep(250); }
            catch (UnauthorizedAccessException ex) { lastError = ex; Thread.Sleep(250); }
        }
        throw new IOException("Не удалось заменить старый BackupS3 Agent после его остановки.", lastError);
    }

    private static void InstallInteractiveTask(string installedExe, string bundleDirectory)
    {
        var user = WindowsIdentity.GetCurrent().Name;
        var escapedExe = installedExe.Replace("'", "''");
        var escapedUser = user.Replace("'", "''");
        var escapedBundle = bundleDirectory.Replace("'", "''");
        var escapedTask = TaskName.Replace("'", "''");
        var workingDirectory = Path.GetDirectoryName(installedExe)!.Replace("'", "''");
        var command = "$ErrorActionPreference='Stop';" +
            "$a=New-ScheduledTaskAction -Execute '" + escapedExe + "' -Argument '--background' -WorkingDirectory '" + workingDirectory + "';" +
            "$t=New-ScheduledTaskTrigger -AtLogOn -User '" + escapedUser + "';" +
            "$p=New-ScheduledTaskPrincipal -UserId '" + escapedUser + "' -LogonType Interactive -RunLevel Limited;" +
            "$s=New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero);" +
            "Register-ScheduledTask -TaskName '" + escapedTask + "' -Action $a -Trigger $t -Principal $p -Settings $s -Force|Out-Null;" +
            "[Environment]::SetEnvironmentVariable('DOTNET_BUNDLE_EXTRACT_BASE_DIR','" + escapedBundle + "','User');" +
            "Start-ScheduledTask -TaskName '" + escapedTask + "'";
        var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        var start = new ProcessStartInfo(powershell)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command })
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Не удалось создать автозадачу агента.");
        var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0)
            throw new InvalidOperationException("Не удалось запустить агент в пользовательском сеансе: " + output.Trim());
    }

    private static void RunFirewallRule(int port)
    {
        var start = new ProcessStartInfo("netsh.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { "advfirewall", "firewall", "add", "rule", "name=BackupS3 Agent probe", "dir=in", "action=allow", "protocol=TCP", "localport=" + port }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Не удалось настроить Windows Firewall.");
        var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd(); process.WaitForExit();
        if (process.ExitCode != 0 && !output.Contains("already exists", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Не удалось открыть порт агента в Windows Firewall: " + output.Trim());
    }

    private static void RunSc(bool allowFailure, params string[] arguments)
    {
        var start = new ProcessStartInfo("sc.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Не удалось запустить sc.exe.");
        var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd(); process.WaitForExit();
        if (!allowFailure && process.ExitCode != 0) throw new InvalidOperationException("sc.exe: " + output.Trim());
    }
}
