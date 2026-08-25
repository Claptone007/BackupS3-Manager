using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text;
using System.Collections.Concurrent;
using System.Diagnostics;

namespace BackupS3Agent;

internal sealed class AgentWorker : BackgroundService
{
    private readonly AgentConfigurationStore _store;
    private readonly ILogger<AgentWorker> _logger;
    private readonly HttpClient _client = new() { Timeout = TimeSpan.FromSeconds(20) };
    private readonly ConcurrentDictionary<string, AgentUploadOperation> _uploadOperations = new(StringComparer.OrdinalIgnoreCase);

    public AgentWorker(AgentConfigurationStore store, ILogger<AgentWorker> logger)
    {
        _store = store;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var probeTask = RunProbeServerAsync(stoppingToken);
        while (!stoppingToken.IsCancellationRequested)
        {
            var delaySeconds = 15;
            try
            {
                var config = _store.Load();
                delaySeconds = Math.Clamp(config.PollSeconds, 5, 3600);
                if (string.IsNullOrWhiteSpace(config.AgentId) || string.IsNullOrWhiteSpace(config.Token))
                    await EnrollAsync(config, stoppingToken);
                if (!string.IsNullOrWhiteSpace(config.AgentId) && !string.IsNullOrWhiteSpace(config.Token))
                    await SendHeartbeatAsync(config, stoppingToken);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Не удалось связаться с BackupS3 Manager");
            }
            await Task.Delay(TimeSpan.FromSeconds(delaySeconds), stoppingToken);
        }
        await probeTask;
    }

    private async Task EnrollAsync(AgentConfiguration config, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(config.EnrollmentCode))
        {
            _logger.LogWarning("Укажите EnrollmentCode в {Path}", AgentConfigurationStore.PathName);
            return;
        }
        var response = await PostJsonAsync(Url(config, "/agent/enroll"), new
        {
            enrollmentCode = config.EnrollmentCode,
            host = Environment.MachineName,
            displayName = string.IsNullOrWhiteSpace(config.DisplayName) ? Environment.MachineName : config.DisplayName,
            version = Version
        }, cancellationToken);
        var text = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"Регистрация отклонена: {text}");
        var result = JsonNode.Parse(text)?.AsObject() ?? throw new InvalidDataException("Manager вернул пустой ответ регистрации.");
        config.AgentId = result["agentId"]?.ToString() ?? "";
        config.Token = result["token"]?.ToString() ?? "";
        if (int.TryParse(result["pollSeconds"]?.ToString(), out var poll)) config.PollSeconds = poll;
        _store.Save(config);
        _logger.LogInformation("Агент зарегистрирован: {AgentId}", config.AgentId);
    }

    private async Task SendHeartbeatAsync(AgentConfiguration config, CancellationToken cancellationToken)
    {
        var discoveredJobs = LocalJobDiscovery.Discover(config.Jobs, _logger);
        _client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", config.Token);
        var response = await PostJsonAsync(Url(config, "/agent/heartbeat"), new
        {
            agentId = config.AgentId,
            host = Environment.MachineName,
            displayName = string.IsNullOrWhiteSpace(config.DisplayName) ? Environment.MachineName : config.DisplayName,
            version = Version,
            report = new
            {
                generatedAt = DateTimeOffset.Now,
                jobs = discoveredJobs.Select(InspectJob).ToArray()
            },
            commandResults = ReadUploadResults()
        }, cancellationToken);
        if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized && !string.IsNullOrWhiteSpace(config.EnrollmentCode))
        {
            _logger.LogWarning("Токен агента отклонён. Выполняется автоматическая повторная регистрация.");
            config.AgentId = "";
            config.Token = "";
            _store.Save(config);
            return;
        }
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Heartbeat отклонён: {await response.Content.ReadAsStringAsync(cancellationToken)}");
        var responseText = await response.Content.ReadAsStringAsync(cancellationToken);
        var result = string.IsNullOrWhiteSpace(responseText) ? new JsonObject() : JsonNode.Parse(responseText)?.AsObject() ?? new JsonObject();
        if (result["assignments"] is JsonArray assignments)
        {
            var updated = assignments.OfType<JsonObject>().Select(item => new AgentJob
            {
                Name = item["name"]?.ToString() ?? "",
                LocalPath = item["localPath"]?.ToString() ?? ""
            }).Where(job => job.Name.Length > 0).ToList();
            if (JsonSerializer.Serialize(updated) != JsonSerializer.Serialize(config.Jobs))
            {
                config.Jobs = updated;
                _store.Save(config);
                _logger.LogInformation("Назначения обновлены: {Jobs} баз", updated.Count);
            }
        }
        if (result["commands"] is JsonArray commands)
        {
            foreach (var command in commands.OfType<JsonObject>())
            {
                if (!string.Equals(command["type"]?.ToString(), "upload", StringComparison.OrdinalIgnoreCase)) continue;
                StartUploadCommand(command);
            }
        }
        _logger.LogInformation("Heartbeat отправлен: {Jobs} баз", discoveredJobs.Count);
    }

    private void StartUploadCommand(JsonObject command)
    {
        var id = command["id"]?.ToString() ?? "";
        if (!Guid.TryParse(id, out _) || !_uploadOperations.TryAdd(id, new AgentUploadOperation(id))) return;
        var database = command["database"]?.ToString() ?? "";
        var filePath = command["filePath"]?.ToString() ?? "";
        _ = Task.Run(async () => await RunUploadCommandAsync(id, database, filePath));
    }

    private async Task RunUploadCommandAsync(string id, string database, string filePath)
    {
        var operation = _uploadOperations[id];
        operation.SetFallback("STARTING", 0, "Агент запускает загрузку на S3");
        try
        {
            var managerRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "BackupS3Manager");
            var script = Path.Combine(managerRoot, "Manual-Upload.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("На сервере агента не найден Manual-Upload.ps1", script);
            if (!File.Exists(filePath)) throw new FileNotFoundException("Локальный backup-файл на сервере агента не найден", filePath);
            var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            var start = new ProcessStartInfo(powershell)
            {
                WorkingDirectory = managerRoot, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
                         "-RootPath", managerRoot, "-OperationId", id, "-Database", database, "-FilePath", filePath })
                start.ArgumentList.Add(argument);
            using var process = Process.Start(start) ?? throw new InvalidOperationException("Не удалось запустить загрузку на агенте.");
            var outputTask = process.StandardOutput.ReadToEndAsync();
            var errorTask = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            var output = (await outputTask).Trim();
            var error = (await errorTask).Trim();
            if (process.ExitCode != 0)
                operation.SetFallback("ERROR", 0, string.IsNullOrWhiteSpace(error) ? $"Manual-Upload завершился с кодом {process.ExitCode}: {output}" : error);
        }
        catch (Exception ex)
        {
            operation.SetFallback("ERROR", 0, ex.Message);
            _logger.LogError(ex, "Удалённая загрузка {OperationId} не выполнена", id);
        }
    }

    private object[] ReadUploadResults()
    {
        var statusRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "BackupS3Manager", "State", "ManualUploads");
        return _uploadOperations.Values.Select(operation =>
        {
            var statusPath = Path.Combine(statusRoot, operation.Id + ".json");
            if (File.Exists(statusPath))
            {
                try
                {
                    var status = JsonNode.Parse(File.ReadAllText(statusPath, Encoding.UTF8))?.AsObject();
                    if (status is not null) return (object)status;
                }
                catch { }
            }
            return operation.Snapshot();
        }).ToArray();
    }

    private async Task RunProbeServerAsync(CancellationToken cancellationToken)
    {
        System.Net.Sockets.TcpListener? listener = null;
        try
        {
            var config = _store.Load();
            listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Any, Math.Clamp(config.ListenPort, 1024, 65535));
            listener.Start();
            _logger.LogInformation("Порт активной проверки агента открыт: {Port}", config.ListenPort);
            while (!cancellationToken.IsCancellationRequested)
            {
                using var client = await listener.AcceptTcpClientAsync(cancellationToken);
                await using var stream = client.GetStream();
                var payload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
                {
                    ok = true, agentId = config.AgentId, host = Environment.MachineName,
                    displayName = config.DisplayName, version = Version, serverTime = DateTimeOffset.Now
                }) + "\n");
                await stream.WriteAsync(payload, cancellationToken);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _logger.LogError(ex, "Не удалось открыть порт активной проверки агента"); }
        finally { listener?.Stop(); }
    }

    private async Task<HttpResponseMessage> PostJsonAsync(string url, object value, CancellationToken cancellationToken)
    {
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value));
        using var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json") { CharSet = "utf-8" };
        return await _client.PostAsync(url, content, cancellationToken);
    }

    private static object InspectJob(AgentJob job)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(job.LocalPath) || !Directory.Exists(job.LocalPath))
                return new { name = job.Name, localPath = job.LocalPath, available = false, error = "Локальный каталог недоступен" };
            var files = Directory.EnumerateFiles(job.LocalPath, "*", SearchOption.TopDirectoryOnly)
                .Select(path => new FileInfo(path))
                .Where(file => string.IsNullOrWhiteSpace(job.FilePrefix) || file.Name.StartsWith(job.FilePrefix, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(file => file.LastWriteTimeUtc).ToArray();
            var latest = files.FirstOrDefault();
            return new
            {
                name = job.Name,
                localPath = job.LocalPath,
                available = true,
                fileCount = files.Length,
                totalBytes = files.Sum(file => file.Length),
                latestFile = latest?.Name,
                latestSizeBytes = latest?.Length ?? 0,
                latestWriteTime = latest is null ? (DateTimeOffset?)null : new DateTimeOffset(latest.LastWriteTime),
                files = files.Take(500).Select(file => new
                {
                    name = file.Name, fullName = file.FullName, sizeBytes = file.Length,
                    lastWriteTime = new DateTimeOffset(file.LastWriteTime)
                }).ToArray()
            };
        }
        catch (Exception ex)
        {
            return new { name = job.Name, localPath = job.LocalPath, available = false, error = ex.Message };
        }
    }

    private static string Url(AgentConfiguration config, string path) => config.ManagerUrl.TrimEnd('/') + path;
    private static string Version => Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "1.0.0";

    private sealed class AgentUploadOperation
    {
        private readonly object _sync = new();
        private string _status = "QUEUED", _message = "Команда получена агентом";
        private int _percent;
        public string Id { get; }
        public AgentUploadOperation(string id) => Id = id;
        public void SetFallback(string status, int percent, string message) { lock (_sync) { _status = status; _percent = percent; _message = message; } }
        public object Snapshot() { lock (_sync) return new { id = Id, status = _status, percent = _percent, message = _message, updatedAt = DateTimeOffset.Now }; }
    }
}
