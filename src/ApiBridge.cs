using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;
using Microsoft.Web.WebView2.Core;

namespace BackupS3Manager;

internal sealed record ApiResponse(
    int StatusCode,
    string Reason,
    byte[] Body,
    string ContentType = "application/json; charset=utf-8",
    string? ExtraHeaders = null)
{
    private static readonly JsonSerializerOptions CompactJson = new()
    {
        WriteIndented = false,
        TypeInfoResolver = new DefaultJsonTypeInfoResolver()
    };

    public static ApiResponse Json(int status, object value) =>
        new(status,
            status is >= 200 and < 300 ? "OK" : "Error",
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value, CompactJson)),
            "application/json; charset=utf-8");

    public static ApiResponse JsonText(int status, string json) =>
        new(status, status is >= 200 and < 300 ? "OK" : "Error",
            Encoding.UTF8.GetBytes(json), "application/json; charset=utf-8");

    public static ApiResponse Text(int status, string text, string contentType = "text/plain; charset=utf-8") =>
        new(status, status is >= 200 and < 300 ? "OK" : "Error",
            Encoding.UTF8.GetBytes(text), contentType);
}

internal sealed class ApiBridge
{
    private const string CurrentVersion = "23.14";
    private const string DefaultUpdateManifestUrl = "https://github.com/Claptone007/BackupS3-Manager/releases/latest/download/manifest.json";
    private static readonly HttpClient UpdateHttp = new() { Timeout = TimeSpan.FromSeconds(25) };
    private static readonly object AuditLock = new();
    private static readonly object HistoryLock = new();
    private JsonObject? _configCache;
    private DateTime _configMtime;
    private readonly Func<string?, Task<string?>> _browseFolder;

    public ApiBridge(Func<string?, Task<string?>> browseFolder) => _browseFolder = browseFolder;

    public async Task<ApiResponse> HandleAsync(string method, Uri uri, string body)
    {
        var path = uri.AbsolutePath.ToLowerInvariant();
        try
        {
            var q = ParseQuery(uri.Query);

            var response = (method.ToUpperInvariant(), path) switch
            {
                ("GET", "/api/health") => ApiResponse.Json(200, new {
                    ok = true,
                    serverTime = DateTimeOffset.Now,
                    appRoot = AppPaths.DataRoot,
                    controllerExists = File.Exists(AppPaths.BackupScript),
                    mode = "Desktop/WebView2"
                }),

                ("GET", "/api/version") => ApiResponse.Json(200, new {
                    version = CurrentVersion,
                    name = "BackupS3 Manager Desktop"
                }),
                ("GET", "/api/update/check") => await CheckForUpdateAsync(),
                ("POST", "/api/update/download") => await DownloadUpdateAsync(),

                ("GET", "/api/progress") => ReadJsonFile(AppPaths.ProgressPath,
                    """{"running":false,"current":0,"total":0,"percent":0,"database":"","phase":"IDLE","message":"Ожидание запуска","checked":[]}"""),

                ("GET", "/api/state") => await StateSummaryAsync(),
                ("GET", "/api/controller-status") => ControllerStatus(),
                ("POST", "/api/refresh") => await StartControllerAsync(Array.Empty<string>()),
                ("POST", "/api/jobs/check") => await StartSingleAsync(body),
                ("POST", "/api/jobs/check-selected") => await StartSelectedAsync(body),
                ("POST", "/api/cancel") => CancelController(),

                ("GET", "/api/settings") => await GetSettingsAsync(),
                ("POST", "/api/settings") => await SaveSettingsAsync(body),
                ("GET", "/api/scheduler/status") => SchedulerStatus(),
                ("POST", "/api/scheduler/run") => await RunSchedulerAsync(),

                ("GET", "/api/ui-settings") => GetUiSettings(),
                ("POST", "/api/ui-settings/job") => SaveUiJob(body),
                ("POST", "/api/ui-settings/global") => SaveUiGlobal(body),

                ("GET", "/api/config-profiles") => ListConfigProfiles(),
                ("POST", "/api/config-profiles/save") => await SaveConfigProfileAsync(body),
                ("POST", "/api/config-profiles/load") => LoadConfigProfile(body),
                ("POST", "/api/config-profiles/delete") => DeleteConfigProfile(body),
                ("GET", "/api/config-profiles/export") => ExportConfigProfile(q.GetValueOrDefault("name", "")),
                ("POST", "/api/config-profiles/import") => ImportConfigProfile(body),
                ("GET", "/api/startup-workspace") => StartupWorkspaceStatus(),
                ("POST", "/api/startup-workspace/select") => await SelectStartupWorkspaceAsync(body),

                ("GET", "/api/s3-profiles") => ListS3Profiles(revealSecrets: false),
                ("POST", "/api/s3-profiles/reveal") => RevealS3Profile(body),
                ("POST", "/api/s3-profiles/save") => SaveS3Profile(body),
                ("POST", "/api/s3-profiles/delete") => DeleteS3Profile(body),
                ("POST", "/api/s3-profiles/test") => await TestS3ProfileAsync(body),

                ("GET", "/api/jobs/detail") => await JobDetailAsync(q.GetValueOrDefault("name", "")),
                ("GET", "/api/jobs/local-files") => await LocalFilesAsync(q.GetValueOrDefault("name", "")),
                ("GET", "/api/jobs/s3-objects") => await S3ObjectsAsync(q.GetValueOrDefault("name", "")),
                ("POST", "/api/jobs/add") => await AddJobAsync(body),
                ("POST", "/api/jobs/update") => await UpdateJobAsync(body),
                ("POST", "/api/jobs/delete") => await DeleteJobAsync(body),
                ("POST", "/api/jobs/delete-selected") => await DeleteJobsAsync(body),

                ("POST", "/api/jobs/local-upload") => await ManualUploadStartAsync(body),
                ("GET", "/api/jobs/local-upload-status") => ManualUploadStatus(q.GetValueOrDefault("id", "")),

                ("POST", "/api/s3/object/delete") => await DeleteS3ObjectAsync(body),
                ("POST", "/api/retention/preview") => await RetentionPreviewAsync(body),
                ("POST", "/api/retention/apply") => await RetentionApplyAsync(body),

                ("POST", "/api/maintenance/set") => MaintenanceSet(body),
                ("POST", "/api/maintenance/clear") => MaintenanceClear(body),

                ("GET", "/api/log") => LogAsync(q),
                ("GET", "/api/browse-folder") => await BrowseFolderAsync(q.GetValueOrDefault("initialPath", "")),
                ("GET", "/api/s3-folders") => await S3FoldersAsync(q),
                ("GET", "/api/s3-connections") => await S3ConnectionsAsync(),
                ("GET", "/api/upload-progress") => UploadProgress(),
                ("GET", "/api/jobs/export-ps1") => await ExportJobScriptAsync(q.GetValueOrDefault("name", "")),
                ("GET", "/api/report") => await ReportAsync(q),

                ("POST", "/api/server/restart") => ApiResponse.Json(200, new { status = "desktop_reload" }),

                _ => ApiResponse.Json(404, new { error = $"Unknown desktop API route: {method} {path}" })
            };

            if (!method.Equals("GET", StringComparison.OrdinalIgnoreCase))
                WriteAudit(response.StatusCode is >= 200 and < 300 ? "INFO" : "ERROR",
                    DescribeAuditAction(path), DescribeAuditTarget(body), response.StatusCode);

            return response;
        }
        catch (Exception ex)
        {
            if (!method.Equals("GET", StringComparison.OrdinalIgnoreCase))
                WriteAudit("ERROR", DescribeAuditAction(path), DescribeAuditTarget(body), 500, ex.Message);
            return ApiResponse.Json(500, new { error = ex.Message });
        }
    }

    private static string DescribeAuditTarget(string body)
    {
        try
        {
            var request = ParseBody(body);
            if (request["Names"] is JsonArray names)
            {
                var safeNames = names.Select(n => n?.ToString() ?? "").Where(n => n.Length > 0).Take(100).ToArray();
                return safeNames.Length == 0 ? "" : $"[{safeNames.Length} баз] " + string.Join(", ", safeNames);
            }
            var name = request["Name"]?.ToString() ?? request["Database"]?.ToString() ?? "";
            return name.Length == 0 ? "" : $"[{name}]";
        }
        catch { return ""; }
    }

    private static string DescribeAuditAction(string path) => path switch
    {
        "/api/jobs/add" => "Добавление базы",
        "/api/jobs/update" => "Изменение базы",
        "/api/jobs/delete" => "Удаление базы",
        "/api/jobs/delete-selected" => "Групповое удаление баз",
        "/api/jobs/check" => "Проверка базы",
        "/api/jobs/check-selected" => "Проверка выбранных баз",
        "/api/refresh" => "Проверка всех баз",
        "/api/settings" => "Изменение настроек",
        "/api/config-profiles/save" => "Сохранение профиля конфигурации",
        "/api/config-profiles/load" => "Загрузка профиля конфигурации",
        "/api/config-profiles/delete" => "Удаление профиля конфигурации",
        "/api/config-profiles/import" => "Импорт профиля конфигурации",
        "/api/s3-profiles/save" => "Сохранение S3-профиля",
        "/api/s3-profiles/delete" => "Удаление S3-профиля",
        "/api/s3-profiles/test" => "Проверка S3-профиля",
        "/api/jobs/local-upload" => "Ручная загрузка на S3",
        "/api/s3/object/delete" => "Удаление объекта S3",
        "/api/retention/apply" => "Очистка S3 по хранению",
        "/api/cancel" => "Остановка проверки",
        _ => path
    };

    private static void WriteAudit(string level, string action, string target, int statusCode, string? details = null)
    {
        try
        {
            lock (AuditLock)
            {
                Directory.CreateDirectory(AppPaths.LogsDir);
                var path = Path.Combine(AppPaths.LogsDir, "audit.log");
                if (File.Exists(path) && new FileInfo(path).Length > 5 * 1024 * 1024)
                {
                    var archive = path + ".1";
                    if (File.Exists(archive)) File.Delete(archive);
                    File.Move(path, archive);
                }
                var user = Environment.UserName;
                var computer = Environment.MachineName;
                var suffix = string.IsNullOrWhiteSpace(details) ? "" : " · " + details.Replace('\r', ' ').Replace('\n', ' ');
                var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz} [{level}] [{user}@{computer}] {action} {target} · HTTP {statusCode}{suffix}";
                File.AppendAllText(path, line + Environment.NewLine, new UTF8Encoding(false));
            }
        }
        catch
        {
            // Audit must never break the requested operation.
        }
    }

    private static void AppendHistoryEvent(string eventName, string database, string message)
    {
        try
        {
            lock (HistoryLock)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(AppPaths.HistoryPath)!);
                var item = new JsonObject
                {
                    ["timestamp"] = DateTimeOffset.Now.ToString("o"),
                    ["database"] = database,
                    ["event"] = eventName,
                    ["message"] = message,
                    ["file"] = "",
                    ["sizeBytes"] = 0
                };
                File.AppendAllText(AppPaths.HistoryPath,
                    item.ToJsonString(CompactJsonOptions) + Environment.NewLine,
                    new UTF8Encoding(false));
            }
        }
        catch
        {
            // History must never roll back an already completed configuration change.
        }
    }

    private static readonly JsonSerializerOptions CompactJsonOptions = new()
    {
        WriteIndented = false,
        TypeInfoResolver = new DefaultJsonTypeInfoResolver()
    };

    private static Dictionary<string,string> ParseQuery(string query)
    {
        var d = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = p.Split('=', 2);
            d[Uri.UnescapeDataString(kv[0])] = kv.Length > 1 ? Uri.UnescapeDataString(kv[1].Replace("+"," ")) : "";
        }
        return d;
    }

    private static ApiResponse ReadJsonFile(string path, string fallback)
    {
        if (!File.Exists(path)) return ApiResponse.JsonText(200, fallback);
        return ApiResponse.JsonText(200, File.ReadAllText(path, Encoding.UTF8));
    }

    private async Task<JsonObject> ConfigAsync()
    {
        var mt = File.Exists(AppPaths.ConfigPath) ? File.GetLastWriteTimeUtc(AppPaths.ConfigPath) : DateTime.MinValue;
        if (_configCache is not null && mt == _configMtime) return _configCache;

        var script = "$c=Import-PowerShellDataFile -Path $desktopArgs[0];$c|ConvertTo-Json -Depth 40 -Compress";
        var r = await RunPowerShellCommandAsync(script, AppPaths.ConfigPath);
        if (r.ExitCode != 0)
            throw new InvalidOperationException("BackupJobs.psd1: " + r.Output);

        var json = r.StdOut.Trim();
        if (string.IsNullOrWhiteSpace(json))
            throw new InvalidOperationException("BackupJobs.psd1: PowerShell вернул пустой JSON.");

        try
        {
            _configCache = JsonNode.Parse(json)!.AsObject();
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                "BackupJobs.psd1: не удалось разобрать JSON конфигурации. " +
                $"PowerShell stdout начинается с: {json[..Math.Min(json.Length, 300)]}. " +
                $"Ошибка: {ex.Message}");
        }
        _configMtime = mt;
        return _configCache;
    }

    private async Task<JsonArray> EffectiveJobsAsync()
    {
        var cfg = await ConfigAsync();
        var jobs = new Dictionary<string,JsonObject>(StringComparer.OrdinalIgnoreCase);

        foreach (var n in cfg["Jobs"]?.AsArray() ?? new JsonArray())
            if (n is JsonObject o && o["Name"] is not null)
                jobs[o["Name"]!.GetValue<string>()] = (JsonObject)o.DeepClone();

        var m = ReadObject(AppPaths.ManagedJobsPath, new JsonObject {
            ["AddedJobs"] = new JsonArray(),
            ["DeletedNames"] = new JsonArray(),
            ["Overrides"] = new JsonObject()
        });

        foreach (var n in m["AddedJobs"]?.AsArray() ?? new JsonArray())
            if (n is JsonObject o && o["Name"] is not null)
                jobs[o["Name"]!.GetValue<string>()] = (JsonObject)o.DeepClone();

        var deleted = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var n in m["DeletedNames"]?.AsArray() ?? new JsonArray())
            if (n is not null) deleted.Add(n.GetValue<string>());

        foreach (var name in deleted) jobs.Remove(name);

        if (m["Overrides"] is JsonObject ovs)
        {
            foreach (var kv in ovs)
            {
                if (!jobs.TryGetValue(kv.Key, out var j) || kv.Value is not JsonObject patch) continue;
                foreach (var p in patch) j[p.Key] = p.Value?.DeepClone();
            }
        }

        var result = new JsonArray();
        foreach (var j in jobs.Values.OrderBy(x => x["Name"]?.GetValue<string>(), StringComparer.OrdinalIgnoreCase))
            result.Add(j);
        return result;
    }

    private async Task<JsonObject?> EffectiveJobAsync(string name)
    {
        foreach (var n in await EffectiveJobsAsync())
            if (n is JsonObject o && string.Equals(o["Name"]?.GetValue<string>(), name, StringComparison.OrdinalIgnoreCase))
                return o;
        return null;
    }

    private static JsonObject ReadObject(string path, JsonObject fallback)
    {
        try
        {
            if (File.Exists(path) && JsonNode.Parse(File.ReadAllText(path, Encoding.UTF8)) is JsonObject o) return o;
        }
        catch {}
        return (JsonObject)fallback.DeepClone();
    }

    private static void WriteObjectAtomic(string path, JsonObject obj)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp";
        var options = new JsonSerializerOptions
        {
            WriteIndented = true,
            TypeInfoResolver = new DefaultJsonTypeInfoResolver()
        };
        File.WriteAllText(tmp, obj.ToJsonString(options), new UTF8Encoding(true));
        File.Move(tmp, path, true);
    }

    private static JsonObject ParseBody(string body) =>
        JsonNode.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body)?.AsObject() ?? new JsonObject();

    private static string SafeProfileName(string? value)
    {
        var name = (value ?? "").Trim();
        if (name.Length is < 1 or > 80 || name.Any(ch => !(char.IsLetterOrDigit(ch) || ch is '-' or '_' or ' ' or '.')))
            throw new InvalidOperationException("Имя профиля должно содержать 1–80 букв, цифр, пробелов или символов - _ .");
        return name;
    }

    private static string ConfigProfilePath(string name) =>
        Path.Combine(AppPaths.ProfilesDir, SafeProfileName(name) + ".json");

    private static ApiResponse ListConfigProfiles()
    {
        Directory.CreateDirectory(AppPaths.ProfilesDir);
        var profiles = Directory.EnumerateFiles(AppPaths.ProfilesDir, "*.json")
            .Select(path => new FileInfo(path))
            .OrderByDescending(x => x.LastWriteTimeUtc)
            .Select(x => new { name = Path.GetFileNameWithoutExtension(x.Name), updatedAt = x.LastWriteTime, sizeBytes = x.Length })
            .ToArray();
        return ApiResponse.Json(200, new { profiles });
    }

    private async Task<ApiResponse> SaveConfigProfileAsync(string body)
    {
        var request = ParseBody(body);
        var name = SafeProfileName(request["Name"]?.ToString());
        var bundle = new JsonObject
        {
            ["format"] = "BackupS3Manager.Profile",
            ["version"] = 1,
            ["name"] = name,
            ["savedAt"] = DateTimeOffset.Now.ToString("o"),
            ["jobs"] = await EffectiveJobsAsync(),
            ["settings"] = File.Exists(AppPaths.SettingsPath)
                ? JsonNode.Parse(File.ReadAllText(AppPaths.SettingsPath, Encoding.UTF8))
                : new JsonObject(),
            ["uiSettings"] = File.Exists(AppPaths.UiSettingsPath)
                ? JsonNode.Parse(File.ReadAllText(AppPaths.UiSettingsPath, Encoding.UTF8))
                : new JsonObject()
        };
        WriteObjectAtomic(ConfigProfilePath(name), bundle);
        return ApiResponse.Json(200, new { status = "saved", name });
    }

    private static JsonObject ValidateConfigProfile(JsonObject profile)
    {
        if (profile["format"]?.ToString() != "BackupS3Manager.Profile" || profile["jobs"] is not JsonArray)
            throw new InvalidOperationException("Файл не является профилем Backup S3 Manager.");
        return profile;
    }

    private ApiResponse LoadConfigProfile(string body)
    {
        var name = SafeProfileName(ParseBody(body)["Name"]?.ToString());
        var path = ConfigProfilePath(name);
        if (!File.Exists(path)) return ApiResponse.Json(404, new { error = "Профиль не найден" });
        var profile = ValidateConfigProfile(JsonNode.Parse(File.ReadAllText(path, Encoding.UTF8))!.AsObject());
        var managed = new JsonObject
        {
            ["AddedJobs"] = profile["jobs"]!.DeepClone(),
            ["DeletedNames"] = new JsonArray(),
            ["Overrides"] = new JsonObject()
        };
        WriteObjectAtomic(AppPaths.ManagedJobsPath, managed);
        if (profile["settings"] is JsonObject settings) WriteObjectAtomic(AppPaths.SettingsPath, (JsonObject)settings.DeepClone());
        if (profile["uiSettings"] is JsonObject ui) WriteObjectAtomic(AppPaths.UiSettingsPath, (JsonObject)ui.DeepClone());
        AppPaths.GenerateDashboard();
        return ApiResponse.Json(200, new { status = "loaded", name, restartRecommended = false });
    }

    private static ApiResponse DeleteConfigProfile(string body)
    {
        var name = SafeProfileName(ParseBody(body)["Name"]?.ToString());
        var path = ConfigProfilePath(name);
        if (File.Exists(path)) File.Delete(path);
        return ApiResponse.Json(200, new { status = "deleted", name });
    }

    private static ApiResponse ExportConfigProfile(string name)
    {
        name = SafeProfileName(name);
        var path = ConfigProfilePath(name);
        if (!File.Exists(path)) return ApiResponse.Json(404, new { error = "Профиль не найден" });
        var encoded = Uri.EscapeDataString($"BackupS3-profile-{name}.json");
        var headers = $"Content-Disposition: attachment; filename=\"BackupS3-profile.json\"; filename*=UTF-8''{encoded}\r\n";
        return new ApiResponse(200, "OK", File.ReadAllBytes(path), "application/json; charset=utf-8", headers);
    }

    private static ApiResponse ImportConfigProfile(string body)
    {
        var request = ParseBody(body);
        var profile = ValidateConfigProfile(request["Profile"]?.AsObject() ?? throw new InvalidOperationException("В запросе отсутствует Profile"));
        var name = SafeProfileName(request["Name"]?.ToString() ?? profile["name"]?.ToString());
        profile["name"] = name;
        profile["importedAt"] = DateTimeOffset.Now.ToString("o");
        WriteObjectAtomic(ConfigProfilePath(name), profile);
        return ApiResponse.Json(200, new { status = "imported", name });
    }

    private static string StartupWorkspacePath => Path.Combine(AppPaths.StateDir, "startup-workspace.json");

    private static ApiResponse StartupWorkspaceStatus()
    {
        var firstRun = !File.Exists(StartupWorkspacePath);
        var state = ReadObject(StartupWorkspacePath, new JsonObject { ["mode"] = "saved" });
        return ApiResponse.Json(200, new {
            mode = state["mode"]?.ToString() ?? "saved",
            firstRun,
            recommendedMode = firstRun ? "new" : state["mode"]?.ToString() ?? "saved",
            autoEnter = state["autoEnter"]?.GetValue<bool>() ?? false,
            savedProfileExists = File.Exists(ConfigProfilePath("Сохраненная конфигурация")),
            newProfileExists = File.Exists(ConfigProfilePath("Новая конфигурация"))
        });
    }

    private async Task<ApiResponse> SelectStartupWorkspaceAsync(string body)
    {
        var request = ParseBody(body);
        var requested = request["Mode"]?.ToString()?.ToLowerInvariant();
        if (requested is not ("saved" or "new"))
            return ApiResponse.Json(400, new { error = "Неизвестный вариант конфигурации." });
        var firstRun = !File.Exists(StartupWorkspacePath);
        var state = ReadObject(StartupWorkspacePath, new JsonObject { ["mode"] = "saved" });
        var current = state["mode"]?.ToString() ?? "saved";

        if (requested == "new")
        {
            if (!firstRun && current != "new") await SaveConfigProfileAsync("{\"Name\":\"Сохраненная конфигурация\"}");
            else if (File.Exists(ConfigProfilePath("Новая конфигурация"))) LoadConfigProfile("{\"Name\":\"Новая конфигурация\"}");

            if (current != "new")
            {
                var effective = await EffectiveJobsAsync();
                var deleted = new JsonArray(effective.Select(j => (JsonNode?)j?["Name"]?.ToString()).Where(x => x is not null).ToArray());
                WriteObjectAtomic(AppPaths.ManagedJobsPath, new JsonObject {
                    ["AddedJobs"] = new JsonArray(), ["DeletedNames"] = deleted, ["Overrides"] = new JsonObject()
                });
                WriteObjectAtomic(AppPaths.UiSettingsPath, new JsonObject { ["Jobs"] = new JsonObject(), ["DefaultSort"] = "name", ["ShowFavorites"] = true });
            }
        }
        else if (current == "new")
        {
            await SaveConfigProfileAsync("{\"Name\":\"Новая конфигурация\"}");
            if (File.Exists(ConfigProfilePath("Сохраненная конфигурация")))
                LoadConfigProfile("{\"Name\":\"Сохраненная конфигурация\"}");
        }

        state["mode"] = requested;
        state["autoEnter"] = request["AutoEnter"]?.GetValue<bool>() ?? state["autoEnter"]?.GetValue<bool>() ?? false;
        state["selectedAt"] = DateTimeOffset.Now.ToString("o");
        WriteObjectAtomic(StartupWorkspacePath, state);
        AppPaths.GenerateDashboard();
        AppLog.Info(requested == "new" ? "Открыта новая пустая конфигурация" : "Открыта сохраненная конфигурация");
        return ApiResponse.Json(200, new { status = "selected", mode = requested, reload = true });
    }

    private static Dictionary<string, Dictionary<string, string>> ReadIni(string path)
    {
        var result = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
        if (!File.Exists(path)) return result;
        Dictionary<string, string>? current = null;
        foreach (var raw in File.ReadAllLines(path, Encoding.UTF8))
        {
            var line = raw.Trim();
            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                var section = line[1..^1].Trim();
                current = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                result[section] = current;
            }
            else if (current is not null && line.Length > 0 && !line.StartsWith('#') && !line.StartsWith(';'))
            {
                var pos = line.IndexOf('=');
                if (pos > 0) current[line[..pos].Trim()] = line[(pos + 1)..].Trim();
            }
        }
        return result;
    }

    private static void WriteIni(string path, Dictionary<string, Dictionary<string, string>> data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var sb = new StringBuilder();
        foreach (var section in data.OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
        {
            sb.Append('[').Append(section.Key).AppendLine("]");
            foreach (var item in section.Value.OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
                sb.Append(item.Key).Append(" = ").AppendLine(item.Value);
            sb.AppendLine();
        }
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));
        File.Move(tmp, path, true);
    }

    private static JsonObject S3ProfileJson(string name, Dictionary<string, string> credentials, Dictionary<string, string>? config, bool reveal)
    {
        string Mask(string value) => value.Length <= 4 ? "••••" : new string('•', Math.Min(12, value.Length - 4)) + value[^4..];
        var access = credentials.GetValueOrDefault("aws_access_key_id", "");
        var secret = credentials.GetValueOrDefault("aws_secret_access_key", "");
        var token = credentials.GetValueOrDefault("aws_session_token", "");
        return new JsonObject
        {
            ["name"] = name,
            ["accessKey"] = reveal ? access : Mask(access),
            ["secretKey"] = reveal ? secret : Mask(secret),
            ["sessionToken"] = reveal ? token : (token.Length > 0 ? Mask(token) : ""),
            ["region"] = config?.GetValueOrDefault("region", "") ?? "",
            ["endpoint"] = config?.GetValueOrDefault("endpoint_url", "") ?? "",
            ["hasAccessKey"] = access.Length > 0,
            ["hasSecretKey"] = secret.Length > 0,
            ["hasSessionToken"] = token.Length > 0,
            ["revealed"] = reveal
        };
    }

    private static ApiResponse ListS3Profiles(bool revealSecrets)
    {
        var credentials = ReadIni(AppPaths.AwsCredentialsPath);
        var config = ReadIni(AppPaths.AwsConfigPath);
        var profiles = new JsonArray();
        foreach (var item in credentials.OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
        {
            var configName = item.Key.Equals("default", StringComparison.OrdinalIgnoreCase) ? "default" : "profile " + item.Key;
            profiles.Add(S3ProfileJson(item.Key, item.Value, config.GetValueOrDefault(configName), revealSecrets));
        }
        return ApiResponse.JsonText(200, new JsonObject { ["profiles"] = profiles, ["credentialsFile"] = AppPaths.AwsCredentialsPath }.ToJsonString());
    }

    private static ApiResponse RevealS3Profile(string body)
    {
        var name = SafeProfileName(ParseBody(body)["Name"]?.ToString());
        var credentials = ReadIni(AppPaths.AwsCredentialsPath);
        if (!credentials.TryGetValue(name, out var values)) return ApiResponse.Json(404, new { error = "S3-профиль не найден" });
        var config = ReadIni(AppPaths.AwsConfigPath);
        var configName = name.Equals("default", StringComparison.OrdinalIgnoreCase) ? "default" : "profile " + name;
        return ApiResponse.JsonText(200, S3ProfileJson(name, values, config.GetValueOrDefault(configName), true).ToJsonString());
    }

    private static ApiResponse SaveS3Profile(string body)
    {
        var request = ParseBody(body);
        var name = SafeProfileName(request["Name"]?.ToString());
        var credentials = ReadIni(AppPaths.AwsCredentialsPath);
        var existing = credentials.GetValueOrDefault(name) ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var access = request["AccessKey"]?.ToString()?.Trim() ?? "";
        var secret = request["SecretKey"]?.ToString()?.Trim() ?? "";
        var token = request["SessionToken"]?.ToString()?.Trim() ?? "";
        if (access.Length > 0) existing["aws_access_key_id"] = access;
        if (secret.Length > 0) existing["aws_secret_access_key"] = secret;
        if (token.Length > 0) existing["aws_session_token"] = token; else existing.Remove("aws_session_token");
        if (!existing.ContainsKey("aws_access_key_id") || !existing.ContainsKey("aws_secret_access_key"))
            return ApiResponse.Json(400, new { error = "Укажите Access Key и Secret Key" });
        credentials[name] = existing;
        WriteIni(AppPaths.AwsCredentialsPath, credentials);

        var config = ReadIni(AppPaths.AwsConfigPath);
        var configName = name.Equals("default", StringComparison.OrdinalIgnoreCase) ? "default" : "profile " + name;
        var cfg = config.GetValueOrDefault(configName) ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var region = request["Region"]?.ToString()?.Trim() ?? "";
        var endpoint = request["Endpoint"]?.ToString()?.Trim() ?? "";
        if (region.Length > 0) cfg["region"] = region; else cfg.Remove("region");
        if (endpoint.Length > 0) cfg["endpoint_url"] = endpoint; else cfg.Remove("endpoint_url");
        config[configName] = cfg;
        WriteIni(AppPaths.AwsConfigPath, config);
        return ApiResponse.Json(200, new { status = "saved", name, credentialsFile = AppPaths.AwsCredentialsPath });
    }

    private static ApiResponse DeleteS3Profile(string body)
    {
        var name = SafeProfileName(ParseBody(body)["Name"]?.ToString());
        var credentials = ReadIni(AppPaths.AwsCredentialsPath);
        credentials.Remove(name);
        WriteIni(AppPaths.AwsCredentialsPath, credentials);
        var config = ReadIni(AppPaths.AwsConfigPath);
        config.Remove(name.Equals("default", StringComparison.OrdinalIgnoreCase) ? "default" : "profile " + name);
        WriteIni(AppPaths.AwsConfigPath, config);
        return ApiResponse.Json(200, new { status = "deleted", name });
    }

    private static async Task<ApiResponse> TestS3ProfileAsync(string body)
    {
        var request = ParseBody(body);
        var name = SafeProfileName(request["Name"]?.ToString());
        var endpoint = request["Endpoint"]?.ToString()?.Trim() ?? "";
        var args = new List<string>();
        if (endpoint.Length > 0) args.AddRange(new[] { "--endpoint-url", endpoint });
        args.AddRange(new[] { "--profile", name, "s3api", "list-buckets", "--output", "json" });
        var result = await RunProcessAsync("aws", args, AppPaths.DataRoot);
        return result.ExitCode == 0
            ? ApiResponse.Json(200, new { ok = true, message = "Подключение успешно" })
            : ApiResponse.Json(400, new { ok = false, error = result.Output });
    }

    private static JsonObject? FindStateJob(string name)
    {
        try
        {
            if (!File.Exists(AppPaths.StatePath)) return null;
            var state = JsonNode.Parse(File.ReadAllText(AppPaths.StatePath, Encoding.UTF8))?.AsObject();
            foreach (var n in state?["Jobs"]?.AsArray() ?? new JsonArray())
                if (n is JsonObject o && string.Equals(o["Name"]?.GetValue<string>(), name, StringComparison.OrdinalIgnoreCase))
                    return o;
        }
        catch {}
        return null;
    }

    private async Task<ApiResponse> StateSummaryAsync()
    {
        await Task.CompletedTask;
        if (!File.Exists(AppPaths.StatePath)) return ApiResponse.Json(404, new { error = "state not found" });
        var o = JsonNode.Parse(File.ReadAllText(AppPaths.StatePath, Encoding.UTF8))?.AsObject();
        var generated = o?["GeneratedAt"]?.ToString();
        return ApiResponse.Json(200, new {
            generatedAt = generated,
            generatedDisplay = DateTimeOffset.TryParse(generated, out var d) ? d.ToLocalTime().ToString("dd.MM.yyyy HH:mm:ss") : ""
        });
    }

    private static ApiResponse ControllerStatus()
    {
        int pid = 0;
        string[] requested = Array.Empty<string>();
        try
        {
            if (File.Exists(AppPaths.ControllerStatePath))
            {
                var o = JsonNode.Parse(File.ReadAllText(AppPaths.ControllerStatePath, Encoding.UTF8))?.AsObject();
                pid = o?["pid"]?.GetValue<int>() ?? 0;
                requested = o?["requested"]?.AsArray().Select(x => x?.ToString() ?? "").Where(x => x.Length > 0).ToArray()
                            ?? Array.Empty<string>();
            }
        }
        catch {}

        var running = false;
        if (pid > 0)
        {
            try { using var p = Process.GetProcessById(pid); running = !p.HasExited; } catch {}
        }

        if (!running && File.Exists(AppPaths.ControllerStatePath))
        {
            try { File.Delete(AppPaths.ControllerStatePath); } catch {}
        }

        return ApiResponse.Json(200, new { running, pid, requested });
    }

    private async Task<ApiResponse> StartSingleAsync(string body)
    {
        var o = ParseBody(body);
        var name = o["Name"]?.ToString() ?? "";
        return await StartControllerAsync(name.Length > 0 ? new[]{ name } : Array.Empty<string>());
    }

    private async Task<ApiResponse> StartSelectedAsync(string body)
    {
        var o = ParseBody(body);
        var names = o["Names"]?.AsArray().Select(n => n?.ToString() ?? "").Where(x => x.Length > 0).ToArray()
                    ?? Array.Empty<string>();
        return await StartControllerAsync(names);
    }

    private async Task<ApiResponse> StartControllerAsync(string[] names)
    {
        var st = ControllerStatus();
        var current = JsonNode.Parse(Encoding.UTF8.GetString(st.Body))?.AsObject();
        if (current?["running"]?.GetValue<bool>() == true)
            return ApiResponse.Json(409, new { error = "Проверка уже выполняется." });

        if (!File.Exists(AppPaths.BackupScript))
            return ApiResponse.Json(500, new { error = "BackupS3.ps1 not found" });

        try { File.Delete(AppPaths.CancelFlagPath); } catch {}

        var psi = new ProcessStartInfo {
            FileName = AppPaths.PowerShellExe(),
            WorkingDirectory = AppPaths.DataRoot,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-NonInteractive");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-File");
        psi.ArgumentList.Add(AppPaths.BackupScript);
        if (names.Length > 0)
        {
            psi.ArgumentList.Add("-JobNamesCsv");
            psi.ArgumentList.Add(string.Join(",", names));
        }

        var p = Process.Start(psi);
        if (p is null) return ApiResponse.Json(500, new { error = "Не удалось запустить BackupS3.ps1" });
        var pid = p.Id;
        p.Dispose();

        var controller = new JsonObject {
            ["pid"] = pid,
            ["startedAt"] = DateTimeOffset.Now.ToString("o"),
            ["requested"] = new JsonArray(names.Select(x => (JsonNode?)x).ToArray()),
            ["source"] = "desktop"
        };
        WriteObjectAtomic(AppPaths.ControllerStatePath, controller);
        await Task.Delay(300);
        return ApiResponse.Json(202, new { status = "started", pid });
    }

    private static ApiResponse CancelController()
    {
        File.WriteAllText(AppPaths.CancelFlagPath, DateTimeOffset.Now.ToString("o"));
        return ApiResponse.Json(200, new { status = "cancel_requested" });
    }

    private async Task<ApiResponse> GetSettingsAsync()
    {
        if (File.Exists(AppPaths.SettingsPath))
        {
            var saved = ReadObject(AppPaths.SettingsPath, new JsonObject());
            if (string.IsNullOrWhiteSpace(saved["UpdateManifestUrl"]?.ToString()))
                saved["UpdateManifestUrl"] = DefaultUpdateManifestUrl;
            return ApiResponse.Json(200, saved);
        }

        var cfg = await ConfigAsync();
        var g = cfg["Global"]?.AsObject();
        return ApiResponse.Json(200, new {
            SafeMode = true,
            EnableUpload = g?["EnableUpload"]?.GetValue<bool>() ?? false,
            EnableCleanup = g?["EnableCleanup"]?.GetValue<bool>() ?? false,
            EnableGraylog = g?["EnableGraylog"]?.GetValue<bool>() ?? false,
            MinFileIdleMinutes = g?["MinFileIdleMinutes"]?.GetValue<int>() ?? 3,
            RetryCount = g?["RetryCount"]?.GetValue<int>() ?? 3,
            RetryDelaySeconds = g?["RetryDelaySeconds"]?.GetValue<int>() ?? 30,
            HistoryDays = g?["HistoryDays"]?.GetValue<int>() ?? 30,
            DefaultSizeAnomalyPercent = g?["DefaultSizeAnomalyPercent"]?.GetValue<int>() ?? 35,
            AutoRefreshSeconds = 60,
            AutoSchedulerEnabled = false,
            AutoSchedulerIntervalMinutes = 5
            ,AutoStartInBackground = false,
            UpdateManifestUrl = DefaultUpdateManifestUrl
        });
    }

    private async Task<ApiResponse> SaveSettingsAsync(string body)
    {
        var o = ParseBody(body);

        var enabled = o["AutoSchedulerEnabled"]?.GetValue<bool>() ?? false;
        var interval = Math.Clamp(o["AutoSchedulerIntervalMinutes"]?.GetValue<int>() ?? 5, 1, 60);
        o["AutoSchedulerIntervalMinutes"] = interval;
        var autoStart = o["AutoStartInBackground"]?.GetValue<bool>() ?? false;
        ApplyWindowsAutoStart(autoStart);

        // Apply the Windows task first. If that fails, don't write settings
        // which claim the scheduler is enabled when it actually isn't.
        await ApplySchedulerAsync(enabled, interval);

        WriteObjectAtomic(AppPaths.SettingsPath, o);
        return ApiResponse.Json(200, new {
            status = "saved",
            autoSchedulerEnabled = enabled,
            autoSchedulerIntervalMinutes = interval
            ,autoStartInBackground = autoStart
        });
    }

    private static void ApplyWindowsAutoStart(bool enabled)
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled)
            key.SetValue("BackupS3Manager", $"\"{Environment.ProcessPath}\" --background", Microsoft.Win32.RegistryValueKind.String);
        else
            key.DeleteValue("BackupS3Manager", false);
        AppLog.Info(enabled ? "Автозапуск в фоновом режиме включён" : "Автозапуск в фоновом режиме выключен");
    }

    private static async Task<ApiResponse> CheckForUpdateAsync()
    {
        var settings = ReadObject(AppPaths.SettingsPath, new JsonObject());
        var manifestUrl = settings["UpdateManifestUrl"]?.ToString()?.Trim() ?? "";
        if (manifestUrl.Length == 0) manifestUrl = DefaultUpdateManifestUrl;
        if (!Uri.TryCreate(manifestUrl, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
            return ApiResponse.Json(400, new { error = "Адрес обновлений должен быть корректным HTTPS URL." });

        using var response = await UpdateHttp.GetAsync(uri);
        response.EnsureSuccessStatusCode();
        var manifest = JsonNode.Parse(await response.Content.ReadAsStringAsync())?.AsObject()
            ?? throw new InvalidOperationException("GitHub вернул пустой manifest обновления.");
        var latest = manifest["version"]?.ToString()?.Trim() ?? "";
        if (!Version.TryParse(NormalizeVersion(latest), out var latestVersion))
            throw new InvalidOperationException("В manifest указана некорректная версия.");
        Version.TryParse(NormalizeVersion(CurrentVersion), out var currentVersion);
        var available = latestVersion > currentVersion;
        return ApiResponse.Json(200, new {
            currentVersion = CurrentVersion,
            latestVersion = latest,
            configured = true,
            updateAvailable = available,
            downloadUrl = available ? manifest["downloadUrl"]?.ToString() : null,
            sha256 = available ? manifest["sha256"]?.ToString() : null,
            notes = manifest["notes"]?.ToString() ?? "",
            message = available ? $"Доступна версия {latest}." : $"Установлена актуальная версия {CurrentVersion}."
        });
    }

    private static async Task<ApiResponse> DownloadUpdateAsync()
    {
        var check = await CheckForUpdateAsync();
        if (check.StatusCode != 200) return check;
        var info = JsonNode.Parse(check.Body)?.AsObject();
        if (info?["updateAvailable"]?.GetValue<bool>() != true)
            return ApiResponse.Json(409, new { error = info?["message"]?.ToString() ?? "Обновление не найдено." });
        var url = info["downloadUrl"]?.ToString() ?? "";
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
            return ApiResponse.Json(400, new { error = "В manifest отсутствует безопасная HTTPS-ссылка на пакет." });

        var downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        Directory.CreateDirectory(downloads);
        var extension = Path.GetExtension(uri.AbsolutePath).Equals(".zip", StringComparison.OrdinalIgnoreCase) ? ".zip" : ".msi";
        var version = info["latestVersion"]?.ToString() ?? "update";
        var destination = Path.Combine(downloads, $"BackupS3Manager-v{version}-x64{extension}");
        var bytes = await UpdateHttp.GetByteArrayAsync(uri);
        var expectedHash = info["sha256"]?.ToString()?.Trim();
        var actualHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
        if (!string.IsNullOrWhiteSpace(expectedHash) && !actualHash.Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("SHA-256 загруженного обновления не совпадает с manifest. Файл не сохранён.");
        File.WriteAllBytes(destination, bytes);
        AppLog.Info($"Обновление {version} загружено: {destination}");
        return ApiResponse.Json(200, new { status = "downloaded", version, path = destination, sha256 = actualHash });
    }

    private static string NormalizeVersion(string value)
    {
        var parts = value.Trim().TrimStart('v', 'V').Split('.', StringSplitOptions.RemoveEmptyEntries).ToList();
        while (parts.Count < 4) parts.Add("0");
        return string.Join('.', parts.Take(4));
    }

    private static ApiResponse GetUiSettings()
    {
        if (File.Exists(AppPaths.UiSettingsPath))
            return ApiResponse.JsonText(200, File.ReadAllText(AppPaths.UiSettingsPath, Encoding.UTF8));

        return ApiResponse.Json(200, new {
            Jobs = new Dictionary<string,object>(),
            DefaultSort = "name",
            ShowFavorites = true
        });
    }

    private static ApiResponse SaveUiJob(string body)
    {
        var patch = ParseBody(body);
        var name = patch["Name"]?.ToString() ?? "";
        if (name.Length == 0) return ApiResponse.Json(400, new { error = "Name is required" });

        var ui = ReadObject(AppPaths.UiSettingsPath, new JsonObject {
            ["Jobs"] = new JsonObject(),
            ["DefaultSort"] = "name",
            ["ShowFavorites"] = true
        });
        var jobs = ui["Jobs"] as JsonObject ?? new JsonObject();
        patch.Remove("Name");
        var current = jobs[name] as JsonObject ?? new JsonObject();
        foreach (var kv in patch) current[kv.Key] = kv.Value?.DeepClone();
        jobs[name] = current;
        ui["Jobs"] = jobs;
        WriteObjectAtomic(AppPaths.UiSettingsPath, ui);
        return ApiResponse.Json(200, new { status = "saved" });
    }

    private static ApiResponse SaveUiGlobal(string body)
    {
        var patch = ParseBody(body);
        var ui = ReadObject(AppPaths.UiSettingsPath, new JsonObject {
            ["Jobs"] = new JsonObject(),
            ["DefaultSort"] = "name",
            ["ShowFavorites"] = true
        });
        foreach (var kv in patch) ui[kv.Key] = kv.Value?.DeepClone();
        WriteObjectAtomic(AppPaths.UiSettingsPath, ui);
        return ApiResponse.Json(200, new { status = "saved" });
    }

    private async Task<ApiResponse> JobDetailAsync(string name)
    {
        var j = await EffectiveJobAsync(name);
        if (j is null) return ApiResponse.Json(404, new { error = "job not found" });
        var result = (JsonObject)j.DeepClone();
        var st = FindStateJob(name);
        foreach (var key in new[]{"S3Latest","SyncStatus","S3Objects","LocalFile","LastChecked"})
            if (st?[key] is not null) result[key] = st[key]!.DeepClone();
        return ApiResponse.JsonText(200, result.ToJsonString());
    }

    private async Task<ApiResponse> LocalFilesAsync(string name)
    {
        var j = await EffectiveJobAsync(name);
        if (j is null) return ApiResponse.Json(404, new { error = "job not found" });

        var localPath = j["LocalPath"]?.ToString() ?? "";
        var prefix = j["FilePrefix"]?.ToString() ?? "";
        if (!Directory.Exists(localPath))
            return ApiResponse.Json(500, new { error = $"Локальная папка недоступна: {localPath}" });

        var s3 = await ListS3ObjectsAsync(j);
        var keys = new HashSet<string>(s3.Select(x => x["Key"]?.ToString() ?? ""), StringComparer.Ordinal);
        var root = (j["S3Path"]?.ToString() ?? "").Trim('/');

        var files = new JsonArray();
        foreach (var f in new DirectoryInfo(localPath).EnumerateFiles()
                     .Where(x => x.Name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                     .OrderByDescending(x => x.LastWriteTimeUtc))
        {
            var key = root.Length > 0 ? $"{root}/{f.Name}" : f.Name;
            files.Add(new JsonObject {
                ["Name"] = f.Name,
                ["FullName"] = f.FullName,
                ["SizeBytes"] = f.Length,
                ["LastWriteTime"] = f.LastWriteTime.ToString("o"),
                ["S3Key"] = key,
                ["OnS3"] = keys.Contains(key)
            });
        }

        return ApiResponse.JsonText(200, new JsonObject {
            ["name"] = name,
            ["localPath"] = localPath,
            ["bucket"] = j["Bucket"]?.ToString(),
            ["s3Path"] = j["S3Path"]?.ToString(),
            ["count"] = files.Count,
            ["files"] = files,
            ["s3LiveChecked"] = true,
            ["s3LiveError"] = "",
            ["checkedAt"] = DateTimeOffset.Now.ToString("o")
        }.ToJsonString());
    }

    private async Task<ApiResponse> S3ObjectsAsync(string name)
    {
        var j = await EffectiveJobAsync(name);
        if (j is null) return ApiResponse.Json(404, new { error = "job not found" });
        var objects = await ListS3ObjectsAsync(j);
        PersistLiveS3State(name, objects);
        var root = (j["S3Path"]?.ToString() ?? "").Trim('/');
        var prefix = root.Length > 0 ? $"{root}/{j["FilePrefix"]}" : j["FilePrefix"]?.ToString();

        return ApiResponse.JsonText(200, new JsonObject {
            ["name"] = name,
            ["bucket"] = j["Bucket"]?.ToString(),
            ["s3Path"] = j["S3Path"]?.ToString(),
            ["prefix"] = prefix,
            ["count"] = objects.Count,
            ["objects"] = new JsonArray(objects.Select(x => (JsonNode?)x).ToArray()),
            ["checkedAt"] = DateTimeOffset.Now.ToString("o")
        }.ToJsonString());
    }

    private static void PersistLiveS3State(string name, List<JsonObject> objects)
    {
        if (!File.Exists(AppPaths.StatePath)) return;
        var state = ReadObject(AppPaths.StatePath, new JsonObject());
        if (state["Jobs"] is not JsonArray jobs) return;
        var job = jobs.OfType<JsonObject>().FirstOrDefault(x => string.Equals(x["Name"]?.ToString(), name, StringComparison.OrdinalIgnoreCase));
        if (job is null) return;
        job["S3ObjectCount"] = objects.Count;
        job["S3TotalBytes"] = objects.Sum(x => x["SizeBytes"]?.GetValue<long>() ?? 0L);
        job["S3Objects"] = new JsonArray(objects.Select(x => (JsonNode?)x.DeepClone()).ToArray());
        job["S3Latest"] = objects.FirstOrDefault()?["LastModified"]?.DeepClone();
        job["S3Key"] = objects.FirstOrDefault()?["Key"]?.DeepClone();
        job["LastChecked"] = DateTimeOffset.Now.ToString("o");
        state["GeneratedAt"] = DateTimeOffset.Now.ToString("o");
        WriteObjectAtomic(AppPaths.StatePath, state);
    }

    private async Task<List<JsonObject>> ListS3ObjectsAsync(JsonObject j)
    {
        var cfg = await ConfigAsync();
        var endpoint = cfg["Global"]?["EndpointUrl"]?.ToString() ?? "";
        var bucket = j["Bucket"]?.ToString() ?? "";
        var root = (j["S3Path"]?.ToString() ?? "").Trim('/');
        var prefix = root.Length > 0 ? $"{root}/{j["FilePrefix"]}" : j["FilePrefix"]?.ToString() ?? "";

        var args = new List<string> {
            "--endpoint-url", endpoint
        };
        var profile = j["AwsProfile"]?.ToString() ?? "";
        if (profile.Length > 0) { args.Add("--profile"); args.Add(profile); }
        args.AddRange(new[]{"s3api","list-objects-v2","--bucket",bucket,"--prefix",prefix,"--output","json"});

        var r = await RunProcessAsync("aws", args, AppPaths.DataRoot);
        if (r.ExitCode != 0) throw new InvalidOperationException("AWS CLI: " + r.Output);

        var list = new List<JsonObject>();
        if (string.IsNullOrWhiteSpace(r.StdOut)) return list;
        var data = JsonNode.Parse(r.StdOut)?.AsObject();
        foreach (var n in data?["Contents"]?.AsArray() ?? new JsonArray())
        {
            if (n is not JsonObject o) continue;
            list.Add(new JsonObject {
                ["Key"] = o["Key"]?.ToString(),
                ["SizeBytes"] = o["Size"]?.GetValue<long>() ?? 0,
                ["LastModified"] = o["LastModified"]?.ToString()
            });
        }
        return list.OrderByDescending(x => DateTimeOffset.TryParse(x["LastModified"]?.ToString(), out var d) ? d : DateTimeOffset.MinValue).ToList();
    }

    private async Task<ApiResponse> AddJobAsync(string body)
    {
        var j = ParseBody(body);
        var name = j["Name"]?.ToString()?.Trim() ?? "";
        if (name.Length == 0) return ApiResponse.Json(400, new { error = "Укажите имя базы." });
        if (await EffectiveJobAsync(name) is not null) return ApiResponse.Json(409, new { error = "База с таким именем уже существует." });

        // The web form sends only user-editable fields. BackupS3.ps1 treats
        // Enabled as authoritative, therefore every newly created job must
        // explicitly be enabled. This also keeps the persisted schema equal
        // to jobs imported from BackupJobs.psd1.
        j["Name"] = name;
        j["Enabled"] = true;

        var m = ReadObject(AppPaths.ManagedJobsPath, new JsonObject {
            ["AddedJobs"] = new JsonArray(),
            ["DeletedNames"] = new JsonArray(),
            ["Overrides"] = new JsonObject()
        });
        var a = m["AddedJobs"] as JsonArray ?? new JsonArray();
        a.Add(j);
        m["AddedJobs"] = a;
        WriteObjectAtomic(AppPaths.ManagedJobsPath, m);
        AppendHistoryEvent("JOB_ADDED", name, "База добавлена в Backup S3 Manager");
        AppPaths.GenerateDashboard();
        return ApiResponse.Json(200, new { status = "added", name });
    }

    private async Task<ApiResponse> UpdateJobAsync(string body)
    {
        var patch = ParseBody(body);
        var name = patch["Name"]?.ToString()?.Trim() ?? "";
        if (name.Length == 0) return ApiResponse.Json(400, new { error = "Name is required" });
        if (await EffectiveJobAsync(name) is null) return ApiResponse.Json(404, new { error = "job not found" });

        var m = ReadObject(AppPaths.ManagedJobsPath, new JsonObject {
            ["AddedJobs"] = new JsonArray(),
            ["DeletedNames"] = new JsonArray(),
            ["Overrides"] = new JsonObject()
        });
        var ovs = m["Overrides"] as JsonObject ?? new JsonObject();
        ovs[name] = patch;
        m["Overrides"] = ovs;
        WriteObjectAtomic(AppPaths.ManagedJobsPath, m);
        AppPaths.GenerateDashboard();
        return ApiResponse.Json(200, new { status = "saved" });
    }

    private async Task<ApiResponse> DeleteJobAsync(string body)
    {
        var o = ParseBody(body);
        var name = o["Name"]?.ToString() ?? "";
        if (name.Length == 0) return ApiResponse.Json(400, new { error = "Name required" });

        var cfg = await ConfigAsync();
        var isBase = cfg["Jobs"]?.AsArray().Any(n => n is JsonObject j &&
            string.Equals(j["Name"]?.ToString(), name, StringComparison.OrdinalIgnoreCase)) == true;

        var m = ReadObject(AppPaths.ManagedJobsPath, new JsonObject {
            ["AddedJobs"] = new JsonArray(),
            ["DeletedNames"] = new JsonArray(),
            ["Overrides"] = new JsonObject()
        });

        if (m["AddedJobs"] is JsonArray added)
        {
            for (int i = added.Count - 1; i >= 0; --i)
                if (added[i] is JsonObject j && string.Equals(j["Name"]?.ToString(), name, StringComparison.OrdinalIgnoreCase))
                    added.RemoveAt(i);
        }

        if (isBase)
        {
            var d = m["DeletedNames"] as JsonArray ?? new JsonArray();
            if (!d.Any(n => string.Equals(n?.ToString(), name, StringComparison.OrdinalIgnoreCase))) d.Add(name);
            m["DeletedNames"] = d;
        }

        if (m["Overrides"] is JsonObject overrides) overrides.Remove(name);

        WriteObjectAtomic(AppPaths.ManagedJobsPath, m);
        AppendHistoryEvent("JOB_DELETED", name, "База удалена из Backup S3 Manager");
        AppPaths.GenerateDashboard();
        return ApiResponse.Json(200, new { status = "deleted" });
    }

    private async Task<ApiResponse> DeleteJobsAsync(string body)
    {
        var request = ParseBody(body);
        var names = request["Names"]?.AsArray()
            .Select(n => n?.ToString()?.Trim() ?? "")
            .Where(n => n.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray() ?? Array.Empty<string>();
        if (names.Length == 0) return ApiResponse.Json(400, new { error = "Не выбраны базы для удаления" });

        var cfg = await ConfigAsync();
        var baseNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var node in cfg["Jobs"]?.AsArray() ?? new JsonArray())
            if (node is JsonObject job && job["Name"] is not null) baseNames.Add(job["Name"]!.ToString());

        var managed = ReadObject(AppPaths.ManagedJobsPath, new JsonObject {
            ["AddedJobs"] = new JsonArray(), ["DeletedNames"] = new JsonArray(), ["Overrides"] = new JsonObject()
        });
        var selected = new HashSet<string>(names, StringComparer.OrdinalIgnoreCase);
        var added = managed["AddedJobs"] as JsonArray ?? new JsonArray();
        for (var i = added.Count - 1; i >= 0; --i)
            if (added[i] is JsonObject job && selected.Contains(job["Name"]?.ToString() ?? "")) added.RemoveAt(i);
        managed["AddedJobs"] = added;

        var deleted = managed["DeletedNames"] as JsonArray ?? new JsonArray();
        var deletedSet = new HashSet<string>(deleted.Select(n => n?.ToString() ?? ""), StringComparer.OrdinalIgnoreCase);
        foreach (var name in names)
            if (baseNames.Contains(name) && deletedSet.Add(name)) deleted.Add(name);
        managed["DeletedNames"] = deleted;

        if (managed["Overrides"] is JsonObject overrides)
            foreach (var name in names) overrides.Remove(name);

        WriteObjectAtomic(AppPaths.ManagedJobsPath, managed);
        foreach (var name in names)
            AppendHistoryEvent("JOB_DELETED", name, "База удалена из Backup S3 Manager");
        AppPaths.GenerateDashboard();
        return ApiResponse.Json(200, new { status = "deleted", deleted = names });
    }

    private async Task<ApiResponse> ManualUploadStartAsync(string body)
    {
        var settings = JsonNode.Parse(Encoding.UTF8.GetString((await GetSettingsAsync()).Body))?.AsObject();
        if (settings?["SafeMode"]?.GetValue<bool>() == true || settings?["EnableUpload"]?.GetValue<bool>() != true)
            return ApiResponse.Json(403, new { error = "Для ручной загрузки выключи SafeMode и включи Upload в Настройках" });

        var o = ParseBody(body);
        var name = o["Name"]?.ToString() ?? "";
        var file = o["FilePath"]?.ToString() ?? "";
        var op = Guid.NewGuid().ToString();

        var initial = new JsonObject {
            ["id"] = op,
            ["database"] = name,
            ["filePath"] = file,
            ["status"] = "STARTING",
            ["percent"] = 0,
            ["message"] = "Запуск Manual-Upload.ps1",
            ["startedAt"] = DateTimeOffset.Now.ToString("o")
        };
        WriteObjectAtomic(Path.Combine(AppPaths.ManualUploadsDir, op + ".json"), initial);

        var psi = new ProcessStartInfo {
            FileName = AppPaths.PowerShellExe(),
            WorkingDirectory = AppPaths.DataRoot,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var x in new[]{"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",AppPaths.ManualUploadScript,
                                "-RootPath",AppPaths.DataRoot,"-OperationId",op,"-Database",name,"-FilePath",file})
            psi.ArgumentList.Add(x);

        var p = Process.Start(psi);
        if (p is null) return ApiResponse.Json(500, new { error = "Manual-Upload.ps1 start failed" });
        var pid = p.Id; p.Dispose();
        return ApiResponse.Json(202, new {
            status = "started",
            id = op,
            operationId = op,
            pid,
            safeMode = false,
            enableUpload = true
        });
    }

    private static ApiResponse ManualUploadStatus(string id)
    {
        if (!Guid.TryParse(id, out _))
            return ApiResponse.Json(400, new { error = "invalid operation id" });
        var path = Path.Combine(AppPaths.ManualUploadsDir, id + ".json");
        if (!File.Exists(path)) return ApiResponse.Json(404, new { error = "operation not found" });
        return ApiResponse.JsonText(200, File.ReadAllText(path, Encoding.UTF8));
    }

    private async Task<ApiResponse> DeleteS3ObjectAsync(string body)
    {
        var settings = JsonNode.Parse(Encoding.UTF8.GetString((await GetSettingsAsync()).Body))?.AsObject();
        if (settings?["SafeMode"]?.GetValue<bool>() == true ||
            settings?["EnableCleanup"]?.GetValue<bool>() != true)
            return ApiResponse.Json(403, new { error = "Для удаления выключи SafeMode и включи Cleanup в Настройках" });

        var o = ParseBody(body);
        var name = o["Name"]?.ToString() ?? "";
        var key = o["Key"]?.ToString() ?? "";
        var j = await EffectiveJobAsync(name);
        if (j is null) return ApiResponse.Json(404, new { error = "job not found" });

        var root = (j["S3Path"]?.ToString() ?? "").Trim('/');
        var filePrefix = j["FilePrefix"]?.ToString() ?? "";
        var allowedPrefix = root.Length > 0 ? $"{root}/{filePrefix}" : filePrefix;
        if (string.IsNullOrWhiteSpace(key) || string.IsNullOrWhiteSpace(filePrefix) ||
            !key.StartsWith(allowedPrefix, StringComparison.Ordinal))
            return ApiResponse.Json(400, new { error = "S3 key is outside the selected database prefix" });

        var cfg = await ConfigAsync();
        var args = new List<string> {"--endpoint-url", cfg["Global"]?["EndpointUrl"]?.ToString() ?? ""};
        var profile = j["AwsProfile"]?.ToString() ?? "";
        if (profile.Length > 0) args.AddRange(new[]{"--profile",profile});
        args.AddRange(new[]{"s3api","delete-object","--bucket",j["Bucket"]?.ToString() ?? "","--key",key});
        var r = await RunProcessAsync("aws", args, AppPaths.DataRoot);
        if (r.ExitCode != 0) return ApiResponse.Json(500, new { error = r.Output });
        return ApiResponse.Json(200, new { status = "deleted" });
    }

    private async Task<ApiResponse> RetentionPreviewAsync(string body)
    {
        var name = ParseBody(body)["Name"]?.ToString() ?? "";
        var j = await EffectiveJobAsync(name);
        if (j is null) return ApiResponse.Json(404, new { error = "job not found" });
        var objects = await ListS3ObjectsAsync(j);
        var keep = j["Keep"]?.GetValue<int>() ?? 2;
        var candidates = new JsonArray(objects.Skip(keep).Select(x => (JsonNode?)x).ToArray());
        var settings = JsonNode.Parse(Encoding.UTF8.GetString((await GetSettingsAsync()).Body))?.AsObject();
        var safe = settings?["SafeMode"]?.GetValue<bool>() ?? true;
        return ApiResponse.JsonText(200, new JsonObject {
            ["name"] = name, ["keep"] = keep, ["candidates"] = candidates,
            ["enabled"] = !safe && (settings?["EnableCleanup"]?.GetValue<bool>() ?? false),
            ["safeMode"] = safe,
            ["autoCleanup"] = !safe && (settings?["EnableCleanup"]?.GetValue<bool>() ?? false)
        }.ToJsonString());
    }

    private async Task<ApiResponse> RetentionApplyAsync(string body)
    {
        var preview = await RetentionPreviewAsync(body);
        if (preview.StatusCode != 200) return preview;
        var p = JsonNode.Parse(Encoding.UTF8.GetString(preview.Body))!.AsObject();
        if (p["enabled"]?.GetValue<bool>() != true)
            return ApiResponse.Json(403, new { error = "Для retention выключи SafeMode и включи Cleanup" });

        var name = p["name"]?.ToString() ?? "";
        var j = await EffectiveJobAsync(name);
        var deleted = new JsonArray();
        foreach (var n in p["candidates"]?.AsArray() ?? new JsonArray())
        {
            var key = n?["Key"]?.ToString() ?? "";
            var r = await DeleteS3ObjectAsync(JsonSerializer.Serialize(new { Name = name, Key = key }));
            if (r.StatusCode == 200) deleted.Add(key);
        }
        return ApiResponse.JsonText(200, new JsonObject { ["status"] = "done", ["deleted"] = deleted }.ToJsonString());
    }

    private static ApiResponse MaintenanceSet(string body)
    {
        var o = ParseBody(body);
        var name = o["Name"]?.ToString() ?? "";
        var hours = o["Hours"]?.GetValue<double>() ?? 2;
        var m = ReadObject(AppPaths.MaintenancePath, new JsonObject());
        m[name] = new JsonObject {
            ["until"] = DateTimeOffset.Now.AddHours(hours).ToString("o"),
            ["reason"] = o["Reason"]?.ToString() ?? ""
        };
        WriteObjectAtomic(AppPaths.MaintenancePath, m);
        return ApiResponse.Json(200, new { status = "maintenance_set" });
    }

    private static ApiResponse MaintenanceClear(string body)
    {
        var name = ParseBody(body)["Name"]?.ToString() ?? "";
        var m = ReadObject(AppPaths.MaintenancePath, new JsonObject());
        m.Remove(name);
        WriteObjectAtomic(AppPaths.MaintenancePath, m);
        return ApiResponse.Json(200, new { status = "maintenance_cleared" });
    }

    private static ApiResponse LogAsync(Dictionary<string,string> q)
    {
        var source = q.GetValueOrDefault("source", "controller").ToLowerInvariant();
        var file = source switch {
            "audit" => Path.Combine(AppPaths.LogsDir, "audit.log"),
            "server" => Path.Combine(AppPaths.LogsDir, "desktop-app.log"),
            _ => Path.Combine(AppPaths.LogsDir, "backup-s3.log")
        };
        var max = int.TryParse(q.GetValueOrDefault("lines",""), out var n) ? Math.Clamp(n,20,2000) : (source is "server" or "audit" ? 100 : 250);
        var lines = File.Exists(file) ? File.ReadLines(file).TakeLast(max).ToArray() : Array.Empty<string>();

        var db = q.GetValueOrDefault("database","");
        var level = q.GetValueOrDefault("level","");
        var query = q.GetValueOrDefault("q","");
        if (db.Length > 0) lines = lines.Where(x => x.Contains($"[{db}]", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (level.Length > 0) lines = lines.Where(x => x.Contains($"[{level}]", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (query.Length > 0) lines = lines.Where(x => x.Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();

        var fi = File.Exists(file) ? new FileInfo(file) : null;
        return ApiResponse.Json(200, new {
            file, source, exists = fi is not null,
            lastWrite = fi?.LastWriteTime.ToString("o"),
            sizeBytes = fi?.Length ?? 0,
            count = lines.Length,
            responseChars = lines.Sum(x => x.Length + 1),
            lines,
            checkedAt = DateTimeOffset.Now
        });
    }

    private async Task<ApiResponse> BrowseFolderAsync(string initial)
    {
        var p = await _browseFolder(initial);
        return ApiResponse.Json(200, new { cancelled = p is null, path = p ?? "" });
    }

    private async Task<ApiResponse> S3ConnectionsAsync()
    {
        var cfg = await ConfigAsync();
        var endpoint = cfg["Global"]?["EndpointUrl"]?.ToString() ?? "";
        var jobs = await EffectiveJobsAsync();

        var unique = new Dictionary<string, (string Bucket, string Profile)>(StringComparer.OrdinalIgnoreCase);

        foreach (var n in jobs)
        {
            if (n is not JsonObject j) continue;
            var bucket = j["Bucket"]?.ToString()?.Trim() ?? "";
            var profile = j["AwsProfile"]?.ToString()?.Trim() ?? "";
            if (bucket.Length == 0) continue;

            var key = bucket + "\u001f" + profile;
            unique.TryAdd(key, (bucket, profile));
        }

        var result = new JsonArray();

        foreach (var item in unique.Values.OrderBy(x => x.Bucket, StringComparer.OrdinalIgnoreCase)
                                          .ThenBy(x => x.Profile, StringComparer.OrdinalIgnoreCase))
        {
            var args = new List<string>();
            if (!string.IsNullOrWhiteSpace(endpoint))
            {
                args.Add("--endpoint-url");
                args.Add(endpoint);
            }

            if (!string.IsNullOrWhiteSpace(item.Profile))
            {
                args.Add("--profile");
                args.Add(item.Profile);
            }

            args.AddRange(new[]
            {
                "s3api", "list-objects-v2",
                "--bucket", item.Bucket,
                "--max-keys", "1",
                "--output", "json"
            });

            var started = DateTime.UtcNow;
            var r = await RunProcessAsync("aws", args, AppPaths.DataRoot);
            var elapsed = (int)Math.Max(0, (DateTime.UtcNow - started).TotalMilliseconds);

            var message = r.ExitCode == 0
                ? "Подключение доступно"
                : (string.IsNullOrWhiteSpace(r.Output) ? $"AWS CLI exit={r.ExitCode}" : r.Output);

            result.Add(new JsonObject
            {
                ["endpoint"] = endpoint,
                ["bucket"] = item.Bucket,
                ["profile"] = item.Profile,
                ["profileDisplay"] = string.IsNullOrWhiteSpace(item.Profile) ? "default" : item.Profile,
                ["ok"] = r.ExitCode == 0,
                ["exitCode"] = r.ExitCode,
                ["elapsedMs"] = elapsed,
                ["message"] = message
            });
        }

        var okCount = result.Count(n => n?["ok"]?.GetValue<bool>() == true);

        return ApiResponse.JsonText(200, new JsonObject
        {
            ["endpoint"] = endpoint,
            ["total"] = result.Count,
            ["ok"] = okCount,
            ["connections"] = result,
            ["checkedAt"] = DateTimeOffset.Now.ToString("o")
        }.ToJsonString());
    }

    private async Task<ApiResponse> S3FoldersAsync(Dictionary<string,string> q)
    {
        var cfg = await ConfigAsync();
        var args = new List<string>{"--endpoint-url",cfg["Global"]?["EndpointUrl"]?.ToString() ?? ""};
        var profile = q.GetValueOrDefault("profile","");
        if (profile.Length > 0) args.AddRange(new[]{"--profile",profile});
        args.AddRange(new[]{"s3api","list-objects-v2","--bucket",q.GetValueOrDefault("bucket",""),
                            "--delimiter","/","--max-keys","1000","--output","json"});
        var r = await RunProcessAsync("aws", args, AppPaths.DataRoot);
        if (r.ExitCode != 0) return ApiResponse.Json(500, new { error = r.Output });
        var data = string.IsNullOrWhiteSpace(r.StdOut) ? new JsonObject() : JsonNode.Parse(r.StdOut)?.AsObject() ?? new JsonObject();
        var folders = new List<string>();
        foreach (var n in data["CommonPrefixes"]?.AsArray() ?? new JsonArray())
            if (n?["Prefix"] is not null) folders.Add(n["Prefix"]!.ToString().Trim('/'));
        return ApiResponse.Json(200, new { bucket = q.GetValueOrDefault("bucket",""), folders });
    }

    private static ApiResponse UploadProgress()
    {
        var a = new JsonArray();
        if (Directory.Exists(AppPaths.UploadProgressDir))
        {
            foreach (var f in Directory.EnumerateFiles(AppPaths.UploadProgressDir, "*.json"))
            {
                try { a.Add(JsonNode.Parse(File.ReadAllText(f, Encoding.UTF8))); } catch {}
            }
        }
        return ApiResponse.JsonText(200, new JsonObject {
            ["items"] = a, ["serverTime"] = DateTimeOffset.Now.ToString("o")
        }.ToJsonString());
    }

    private async Task<ApiResponse> ExportJobScriptAsync(string name)
    {
        var j = await EffectiveJobAsync(name);
        if (j is null) return ApiResponse.Json(404, new { error = "job not found" });
        var cfg = await ConfigAsync();
        var endpoint = cfg["Global"]?["EndpointUrl"]?.ToString() ?? "";
        string E(string? s) => (s ?? "").Replace("\"","`\"");
        var ps = string.Join("\r\n", new[]
        {
            "param([switch]$Upload)",
            "$ErrorActionPreference=\"Stop\"",
            $"$endpoint=\"{E(endpoint)}\"",
            $"$bucket=\"{E(j["Bucket"]?.ToString())}\"",
            $"$s3Path=\"{E(j["S3Path"]?.ToString())}\"",
            $"$localPath=\"{E(j["LocalPath"]?.ToString())}\"",
            $"$filePrefix=\"{E(j["FilePrefix"]?.ToString())}\"",
            $"$profile=\"{E(j["AwsProfile"]?.ToString())}\"",
            "$latest=Get-ChildItem $localPath -File | Where-Object {$_.Name.StartsWith($filePrefix,[StringComparison]::OrdinalIgnoreCase)} | Sort-Object LastWriteTime -Descending | Select-Object -First 1",
            "if($null-eq$latest){throw \"Backup file not found\"}",
            "$key=if($s3Path){\"$s3Path/$($latest.Name)\"}else{$latest.Name}",
            "$dest=\"s3://$bucket/$key\"",
            "Write-Host \"Local: $($latest.FullName)\"",
            "Write-Host \"S3: $dest\"",
            "if(-not$Upload){Write-Host \"DRY RUN. Use -Upload\";exit 0}",
            "$args=@(\"--endpoint-url\",$endpoint)",
            "if($profile){$args+=@(\"--profile\",$profile)}",
            "& aws @args s3 cp $latest.FullName $dest --only-show-errors",
            "if($LASTEXITCODE-ne0){throw \"AWS upload failed: $LASTEXITCODE\"}",
            ""
        });
        var headers = $"Content-Disposition: attachment; filename=\"BackupS3-{name}.ps1\"\r\n";
        return new ApiResponse(200,"OK",Encoding.UTF8.GetBytes(ps),"text/plain; charset=utf-8",headers);
    }

    private async Task<ApiResponse> ReportAsync(Dictionary<string,string> q)
    {
        await Task.CompletedTask;
        var format = q.GetValueOrDefault("format","html").ToLowerInvariant();
        var state = File.Exists(AppPaths.StatePath) ? File.ReadAllText(AppPaths.StatePath,Encoding.UTF8) : "{}";
        var node = JsonNode.Parse(state)?.AsObject() ?? new JsonObject();
        var jobs = node["Jobs"]?.AsArray() ?? new JsonArray();
        var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");

        if (format == "json")
        {
            return new ApiResponse(200,"OK",Encoding.UTF8.GetBytes(state),"application/json; charset=utf-8",
                $"Content-Disposition: attachment; filename=\"BackupS3-report-{stamp}.json\"\r\n");
        }

        if (format == "csv")
        {
            var sb = new StringBuilder("Name,Status,LocalFile,LocalSizeBytes,S3ObjectCount,SyncStatus,StatusText\r\n");
            string Csv(string s) => "\"" + s.Replace("\"","\"\"") + "\"";
            foreach (var n in jobs)
            {
                if (n is not JsonObject j) continue;
                sb.AppendLine(string.Join(",", new[]{
                    Csv(j["Name"]?.ToString()??""), Csv(j["Status"]?.ToString()??""),
                    Csv(j["LocalFile"]?.ToString()??""), (j["LocalSizeBytes"]?.ToString()??"0"),
                    (j["S3ObjectCount"]?.ToString()??"0"), Csv(j["SyncStatus"]?.ToString()??""),
                    Csv(j["StatusText"]?.ToString()??"")
                }));
            }
            return new ApiResponse(200,"OK",Encoding.UTF8.GetBytes(sb.ToString()),"text/csv; charset=utf-8",
                $"Content-Disposition: attachment; filename=\"BackupS3-report-{stamp}.csv\"\r\n");
        }

        var html = new StringBuilder("""
<!doctype html><html><head><meta charset="utf-8"><title>BackupS3 Report</title>
<style>body{font-family:Segoe UI,Arial;background:#111;color:#ddd;padding:24px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #444;padding:6px;text-align:left}th{background:#222}</style></head><body>
<h1>BackupS3 Report</h1><table><thead><tr><th>База</th><th>Статус</th><th>Local</th><th>S3</th><th>Sync</th><th>Комментарий</th></tr></thead><tbody>
""");
        foreach (var n in jobs)
        {
            if (n is not JsonObject j) continue;
            static string H(string? x) => System.Net.WebUtility.HtmlEncode(x ?? "");
            html.Append($"<tr><td>{H(j["Name"]?.ToString())}</td><td>{H(j["Status"]?.ToString())}</td><td>{H(j["LocalFile"]?.ToString())}</td><td>{H(j["S3ObjectCount"]?.ToString())}</td><td>{H(j["SyncStatus"]?.ToString())}</td><td>{H(j["StatusText"]?.ToString())}</td></tr>");
        }
        html.Append("</tbody></table></body></html>");
        return new ApiResponse(200,"OK",Encoding.UTF8.GetBytes(html.ToString()),"text/html; charset=utf-8",
            $"Content-Disposition: attachment; filename=\"BackupS3-report-{stamp}.html\"\r\n");
    }

    private Task ApplySchedulerAsync(bool enabled, int interval)
    {
        // v23.13 hotfix: do not invoke schtasks.exe while the settings request
        // owns the WebView UI call. On several Windows builds that transition
        // made the desktop window disappear even though .NET did not crash.
        // The dashboard-backed scheduler persists the deadline and starts the
        // same hidden AutoScheduler.ps1 process through /api/scheduler/run.
        // This keeps the application window and settings modal alive.
        var inAppInterval = Math.Clamp(interval, 1, 60);
        if (!enabled)
        {
            if (File.Exists(AppPaths.SchedulerStatePath))
                File.Delete(AppPaths.SchedulerStatePath);
            AppLog.Info("Встроенная автоматическая проверка выключена");
            return Task.CompletedTask;
        }

        if (!File.Exists(AppPaths.AutoSchedulerScript))
            throw new InvalidOperationException(
                $"AutoScheduler.ps1 не найден: {AppPaths.AutoSchedulerScript}");

        WriteSchedulerState(DateTimeOffset.Now.AddMinutes(inAppInterval), inAppInterval, "WAITING", null);
        AppLog.Info($"Встроенная автоматическая проверка включена: каждые {inAppInterval} мин.");
        return Task.CompletedTask;
    }

    private static ApiResponse SchedulerStatus()
    {
        var settings = ReadObject(AppPaths.SettingsPath, new JsonObject());
        var enabled = settings["AutoSchedulerEnabled"]?.GetValue<bool>() ?? false;
        var interval = Math.Clamp(settings["AutoSchedulerIntervalMinutes"]?.GetValue<int>() ?? 2, 1, 60);
        var state = ReadObject(AppPaths.SchedulerStatePath, new JsonObject());
        return ApiResponse.Json(200, new {
            enabled,
            intervalMinutes = interval,
            nextRunAt = state["nextRunAt"]?.ToString(),
            lastStartedAt = state["lastStartedAt"]?.ToString(),
            status = state["status"]?.ToString() ?? (enabled ? "WAITING" : "DISABLED")
        });
    }

    private static async Task<ApiResponse> RunSchedulerAsync()
    {
        var settings = ReadObject(AppPaths.SettingsPath, new JsonObject());
        if (!(settings["AutoSchedulerEnabled"]?.GetValue<bool>() ?? false))
            return ApiResponse.Json(409, new { error = "Автоматическая проверка выключена." });

        var interval = Math.Clamp(settings["AutoSchedulerIntervalMinutes"]?.GetValue<int>() ?? 2, 1, 60);
        if (!File.Exists(AppPaths.AutoSchedulerScript))
            return ApiResponse.Json(500, new { error = "AutoScheduler.ps1 не найден." });

        var psi = new ProcessStartInfo {
            FileName = AppPaths.PowerShellExe(),
            WorkingDirectory = AppPaths.DataRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", AppPaths.AutoSchedulerScript })
            psi.ArgumentList.Add(arg);
        var process = Process.Start(psi);
        if (process is null)
            return ApiResponse.Json(500, new { error = "Не удалось запустить автоматическую проверку." });

        WriteSchedulerState(DateTimeOffset.Now.AddMinutes(interval), interval, "STARTED", DateTimeOffset.Now);
        await Task.Delay(100);
        return ApiResponse.Json(202, new { status = "started", pid = process.Id, nextRunAt = DateTimeOffset.Now.AddMinutes(interval) });
    }

    private static void WriteSchedulerState(DateTimeOffset nextRunAt, int interval, string status, DateTimeOffset? lastStartedAt)
    {
        var state = ReadObject(AppPaths.SchedulerStatePath, new JsonObject());
        state["nextRunAt"] = nextRunAt.ToString("O");
        state["intervalMinutes"] = interval;
        state["status"] = status;
        if (lastStartedAt.HasValue) state["lastStartedAt"] = lastStartedAt.Value.ToString("O");
        WriteObjectAtomic(AppPaths.SchedulerStatePath, state);
    }

    private static async Task<(int ExitCode,string StdOut,string StdErr,string Output)> RunPowerShellCommandAsync(string script, params string[] args)
    {
        // Windows PowerShell 5.1 does not reliably treat "--" as an argument
        // separator for -Command. v23.05 therefore could pass "--" as
        // $args[0], which broke Import-PowerShellDataFile and caused errors
        // such as: "'R' is an invalid start of a value".
        //
        // Pass arguments through a UTF-8/Base64 environment variable instead.
        var argsJson = JsonSerializer.Serialize(args);
        var argsBase64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(argsJson));

        var bootstrap =
            "$ErrorActionPreference='Stop';" +
            "$__raw=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:BACKUPS3_DESKTOP_ARGS_B64));" +
            "$desktopArgs=@(ConvertFrom-Json $__raw);" +
            script;

        var psi = new ProcessStartInfo
        {
            FileName = AppPaths.PowerShellExe(),
            WorkingDirectory = AppPaths.DataRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-NonInteractive");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-Command");
        psi.ArgumentList.Add(bootstrap);
        psi.Environment["BACKUPS3_DESKTOP_ARGS_B64"] = argsBase64;

        using var p = new Process { StartInfo = psi };
        p.Start();
        var so = p.StandardOutput.ReadToEndAsync();
        var se = p.StandardError.ReadToEndAsync();
        await WaitForExitAsync(p, 120000);

        var stdout = await so;
        var stderr = await se;
        var output = string.Join(
            Environment.NewLine,
            new[] { stdout.Trim(), stderr.Trim() }.Where(x => x.Length > 0));

        return (p.ExitCode, stdout, stderr, output);
    }

    private static async Task<(int ExitCode,string StdOut,string StdErr,string Output)> RunProcessAsync(
        string exe, IEnumerable<string> args, string workingDir, int timeoutMs = 120000)
    {
        var psi = new ProcessStartInfo {
            FileName = exe, WorkingDirectory = workingDir,
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var p = new Process { StartInfo = psi };
        p.Start();
        var so = p.StandardOutput.ReadToEndAsync();
        var se = p.StandardError.ReadToEndAsync();
        await WaitForExitAsync(p, timeoutMs);
        var stdout = await so;
        var stderr = await se;
        var output = string.Join(Environment.NewLine, new[]{stdout.Trim(),stderr.Trim()}.Where(x => x.Length > 0));
        return (p.ExitCode, stdout, stderr, output);
    }

    private static async Task WaitForExitAsync(Process process, int timeoutMs)
    {
        using var cts = new CancellationTokenSource(timeoutMs);
        try
        {
            await process.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(true); } catch { }
            throw new TimeoutException($"Процесс {process.StartInfo.FileName} не завершился за {timeoutMs / 1000} секунд.");
        }
    }
}
