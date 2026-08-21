param(
    [int]$IntervalMinutes = 2
)

$ErrorActionPreference="Stop"
$root=$PSScriptRoot
$scheduler=Join-Path $root "AutoScheduler.ps1"

if(-not(Test-Path $scheduler)){throw "AutoScheduler.ps1 not found"}

if($IntervalMinutes -lt 1 -or $IntervalMinutes -gt 60){
    throw "IntervalMinutes must be 1..60"
}

$taskName="BackupS3 Auto Scheduler"
$ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$action=New-ScheduledTaskAction `
    -Execute $ps `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scheduler`""

$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$settings=New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 3)

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "Automatic BackupS3 due-check and S3 upload orchestration" `
    -Force | Out-Null

Write-Host ""
Write-Host "OK: '$taskName' installed."
Write-Host "Interval: $IntervalMinutes minute(s)"
Write-Host "Scheduler: $scheduler"
Write-Host ""
Write-Host "SafeMode can stay ON for dry monitoring."
Write-Host "For automatic upload: SafeMode OFF + EnableUpload ON."
