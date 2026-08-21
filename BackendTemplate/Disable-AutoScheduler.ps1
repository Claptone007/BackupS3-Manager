$taskName="BackupS3 Auto Scheduler"
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($null -eq $task){
    Write-Host "Task not found: $taskName"
    exit 0
}
Disable-ScheduledTask -TaskName $taskName | Out-Null
Write-Host "Disabled: $taskName"
