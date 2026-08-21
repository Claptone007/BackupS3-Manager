namespace BackupS3Manager;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();

        using var mutex = new Mutex(true, @"Local\BackupS3Manager.SingleInstance", out var created);
        if (!created)
        {
            MessageBox.Show("Backup S3 Manager уже запущен.", "Backup S3 Manager",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        try
        {
            AppPaths.Initialize();
            AppLog.Info("BackupS3 Manager v23.14 запускается");

            var startInBackground = args.Any(x => x.Equals("--background", StringComparison.OrdinalIgnoreCase));
            if (startInBackground)
            {
                Application.Run(new MainForm(null, startInBackground: true));
                AppLog.Info("BackupS3 Manager завершён");
                return;
            }

            // v23.12: the user never needs to open PowerShell to validate a build.
            // EXE performs the checks itself and presents a readable Windows dialog.
            using (var diagnostics = new DiagnosticsForm(startupMode: true))
            {
                diagnostics.ShowDialog();
                if (!diagnostics.ContinueRequested)
                    return;
            }

            using var splash = new SplashForm();
            splash.Show();
            Application.Run(new MainForm(splash));
            AppLog.Info("BackupS3 Manager завершён");
        }
        catch (Exception ex)
        {
            AppLog.Error("Критическая ошибка запуска", ex);
            MessageBox.Show(ex.ToString(), "Ошибка запуска Backup S3 Manager",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
