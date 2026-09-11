using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BackupS3Manager.Server;

internal sealed class ServerStore
{
    private readonly object _gate = new();
    private readonly string _path;
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public ServerStore(IConfiguration configuration)
    {
        var root = configuration["BS3_DATA_DIR"] ?? "/var/lib/backups3-manager";
        Directory.CreateDirectory(root);
        _path = Path.Combine(root, "server-state.json");
        lock (_gate)
        {
            var state = ReadUnsafe();
            if (string.IsNullOrWhiteSpace(state["enrollmentCode"]?.ToString()))
                state["enrollmentCode"] = Convert.ToHexString(RandomNumberGenerator.GetBytes(6));
            WriteUnsafe(state);
        }
    }

    public JsonObject Snapshot()
    {
        lock (_gate) return (JsonObject)ReadUnsafe().DeepClone();
    }

    public JsonObject Enroll(string code, string host, string displayName, string version)
    {
        lock (_gate)
        {
            var state = ReadUnsafe();
            var expected = state["enrollmentCode"]?.ToString() ?? "";
            if (!FixedEquals(expected, code)) throw new UnauthorizedAccessException("Неверный код подключения.");
            var agents = state["agents"]!.AsArray();
            var normalizedHost = host.Trim().ToUpperInvariant();
            var agent = agents.OfType<JsonObject>().FirstOrDefault(x =>
                string.Equals(x["host"]?.ToString(), normalizedHost, StringComparison.OrdinalIgnoreCase));
            if (agent is null) { agent = new JsonObject(); agents.Add(agent); }
            var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
            agent["id"] = agent["id"]?.ToString() ?? Guid.NewGuid().ToString("N");
            agent["tokenHash"] = Hash(token);
            agent["host"] = normalizedHost;
            agent["displayName"] = string.IsNullOrWhiteSpace(displayName) ? normalizedHost : displayName.Trim();
            agent["version"] = version;
            agent["online"] = true;
            agent["lastSeen"] = DateTimeOffset.UtcNow;
            agent["assignedJobs"] ??= new JsonArray();
            WriteUnsafe(state);
            return new JsonObject { ["agentId"] = agent["id"]!.ToString(), ["token"] = token, ["pollSeconds"] = 15 };
        }
    }

    public JsonObject Heartbeat(string agentId, string bearerToken, JsonNode? report)
    {
        lock (_gate)
        {
            var state = ReadUnsafe();
            var agent = state["agents"]!.AsArray().OfType<JsonObject>()
                .FirstOrDefault(x => x["id"]?.ToString() == agentId)
                ?? throw new UnauthorizedAccessException("Агент не зарегистрирован.");
            if (!FixedEquals(agent["tokenHash"]?.ToString() ?? "", Hash(bearerToken)))
                throw new UnauthorizedAccessException("Токен агента отклонён.");
            agent["lastSeen"] = DateTimeOffset.UtcNow;
            agent["online"] = true;
            agent["report"] = report?.DeepClone();
            var assignments = agent["assignedJobs"]?.DeepClone() ?? new JsonArray();
            var commands = agent["pendingCommands"]?.DeepClone() ?? new JsonArray();
            agent["pendingCommands"] = new JsonArray();
            WriteUnsafe(state);
            return new JsonObject
            {
                ["ok"] = true, ["serverTime"] = DateTimeOffset.UtcNow,
                ["assignments"] = assignments, ["commands"] = commands
            };
        }
    }

    public JsonArray AgentsForDashboard()
    {
        lock (_gate)
        {
            var state = ReadUnsafe();
            var result = new JsonArray();
            foreach (var source in state["agents"]!.AsArray().OfType<JsonObject>())
            {
                var item = (JsonObject)source.DeepClone();
                item.Remove("tokenHash");
                var online = DateTimeOffset.TryParse(item["lastSeen"]?.ToString(), out var seen) &&
                             DateTimeOffset.UtcNow - seen < TimeSpan.FromSeconds(45);
                item["online"] = online;
                result.Add(item);
            }
            return result;
        }
    }

    public JsonObject PublicSettings()
    {
        lock (_gate)
        {
            var state = ReadUnsafe();
            return new JsonObject { ["enrollmentCode"] = state["enrollmentCode"]?.ToString(), ["version"] = "25.0.0" };
        }
    }

    private JsonObject ReadUnsafe()
    {
        try
        {
            if (File.Exists(_path) && JsonNode.Parse(File.ReadAllText(_path, Encoding.UTF8)) is JsonObject saved)
            {
                saved["agents"] ??= new JsonArray();
                return saved;
            }
        }
        catch { }
        return new JsonObject { ["schemaVersion"] = 1, ["agents"] = new JsonArray() };
    }

    private void WriteUnsafe(JsonObject state)
    {
        var temporary = _path + ".tmp";
        File.WriteAllText(temporary, state.ToJsonString(JsonOptions), new UTF8Encoding(false));
        File.Move(temporary, _path, true);
    }

    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
    private static bool FixedEquals(string left, string right)
    {
        var a = Encoding.UTF8.GetBytes(left); var b = Encoding.UTF8.GetBytes(right);
        return a.Length == b.Length && CryptographicOperations.FixedTimeEquals(a, b);
    }
}
