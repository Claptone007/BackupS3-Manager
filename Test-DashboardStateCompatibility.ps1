$ErrorActionPreference="Stop"
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ("BackupS3-DashboardTest-"+[guid]::NewGuid().ToString("N"))
$stateDir=Join-Path $testRoot "State"
$webDir=Join-Path $testRoot "Web"
New-Item -ItemType Directory -Path $stateDir,$webDir -Force|Out-Null

try{
    $statePath=Join-Path $stateDir "state.json"
    $managedPath=Join-Path $stateDir "managed-jobs.json"
    $historyPath=Join-Path $stateDir "history.jsonl"
    $dashboardPath=Join-Path $webDir "index.html"
    $configPath=Join-Path $testRoot "BackupJobs.psd1"

    $config=Get-Content (Join-Path $root "installer\BackupJobs.clean.psd1") -Raw -Encoding UTF8
    $config=$config.Replace('State\state.json',$statePath)
    $config=$config.Replace('State\managed-jobs.json',$managedPath)
    $config=$config.Replace('State\history.jsonl',$historyPath)
    $config=$config.Replace('Web\index.html',$dashboardPath)
    Set-Content -LiteralPath $configPath -Value $config -Encoding UTF8

    @{GeneratedAt=(Get-Date).ToString('o');Host='TEST';Jobs=@(@{
        Name='NewBase';Status='WAITING';LocalPath='D:\Backups\NewBase';Bucket='bucket';S3Path='folder';Keep=2
    })}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $statePath -Encoding UTF8
    @{UseBaseJobs=$false;DeletedNames=@();Overrides=@{};AddedJobs=@(@{
        Name='NewBase';AgentId='agent-test';Enabled=$true;LocalPath='D:\Backups\NewBase';Bucket='bucket';S3Path='folder';Keep=2
    })}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $managedPath -Encoding UTF8

    & (Join-Path $root "BackendTemplate\Generate-Dashboard.ps1") -ConfigPath $configPath
    if(-not(Test-Path $dashboardPath -PathType Leaf)){
        throw "Dashboard was not generated at $dashboardPath. Config: $config"
    }
    $html=Get-Content $dashboardPath -Raw -Encoding UTF8
    if($html -notmatch 'NewBase'){throw "Added database is missing from Dashboard"}
    if($html -notmatch 'data-agent-id="agent-test"'){throw "Agent assignment is missing from the new Dashboard row"}
    Write-Host "[OK] old state without AwsProfile is upgraded while Dashboard is generated" -ForegroundColor Green
    Write-Host "[OK] newly added agent database is present in Dashboard with AgentId" -ForegroundColor Green
}
finally{
    if(Test-Path $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
