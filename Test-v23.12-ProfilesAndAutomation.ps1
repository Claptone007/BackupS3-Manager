$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$api = Get-Content (Join-Path $root "src\ApiBridge.cs") -Raw
$ui = Get-Content (Join-Path $root "BackendTemplate\Generate-Dashboard.ps1") -Raw
$scheduler = Get-Content (Join-Path $root "BackendTemplate\AutoScheduler.ps1") -Raw
$project = Get-Content (Join-Path $root "src\BackupS3Manager.csproj") -Raw
$appPaths = Get-Content (Join-Path $root "src\AppPaths.cs") -Raw
$appLog = Get-Content (Join-Path $root "src\AppLog.cs") -Raw
$backup = Get-Content (Join-Path $root "BackendTemplate\BackupS3.ps1") -Raw

$checks = [ordered]@{
    "application icon" = '<ApplicationIcon>Assets\BackupS3-BS3.ico</ApplicationIcon>'
    "configuration profile list API" = '"GET", "/api/config-profiles"'
    "configuration profile import API" = '"POST", "/api/config-profiles/import"'
    "S3 profile masked list" = 'ListS3Profiles(revealSecrets: false)'
    "S3 profile explicit reveal" = '"POST", "/api/s3-profiles/reveal"'
    "S3 standard credentials path" = 'AppPaths.AwsCredentialsPath'
    "bulk delete API" = '"POST", "/api/jobs/delete-selected"'
    "serializer resolver fix" = 'TypeInfoResolver = new DefaultJsonTypeInfoResolver()'
    "central audit log" = 'Path.Combine(AppPaths.LogsDir, "audit.log")'
    "database added history event" = 'AppendHistoryEvent("JOB_ADDED", name'
    "database deleted history event" = 'AppendHistoryEvent("JOB_DELETED", name'
    "bulk delete audit label" = '"Групповое удаление баз"'
    "audit excludes request secrets" = 'DescribeAuditTarget(body)'
    "profile manager UI" = 'id="profilesModal"'
    "secret inputs masked" = 'id="s3SecretKey" type="password"'
    "scheduler health" = 'auto-scheduler-health.json'
    "scheduler log rotation" = '(Get-Item $LogPath).Length -gt 5MB'
}

foreach($item in $checks.GetEnumerator()){
    $haystack = if($item.Key -like 'application*'){$project}elseif($item.Key -like 'scheduler*'){$scheduler}elseif($item.Key -like '*UI' -or $item.Key -like 'secret*'){$ui}else{$api}
    if(-not $haystack.Contains($item.Value)){throw "Missing: $($item.Key)"}
    Write-Host "[OK] $($item.Key)"
}

foreach($needle in @('id="selectAllJobsButton"','id="deleteSelectedButton"','function downloadApiFile(url,fileName)','/api/jobs/delete-selected')){
    if(-not $ui.Contains($needle)){throw "Missing UI behavior: $needle"}
    Write-Host "[OK] UI: $needle"
}

foreach($needle in @('id="backToTopButton"','$byName[[string]$j.Name]=$j','window.scrollTo({top:0,behavior:''smooth''})')){
    if(-not $ui.Contains($needle)){throw "Missing duplicate/UI fix: $needle"}
    Write-Host "[OK] duplicate/UI fix: $needle"
}

foreach($needle in @('"JOB_ADDED"','/api/jobs/check','location.reload()')){
    if(-not $ui.Contains($needle)){throw "Missing instant add behavior: $needle"}
    Write-Host "[OK] instant add: $needle"
}

foreach($needle in @('class="dashboard-brand"','class="dashboard-brand-symbol"','@keyframes dashboard-brand-orbit','<h1>Backup<strong>S3</strong></h1>')){
    if(-not $ui.Contains($needle)){throw "Missing dashboard brand: $needle"}
    Write-Host "[OK] dashboard brand: $needle"
}

foreach($needle in @('draggable="true"','text/x-backups3-database','setJobPinned(name,true)','class=''unpin-job''','class=''favorite-health''')){
    if(-not $ui.Contains($needle)){throw "Missing v23.13 favorites behavior: $needle"}
    Write-Host "[OK] v23.13 favorites: $needle"
}

if(-not $api.Contains('foreach (var kv in patch) current[kv.Key]')){throw "Partial UI updates do not preserve customization"}
Write-Host "[OK] partial pin updates preserve existing customization"

foreach($needle in @('desktop-app.log','MaxBytes = 5 * 1024 * 1024','File.AppendAllText')){
    if(-not $appLog.Contains($needle)){throw "Missing application logging: $needle"}
    Write-Host "[OK] application log: $needle"
}
foreach($needle in @('CreateDailyConfigurationSnapshot','AutomaticBackups','Skip(14)')){
    if(-not $appPaths.Contains($needle)){throw "Missing automatic configuration backup: $needle"}
    Write-Host "[OK] automatic configuration backup: $needle"
}

foreach($needle in @('text/x-backups3-database','toggleDesktopTools','field-help','Время загрузки на S3','settingsSuccess','newestLocal.Name','newestS3.Key')){
    if(-not $ui.Contains($needle)){throw "Missing v23.13 usability fix: $needle"}
    Write-Host "[OK] v23.13 usability: $needle"
}

foreach($needle in @('[switch]$ScheduledRun','Test-ScheduledUploadWindow','MAX_AGE_EXCEEDED','Select-Object -Skip ([int]$job.Keep)')){
    if(-not $backup.Contains($needle)){throw "Missing scheduled upload/retention behavior: $needle"}
    Write-Host "[OK] scheduled upload/retention: $needle"
}
foreach($needle in @('Where-Object {$null -eq $_.Enabled -or [bool]$_.Enabled}','"-ScheduledRun"','Полная автоматическая проверка баз запущена')){
    if(-not $scheduler.Contains($needle)){throw "Scheduler does not run a full check: $needle"}
    Write-Host "[OK] full auto-check: $needle"
}

$program = Get-Content (Join-Path $root "src\Program.cs") -Raw
$splash = Get-Content (Join-Path $root "src\SplashForm.cs") -Raw
if(-not $program.Contains('new SplashForm()')){throw "Animated startup splash is not launched"}
foreach($needle in @('WaitForMinimumDisplayAsync','CreateRoundRectRgn','Backup','BACKUP MANAGER')){
    if(-not $splash.Contains($needle)){throw "Missing splash behavior: $needle"}
    Write-Host "[OK] startup splash: $needle"
}

if(-not $backup.Contains('$byName[[string]$j.Name]=$j')){throw "Backup controller does not deduplicate jobs"}
if(-not $backup.Contains('$null -eq $_.Enabled -or [bool]$_.Enabled')){throw "Backup controller does not enable legacy managed jobs"}
if(-not $scheduler.Contains('$byName[[string]$j.Name]=')){throw "Scheduler does not deduplicate jobs"}
Write-Host "[OK] dashboard, controller and scheduler deduplicate database names"

if($ui.Contains("window.location.href='/api/report")){throw "Report still navigates WebView to API URL"}
Write-Host "[OK] reports download through the desktop API bridge"

foreach($asset in @("src\Assets\BackupS3-BS3.ico","src\Assets\BackupS3-BS3.png")){
    if(-not(Test-Path (Join-Path $root $asset) -PathType Leaf)){throw "Missing asset: $asset"}
    Write-Host "[OK] $asset"
}

Write-Host "v23.12 profiles and automation regression checks passed."
