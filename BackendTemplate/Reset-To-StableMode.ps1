$ErrorActionPreference="Continue"

$taskName="BackupS3 Auto Scheduler"
Write-Host "=== BackupS3 Stable Reset ===" -ForegroundColor Cyan

try{
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if($null-ne$task){
        Disable-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue|Out-Null
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Host "[OK] AutoScheduler disabled" -ForegroundColor Green
    }else{
        Write-Host "[OK] AutoScheduler task not installed" -ForegroundColor Green
    }
}catch{
    Write-Host "[WARN] Scheduler disable: $($_.Exception.Message)" -ForegroundColor Yellow
}

foreach($name in @(
    "State\auto-scheduler-status.json",
    "State\restart-dashboard.ps1"
)){
    $p=Join-Path $PSScriptRoot $name
    if(Test-Path $p){
        Remove-Item $p -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Removed transient file: $name" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Stable mode prepared. AutoScheduler will not run." -ForegroundColor Green
Write-Host "Run .\Test-PowerShellSyntax.ps1 and then .\Start-DashboardServer.ps1"
