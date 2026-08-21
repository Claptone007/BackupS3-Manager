$ErrorActionPreference="Stop"
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$api=Get-Content (Join-Path $root "src\ApiBridge.cs") -Raw -Encoding UTF8

Write-Host "=== BackupS3 Manager v23.11 scheduler regression checks ===" -ForegroundColor Cyan

foreach($needle in @(
    'ApplySchedulerAsync',
    'WriteSchedulerState',
    'AutoSchedulerEnabled',
    'AutoSchedulerIntervalMinutes',
    'SchedulerStatePath',
    'RunSchedulerAsync'
)){
    if(-not $api.Contains($needle)){throw "ApiBridge.cs missing: $needle"}
    Write-Host "[OK] $needle" -ForegroundColor Green
}

if($api -match '(?m)^\s*Register-ScheduledTask\b'){
    throw "Legacy Register-ScheduledTask code is still present."
}
Write-Host "[OK] Register-ScheduledTask removed from desktop API" -ForegroundColor Green

if($api -notmatch 'CurrentVersion\s*=\s*"23\.16"'){
    throw "ApiBridge.cs version is not 23.16"
}
Write-Host "[OK] desktop API version 23.16" -ForegroundColor Green

Write-Host "v23.11 scheduler regression checks passed." -ForegroundColor Green
