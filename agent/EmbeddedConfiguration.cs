using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;

namespace BackupS3Agent;

internal static class EmbeddedConfiguration
{
    private static readonly byte[] Marker = Encoding.ASCII.GetBytes("\nBS3-CONFIG-V1\n");
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        TypeInfoResolver = new DefaultJsonTypeInfoResolver()
    };

    public static AgentConfiguration? Read()
    {
        try
        {
            var path = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(path)) return null;
            using var stream = File.OpenRead(path);
            var tailSize = (int)Math.Min(stream.Length, 64 * 1024);
            var tail = new byte[tailSize];
            stream.Position = stream.Length - tailSize;
            stream.ReadExactly(tail);
            var markerIndex = tail.AsSpan().LastIndexOf(Marker);
            if (markerIndex < 0) return null;
            var json = Encoding.UTF8.GetString(tail, markerIndex + Marker.Length, tail.Length - markerIndex - Marker.Length);
            return JsonSerializer.Deserialize<AgentConfiguration>(json, Options);
        }
        catch { return null; }
    }
}
