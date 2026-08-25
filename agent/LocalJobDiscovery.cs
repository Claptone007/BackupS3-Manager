using System.Diagnostics;
using System.Text.Json.Nodes;

namespace BackupS3Agent;

internal static class LocalJobDiscovery
{
    private static readonly string ManagerRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "BackupS3Manager");

    public static List<AgentJob> Discover(IEnumerable<AgentJob> assignedJobs, ILogger logger)
    {
        var jobs = new Dictionary<string, AgentJob>(StringComparer.OrdinalIgnoreCase);
        foreach (var job in assignedJobs.Where(job => !string.IsNullOrWhiteSpace(job.Name)))
            jobs[job.Name] = new AgentJob { Name = job.Name, LocalPath = job.LocalPath, FilePrefix = job.FilePrefix };

        var configPath = Path.Combine(ManagerRoot, "BackupJobs.psd1");
        if (File.Exists(configPath))
        {
            try { foreach (var job in ReadPowerShellDataFile(configPath)) jobs[job.Name] = job; }
            catch (Exception ex) { logger.LogWarning(ex, "Не удалось прочитать локальный BackupJobs.psd1"); }
        }

        var managedPath = Path.Combine(ManagerRoot, "State", "managed-jobs.json");
        if (File.Exists(managedPath))
        {
            try { ApplyManagedJobs(jobs, JsonNode.Parse(File.ReadAllText(managedPath))?.AsObject()); }
            catch (Exception ex) { logger.LogWarning(ex, "Не удалось прочитать локальный managed-jobs.json"); }
        }

        logger.LogInformation("Автообнаружение локальной конфигурации: {Jobs} баз", jobs.Count);
        return jobs.Values.OrderBy(job => job.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static IEnumerable<AgentJob> ReadPowerShellDataFile(string path)
    {
        var escaped = path.Replace("'", "''");
        var command = "$ErrorActionPreference='Stop';$c=Import-PowerShellDataFile -LiteralPath '" + escaped +
                      "';@($c.Jobs|ForEach-Object{[pscustomobject]@{Name=[string]$_.Name;LocalPath=[string]$_.LocalPath;FilePrefix=[string]$_.FilePrefix}})|ConvertTo-Json -Compress";
        var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        var start = new ProcessStartInfo(File.Exists(powershell) ? powershell : "powershell.exe")
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command })
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Не удалось запустить PowerShell для чтения BackupJobs.psd1.");
        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        if (!process.WaitForExit(15000)) { process.Kill(true); throw new TimeoutException("Чтение BackupJobs.psd1 превысило 15 секунд."); }
        if (process.ExitCode != 0) throw new InvalidOperationException(error.Trim());
        if (string.IsNullOrWhiteSpace(output)) return Array.Empty<AgentJob>();
        var node = JsonNode.Parse(output);
        var values = node is JsonArray array ? array : new JsonArray(node?.DeepClone());
        return values.OfType<JsonObject>().Select(ReadJob).Where(job => job.Name.Length > 0).ToArray();
    }

    private static void ApplyManagedJobs(Dictionary<string, AgentJob> jobs, JsonObject? managed)
    {
        if (managed is null) return;
        if (managed["UseBaseJobs"]?.GetValue<bool>() == false) jobs.Clear();
        foreach (var node in managed["AddedJobs"]?.AsArray() ?? new JsonArray())
            if (node is JsonObject value)
            {
                var job = ReadJob(value);
                if (job.Name.Length > 0) jobs[job.Name] = job;
            }
        foreach (var node in managed["DeletedNames"]?.AsArray() ?? new JsonArray())
            if (node is not null) jobs.Remove(node.ToString());
        if (managed["Overrides"] is not JsonObject overrides) return;
        foreach (var pair in overrides)
        {
            if (!jobs.TryGetValue(pair.Key, out var job) || pair.Value is not JsonObject patch) continue;
            var localPath = patch["LocalPath"]?.ToString();
            if (!string.IsNullOrWhiteSpace(localPath)) job.LocalPath = localPath;
            var filePrefix = patch["FilePrefix"]?.ToString();
            if (!string.IsNullOrWhiteSpace(filePrefix)) job.FilePrefix = filePrefix;
        }
    }

    private static AgentJob ReadJob(JsonObject value) => new()
    {
        Name = value["Name"]?.ToString() ?? value["name"]?.ToString() ?? "",
        LocalPath = value["LocalPath"]?.ToString() ?? value["localPath"]?.ToString() ?? "",
        FilePrefix = value["FilePrefix"]?.ToString() ?? value["filePrefix"]?.ToString() ?? ""
    };
}
