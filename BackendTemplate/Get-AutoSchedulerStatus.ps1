$taskName="BackupS3 Auto Scheduler"
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($null-eq$task){
    Write-Host "NOT INSTALLED"
    exit 1
}
$info=Get-ScheduledTaskInfo -TaskName $taskName
[PSCustomObject]@{
    TaskName=$taskName
    State=$task.State
    LastRunTime=$info.LastRunTime
    LastTaskResult=$info.LastTaskResult
    NextRunTime=$info.NextRunTime
}|Format-List

$log=Join-Path $PSScriptRoot "Logs\auto-scheduler.log"
if(Test-Path $log){
    Write-Host "`nLast scheduler lines:"
    Get-Content $log -Tail 20
}
