@{
    Global = @{
        EndpointUrl = "https://s3.example.com"
        GraylogUrl = ""
        EnableGraylog = $false
        EnableUpload = $false
        EnableCleanup = $false
        MinFileIdleMinutes = 3
        RetryCount = 3
        RetryDelaySeconds = 30
        StateFile = "State\state.json"
        ProgressFile = "State\progress.json"
        HistoryFile = "State\history.jsonl"
        LogFile = "Logs\backup-s3.log"
        ManagedJobsFile = "State\managed-jobs.json"
        MaintenanceFile = "State\maintenance.json"
        SettingsFile = "State\settings.json"
        Dashboard = "Web\index.html"
        HistoryDays = 30
        SizeHistoryCount = 7
        DefaultSizeAnomalyPercent = 35
        SqlVerify = @{ Enabled = $false; Server = "localhost"; SqlcmdPath = "sqlcmd.exe"; TimeoutSeconds = 600 }
    }
    Jobs = @()
}
