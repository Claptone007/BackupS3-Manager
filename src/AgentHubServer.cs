using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;

namespace BackupS3Manager;

internal sealed class AgentHubServer : IDisposable
{
    private const int Port = 17831;
    private const int MaxBodyBytes = 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        TypeInfoResolver = new DefaultJsonTypeInfoResolver()
    };
    private readonly CancellationTokenSource _stop = new();
    internal static readonly object StateLock = new();
    private TcpListener? _listener;
    private Task? _loop;
    private Task? _probeLoop;

    public void Start()
    {
        Directory.CreateDirectory(AppPaths.StateDir);
        EnsureEnrollmentCode();
        _listener = new TcpListener(IPAddress.Any, Port);
        _listener.Start();
        _loop = AcceptLoopAsync(_stop.Token);
        _probeLoop = ProbeLoopAsync(_stop.Token);
        AppLog.Info($"Agent Hub запущен на TCP {Port}");
    }

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var client = await _listener!.AcceptTcpClientAsync(cancellationToken);
                _ = Task.Run(() => HandleClientAsync(client, cancellationToken), cancellationToken);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) { AppLog.Warn("Agent Hub: ошибка приёма соединения: " + ex.Message); }
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken cancellationToken)
    {
        using (client)
        {
            client.ReceiveTimeout = 15000;
            client.SendTimeout = 15000;
            await using var stream = client.GetStream();
            try
            {
                var request = await ReadRequestAsync(stream, cancellationToken);
                var response = Process(request);
                await WriteResponseAsync(stream, response.Status, response.Body, cancellationToken);
            }
            catch (Exception ex)
            {
                await WriteResponseAsync(stream, 400, new JsonObject { ["error"] = ex.Message }, cancellationToken);
            }
        }
    }

    private HubResponse Process(HubRequest request)
    {
        if (request.Method == "GET" && request.Path == "/agent/health")
            return new(200, new JsonObject { ["ok"] = true, ["manager"] = Environment.MachineName, ["serverTime"] = DateTimeOffset.Now });

        if (request.Method == "POST" && request.Path == "/agent/enroll")
            return Enroll(request.Body);

        if (request.Method == "POST" && request.Path == "/agent/heartbeat")
            return Heartbeat(request.Authorization, request.Body);

        return new(404, new JsonObject { ["error"] = "Маршрут Agent Hub не найден." });
    }

    private HubResponse Enroll(JsonObject body)
    {
        var expected = ReadSettings()["AgentEnrollmentCode"]?.ToString() ?? "";
        var supplied = body["enrollmentCode"]?.ToString() ?? "";
        JsonObject? pending = null;
        lock (StateLock)
            pending = ReadAgentState()["agents"]!.AsArray().OfType<JsonObject>().FirstOrDefault(a =>
                string.Equals(a["pendingCodeHash"]?.ToString(), HashToken(supplied), StringComparison.Ordinal));
        var globalCodeMatches = expected.Length > 0 && supplied.Length == expected.Length &&
            CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(supplied));
        if (!globalCodeMatches && pending is null)
            return new(403, new JsonObject { ["error"] = "Неверный или уже использованный код подключения агента." });

        var host = NormalizeHost(body["host"]?.ToString());
        if (host.Length == 0) return new(400, new JsonObject { ["error"] = "Агент не передал Host." });

        lock (StateLock)
        {
            var revoked = ReadAgentState()["revokedHosts"]?.AsArray().Any(value =>
                string.Equals(value?.ToString(), host, StringComparison.OrdinalIgnoreCase)) ?? false;
            if (revoked && pending is null)
                return new(403, new JsonObject { ["error"] = "Подключение агента отозвано. Создайте новую карточку и используйте её персональный код." });
        }

        lock (StateLock)
        {
            var state = ReadAgentState();
            var agents = state["agents"]!.AsArray();
            var existing = agents.OfType<JsonObject>().FirstOrDefault(a =>
                string.Equals(a["pendingCodeHash"]?.ToString(), HashToken(supplied), StringComparison.Ordinal)) ?? agents.OfType<JsonObject>().FirstOrDefault(a =>
                string.Equals(a["host"]?.ToString(), host, StringComparison.OrdinalIgnoreCase));
            var agent = existing ?? new JsonObject();
            if (existing is null) agents.Add(agent);
            var id = agent["id"]?.ToString() ?? Guid.NewGuid().ToString("N");
            var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
            agent["id"] = id;
            agent["tokenHash"] = HashToken(token);
            agent["host"] = host;
            agent["displayName"] = body["displayName"]?.ToString() ?? host;
            agent["version"] = body["version"]?.ToString() ?? "unknown";
            agent["enrollmentCodeHint"] = supplied.Length <= 4 ? supplied : "••••" + supplied[^4..];
            agent.Remove("pendingCodeHash");
            if (state["revokedHosts"] is JsonArray revokedHosts)
                for (var index = revokedHosts.Count - 1; index >= 0; index--)
                    if (string.Equals(revokedHosts[index]?.ToString(), host, StringComparison.OrdinalIgnoreCase)) revokedHosts.RemoveAt(index);
            agent["enrolledAt"] = DateTimeOffset.Now;
            agent["lastSeen"] = DateTimeOffset.Now;
            agent["online"] = true;
            WriteAgentState(state);
            AppLog.Info($"Agent Hub: зарегистрирован агент {host} ({id})");
            return new(200, new JsonObject { ["agentId"] = id, ["token"] = token, ["pollSeconds"] = 15 });
        }
    }

    private async Task ProbeLoopAsync(CancellationToken cancellationToken)
    {
        using var timeout = new CancellationTokenSource();
        while (!cancellationToken.IsCancellationRequested)
        {
            List<(string Id, string Address, int Port)> targets;
            lock (StateLock)
            {
                targets = ReadAgentState()["agents"]!.AsArray().OfType<JsonObject>()
                    .Select(a => (a["id"]?.ToString() ?? "", a["expectedAddress"]?.ToString() ?? "",
                        a["probePort"]?.GetValue<int>() ?? 17832))
                    .Where(x => x.Item1.Length > 0 && x.Item2.Length > 0).ToList();
            }
            foreach (var target in targets)
            {
                var reachable = false;
                var error = "";
                try
                {
                    using var client = new TcpClient();
                    using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    linked.CancelAfter(TimeSpan.FromSeconds(2));
                    await client.ConnectAsync(target.Address, target.Port, linked.Token);
                    reachable = true;
                }
                catch (Exception ex) when (ex is SocketException or OperationCanceledException) { error = ex is OperationCanceledException ? "Тайм-аут" : ex.Message; }
                lock (StateLock)
                {
                    var state = ReadAgentState();
                    var agent = state["agents"]!.AsArray().OfType<JsonObject>().FirstOrDefault(a => a["id"]?.ToString() == target.Id);
                    if (agent is not null)
                    {
                        agent["probeOnline"] = reachable;
                        agent["probeCheckedAt"] = DateTimeOffset.Now;
                        agent["probeError"] = error;
                        WriteAgentState(state);
                    }
                }
            }
            try { await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken); } catch (OperationCanceledException) { break; }
        }
    }

    private HubResponse Heartbeat(string authorization, JsonObject body)
    {
        var token = authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            ? authorization[7..].Trim() : "";
        if (token.Length == 0) return new(401, new JsonObject { ["error"] = "Токен агента не передан." });
        var agentId = body["agentId"]?.ToString() ?? "";

        var reportChanged = false;
        HubResponse response;
        lock (StateLock)
        {
            var state = ReadAgentState();
            var agent = state["agents"]!.AsArray().OfType<JsonObject>().FirstOrDefault(a =>
                string.Equals(a["id"]?.ToString(), agentId, StringComparison.Ordinal));
            if (agent is null || !CryptographicOperations.FixedTimeEquals(
                    Encoding.UTF8.GetBytes(agent["tokenHash"]?.ToString() ?? ""), Encoding.UTF8.GetBytes(HashToken(token))))
                return new(401, new JsonObject { ["error"] = "Агент не авторизован." });

            agent["host"] = NormalizeHost(body["host"]?.ToString());
            agent["displayName"] = body["displayName"]?.ToString() ?? agent["host"]?.ToString();
            agent["version"] = body["version"]?.ToString() ?? "unknown";
            agent["lastSeen"] = DateTimeOffset.Now;
            agent["online"] = true;
            var previousReport = agent["report"]?.ToJsonString() ?? "";
            var incomingReport = body["report"]?.ToJsonString() ?? "";
            reportChanged = !string.Equals(previousReport, incomingReport, StringComparison.Ordinal);
            agent["report"] = body["report"]?.DeepClone();
            if (body["commandResults"] is JsonArray commandResults)
            {
                foreach (var result in commandResults.OfType<JsonObject>())
                {
                    var operationId = result["id"]?.ToString() ?? "";
                    if (!Guid.TryParse(operationId, out _)) continue;
                    var managerResult = (JsonObject)result.DeepClone();
                    managerResult["source"] = "agent";
                    managerResult["agentId"] = agentId;
                    managerResult["agent"] = agent["displayName"]?.ToString() ?? agent["host"]?.ToString();
                    ApiBridge.WriteAgentUploadStatus(operationId, managerResult);
                    if (string.Equals(managerResult["status"]?.ToString(), "FINISHED", StringComparison.OrdinalIgnoreCase))
                        ApiBridge.ApplyAgentUploadResult(managerResult);
                }
            }
            var assignments = agent["assignedJobs"]?.DeepClone() ?? new JsonArray();
            var forceJob = agent["forceCheckJob"]?.ToString() ?? "";
            var commands = agent["pendingCommands"]?.DeepClone() ?? new JsonArray();
            agent.Remove("pendingCommands");
            agent.Remove("forceCheckJob");agent.Remove("forceCheckRequestedAt");
            WriteAgentState(state);
            response = new(200, new JsonObject { ["ok"] = true, ["serverTime"] = DateTimeOffset.Now, ["assignments"] = assignments, ["forceCheckJob"] = forceJob, ["commands"] = commands });
        }
        if (reportChanged)
            _ = Task.Run(() => { try { AppPaths.GenerateDashboard(); } catch (Exception ex) { AppLog.Warn("Agent Hub: не удалось обновить Dashboard после отчёта агента: " + ex.Message); } });
        return response;
    }

    private static string NormalizeHost(string? host) => (host ?? "").Trim().ToUpperInvariant();
    private static string HashToken(string token) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();

    private void EnsureEnrollmentCode()
    {
        lock (StateLock)
        {
            var settings = ReadSettings();
            if (string.IsNullOrWhiteSpace(settings["AgentEnrollmentCode"]?.ToString()))
            {
                settings["AgentEnrollmentCode"] = Convert.ToHexString(RandomNumberGenerator.GetBytes(6));
                WriteAtomic(AppPaths.SettingsPath, settings);
            }
        }
    }

    private static JsonObject ReadSettings() => ReadObject(AppPaths.SettingsPath, new JsonObject());
    private static JsonObject ReadAgentState() => ReadObject(AppPaths.AgentStatePath,
        new JsonObject { ["schemaVersion"] = 1, ["agents"] = new JsonArray() });
    private static void WriteAgentState(JsonObject value) => WriteAtomic(AppPaths.AgentStatePath, value);

    private static JsonObject ReadObject(string path, JsonObject fallback)
    {
        try { return File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path, Encoding.UTF8))?.AsObject() ?? fallback : fallback; }
        catch { return fallback; }
    }

    private static void WriteAtomic(string path, JsonObject value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllText(temp, value.ToJsonString(JsonOptions), new UTF8Encoding(false));
        File.Move(temp, path, true);
    }

    private static async Task<HubRequest> ReadRequestAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        using var reader = new StreamReader(stream, Encoding.ASCII, false, 4096, leaveOpen: true);
        var requestLine = await reader.ReadLineAsync(cancellationToken) ?? throw new InvalidDataException("Пустой HTTP-запрос.");
        var parts = requestLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) throw new InvalidDataException("Некорректная строка HTTP-запроса.");
        var contentLength = 0;
        var authorization = "";
        while (true)
        {
            var line = await reader.ReadLineAsync(cancellationToken);
            if (string.IsNullOrEmpty(line)) break;
            var separator = line.IndexOf(':');
            if (separator < 1) continue;
            var name = line[..separator].Trim();
            var value = line[(separator + 1)..].Trim();
            if (name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) int.TryParse(value, out contentLength);
            if (name.Equals("Authorization", StringComparison.OrdinalIgnoreCase)) authorization = value;
        }
        if (contentLength < 0 || contentLength > MaxBodyBytes) throw new InvalidDataException("Слишком большой запрос агента.");
        var chars = new char[contentLength];
        var read = 0;
        while (read < chars.Length)
        {
            var count = await reader.ReadAsync(chars.AsMemory(read, chars.Length - read), cancellationToken);
            if (count == 0) break;
            read += count;
        }
        var bodyText = new string(chars, 0, read);
        var body = string.IsNullOrWhiteSpace(bodyText) ? new JsonObject() : JsonNode.Parse(bodyText)?.AsObject() ?? new JsonObject();
        return new(parts[0].ToUpperInvariant(), parts[1].Split('?')[0].ToLowerInvariant(), authorization, body);
    }

    private static async Task WriteResponseAsync(NetworkStream stream, int status, JsonObject body, CancellationToken cancellationToken)
    {
        var bytes = Encoding.UTF8.GetBytes(body.ToJsonString(JsonOptions));
        var reason = status is >= 200 and < 300 ? "OK" : "Error";
        var headers = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {bytes.Length}\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(headers, cancellationToken);
        await stream.WriteAsync(bytes, cancellationToken);
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener?.Stop();
        try { _loop?.Wait(1000); } catch { }
        try { _probeLoop?.Wait(1000); } catch { }
        _stop.Dispose();
    }

    private sealed record HubRequest(string Method, string Path, string Authorization, JsonObject Body);
    private sealed record HubResponse(int Status, JsonObject Body);
}
