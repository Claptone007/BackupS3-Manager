using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;

namespace BackupS3Agent;

internal sealed class AgentConfiguration
{
    public string ManagerUrl { get; set; } = "http://127.0.0.1:17831";
    public string EnrollmentCode { get; set; } = "";
    public string DisplayName { get; set; } = Environment.MachineName;
    public string AgentId { get; set; } = "";
    public string Token { get; set; } = "";
    public int PollSeconds { get; set; } = 15;
    public int ListenPort { get; set; } = 17832;
    public List<AgentJob> Jobs { get; set; } = new();
}

internal sealed class AgentJob
{
    public string Name { get; set; } = "";
    public string LocalPath { get; set; } = "";
    public string FilePrefix { get; set; } = "";
}

internal sealed class AgentConfigurationStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        TypeInfoResolver = new DefaultJsonTypeInfoResolver()
    };
    public static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "BackupS3Agent");
    public static string PathName => Path.Combine(Root, "agent-settings.json");

    public AgentConfiguration Load()
    {
        Directory.CreateDirectory(Root);
        if (!File.Exists(PathName))
        {
            var initial = new AgentConfiguration();
            Save(initial);
            return initial;
        }
        return JsonSerializer.Deserialize<AgentConfiguration>(File.ReadAllText(PathName, Encoding.UTF8), Options)
               ?? new AgentConfiguration();
    }

    public void Save(AgentConfiguration configuration)
    {
        Directory.CreateDirectory(Root);
        var temporary = PathName + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(configuration, Options), new UTF8Encoding(false));
        File.Move(temporary, PathName, true);
    }
}
