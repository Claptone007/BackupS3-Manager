$ErrorActionPreference="Stop"
$root=Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=== BackupS3 Manager v24.17 API bridge source check ===" -ForegroundColor Cyan

$main=Get-Content (Join-Path $root "src\MainForm.cs") -Raw -Encoding UTF8
$api=Get-Content (Join-Path $root "src\ApiBridge.cs") -Raw -Encoding UTF8

$required=@(
    'AddScriptToExecuteOnDocumentCreatedAsync(ApiFetchShim)',
    'WebMessageReceived += WebMessageReceived',
    'chrome.webview.postMessage',
    '__backupS3ApiResolve',
    'HandleAsync(method, uri, body)'
)

foreach($needle in $required){
    if($main -notlike "*$needle*"){
        throw "MainForm.cs missing: $needle"
    }
    Write-Host "[OK] $needle" -ForegroundColor Green
}

if($main -match 'AddWebResourceRequestedFilter\s*\('){
    throw "Old WebResourceRequested API transport is still enabled."
}
Write-Host "[OK] old network-style API transport removed" -ForegroundColor Green

if($api -notmatch 'CurrentVersion\s*=\s*"24\.17"'){
    throw "ApiBridge.cs version is not 24.17"
}
Write-Host "[OK] desktop API version 24.17" -ForegroundColor Green

foreach($needle in @('return RequestAgentCheck','["AgentId"] = agentId','total = (await EffectiveJobsAsync()).Count')){
    if(-not$api.Contains($needle)){throw "ApiBridge.cs missing agent job synchronization: $needle"}
    Write-Host "[OK] agent job synchronization: $needle" -ForegroundColor Green
}

$hub=Get-Content (Join-Path $root "src\AgentHubServer.cs") -Raw -Encoding UTF8
foreach($needle in @('reportChanged','AppPaths.GenerateDashboard()')){
    if(-not$hub.Contains($needle)){throw "AgentHubServer.cs missing dashboard refresh: $needle"}
    Write-Host "[OK] heartbeat dashboard refresh: $needle" -ForegroundColor Green
}

foreach($needle in @(
    '"-RootPath",AppPaths.DataRoot',
    'Guid.TryParse(id',
    'EnableCleanup',
    'WaitForExitAsync(p, timeoutMs)'
)){
    if(-not$api.Contains($needle)){throw "ApiBridge.cs missing safety fix: $needle"}
    Write-Host "[OK] safety fix: $needle" -ForegroundColor Green
}

foreach($needle in @('SchedulerStatePath','/api/scheduler/run','AutoSchedulerIntervalMinutes')){
    if(-not$api.Contains($needle)){throw "ApiBridge.cs missing scheduler timing: $needle"}
    Write-Host "[OK] scheduler timing: $needle" -ForegroundColor Green
}
