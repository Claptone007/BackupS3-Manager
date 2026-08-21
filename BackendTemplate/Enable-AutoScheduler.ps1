$taskName="BackupS3 Auto Scheduler"
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($null -eq $task){
    Write-Host "Task not found: $taskName"
    exit 1
}
Enable-ScheduledTask -TaskName $taskName | Out-Null
Write-Host "Enabled: $taskName"
