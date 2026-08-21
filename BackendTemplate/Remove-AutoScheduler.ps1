$taskName="BackupS3 Auto Scheduler"
if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed: $taskName"
}else{
    Write-Host "Task not found: $taskName"
}
