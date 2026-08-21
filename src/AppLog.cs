using System.Text;

namespace BackupS3Manager;

internal static class AppLog
{
    private static readonly object Sync = new();
    private const long MaxBytes = 5 * 1024 * 1024;
    public static string Path => System.IO.Path.Combine(AppPaths.LogsDir, "desktop-app.log");

    public static void Info(string message) => Write("INFO", message);
    public static void Warn(string message) => Write("WARN", message);
    public static void Error(string message, Exception? exception = null) =>
        Write("ERROR", exception is null ? message : $"{message} · {exception.GetType().Name}: {exception.Message}");

    private static void Write(string level, string message)
    {
        try
        {
            lock (Sync)
            {
                Directory.CreateDirectory(AppPaths.LogsDir);
                if (File.Exists(Path) && new FileInfo(Path).Length > MaxBytes)
                {
                    var archive = Path + ".1";
                    if (File.Exists(archive)) File.Delete(archive);
                    File.Move(Path, archive);
                }

                var clean = message.Replace('\r', ' ').Replace('\n', ' ');
                var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz} [{level}] [{Environment.UserName}@{Environment.MachineName}] {clean}";
                File.AppendAllText(Path, line + Environment.NewLine, new UTF8Encoding(false));
            }
        }
        catch { }
    }
}
