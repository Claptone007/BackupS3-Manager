param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "BackupJobs.psd1")
)

$ErrorActionPreference = "Stop"

function Resolve-LocalConfigPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $PSScriptRoot $Path)
}

function ConvertTo-HtmlSafe {
    param($Value)
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-StatusLabel {
    param([string]$Status)
    switch (([string]$Status).ToUpperInvariant()) {
        "OK"       { "В норме" }
        "UPLOADED" { "Загружено" }
        "READY"    { "Готово" }
        "WAITING"  { "Ожидание" }
        "STALE"    { "Устарело" }
        "WARNING"  { "Предупреждение" }
        "ERROR"    { "Ошибка" }
        default     { if([string]::IsNullOrWhiteSpace($Status)){"Неизвестно"}else{$Status} }
    }
}

function Get-SyncStatusLabel {
    param([string]$Status)
    switch (([string]$Status).ToUpperInvariant()) {
        "SYNCED"     { "Синхронизировано" }
        "S3_MISSING" { "Нет на S3" }
        "NOT_CHECKED" { "Ещё не проверено" }
        "UNKNOWN"    { "Не проверено" }
        default       { if([string]::IsNullOrWhiteSpace($Status)){"Неизвестно"}else{$Status} }
    }
}

function Get-ReasonLabel {
    param([string]$Reason)
    switch (([string]$Reason).ToUpperInvariant()) {
        "ERROR"             { "Ошибка проверки" }
        "MISSED_SCHEDULE"   { "Пропущено расписание" }
        "RETENTION_PENDING" { "Ожидается очистка S3" }
        "S3_MISSING"        { "Нет на S3" }
        "MAX_AGE_EXCEEDED"  { "Превышен максимальный возраст локальной копии" }
        "SIZE_ANOMALY"      { "Аномальный размер" }
        "SIZE_MISMATCH"     { "Размеры не совпадают" }
        "VERIFY_FAILED"     { "Проверка файла не пройдена" }
        "WAITING_FILE"      { "Файл ещё формируется" }
        "NOT_CHECKED"       { "Ещё не проверено" }
        default              { $Reason }
    }
}

function Format-Bytes {
    param([Int64]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-DateValue {
    param($Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return "-" }
    try { return ([datetime]$Value).ToString("dd.MM.yyyy HH:mm:ss") }
    catch { return [string]$Value }
}

$config = Import-PowerShellDataFile $ConfigPath
$stateFile = Resolve-LocalConfigPath $config.Global.StateFile
$outputFile = Resolve-LocalConfigPath $config.Global.Dashboard
$cssFile = Join-Path (Split-Path $outputFile -Parent) "style.css"

function Convert-JobToOrderedMap {
    param($Job)

    $map=[ordered]@{}
    if($null -eq $Job){return $map}

    if($Job -is [System.Collections.IDictionary]){
        foreach($key in $Job.Keys){
            $map[[string]$key]=$Job[$key]
        }
    }else{
        foreach($p in $Job.PSObject.Properties){
            $map[$p.Name]=$p.Value
        }
    }

    return $map
}

function Get-EffectiveDashboardJobs {
    param(
        $BaseJobs,
        [string]$ManagedJobsPath
    )

    $added=@()
    $deleted=@()
    $overrides=@{}

    if(Test-Path $ManagedJobsPath -PathType Leaf){
        try{
            $managed=Get-Content $ManagedJobsPath -Raw -Encoding UTF8|ConvertFrom-Json
            $added=@($managed.AddedJobs)
            $deleted=@($managed.DeletedNames)

            if($null-ne$managed.Overrides){
                foreach($p in $managed.Overrides.PSObject.Properties){
                    $overrides[$p.Name]=$p.Value
                }
            }
        }catch{}
    }

    # A saved/imported profile may contain a job that also exists in
    # BackupJobs.psd1. Keep exactly one row per name; the managed copy wins.
    $byName=@{}

    foreach($j in @($BaseJobs)){
        if($null-ne$j -and $deleted -notcontains [string]$j.Name){
            $byName[[string]$j.Name]=$j
        }
    }

    foreach($j in @($added)){
        if($null-ne$j -and $deleted -notcontains [string]$j.Name){
            $byName[[string]$j.Name]=$j
        }
    }

    $effective=@()

    foreach($job in @($byName.Values)){
        $copy=Convert-JobToOrderedMap $job
        $name=[string]$copy["Name"]

        if($overrides.ContainsKey($name)){
            foreach($p in $overrides[$name].PSObject.Properties){
                if($p.Name -ne "Name"){
                    $copy[$p.Name]=$p.Value
                }
            }
        }

        $effective+=[PSCustomObject]$copy
    }

    return @($effective)
}

function New-UncheckedDashboardState {
    param($Job)

    return [PSCustomObject][ordered]@{
        Name=[string]$Job.Name
        Status="WAITING"
        StatusText="База добавлена, проверка ещё не выполнялась"
        ReasonCodes=@("NOT_CHECKED")
        HealthScore=0

        LocalPath=[string]$Job.LocalPath
        LocalFile=$null
        LocalSizeBytes=0
        LocalFileCount=0
        LocalTotalBytes=0
        LocalObjects=@()
        LocalLastWrite=$null
        AgeHours=$null

        ExpectedBackupTime=[string]$Job.ExpectedBackupTime
        ExpectedDays=[string]$Job.ExpectedDays
        ExpectedOccurrence=$null
        ScheduleDelayMinutes=$null

        Bucket=[string]$Job.Bucket
        S3Path=[string]$Job.S3Path
        S3Key=$null
        S3ObjectCount=0
        S3TotalBytes=0
        S3Latest=$null
        S3Objects=@()

        SyncStatus="NOT_CHECKED"
        SizeMatch=$null
        SizeAnomalyPercent=$null
        Keep=[int]$Job.Keep
        RetentionCandidates=@()

        UploadDurationSec=$null
        UploadSpeedMBps=$null
        MaintenanceUntil=$null
        RestoreVerifyStatus="DISABLED"
        RestoreVerifyAt=$null
        LastChecked=$null
    }
}

# On a fresh installation state.json does not exist yet.  The desktop app must
# still be able to render the dashboard/settings before the first check.
if (Test-Path $stateFile -PathType Leaf) {
    $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
}
else {
    $state = [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToString("o")
        Jobs        = @()
    }
}
# v23.11: the visible database list is driven by the effective
# configuration (BackupJobs.psd1 + managed-jobs.json), not only state.json.
# This makes newly added databases appear immediately, even before their
# first BackupS3 check.
$managedJobsPath=Resolve-LocalConfigPath $config.Global.ManagedJobsFile
$effectiveJobs=Get-EffectiveDashboardJobs -BaseJobs $config.Jobs -ManagedJobsPath $managedJobsPath
$stateJobs=@($state.Jobs)
$jobs=@()

foreach($configured in $effectiveJobs){
    $name=[string]$configured.Name
    $existing=@(
        $stateJobs |
        Where-Object{[string]$_.Name -eq $name} |
        Select-Object -First 1
    )

    if($existing.Count){
        $row=$existing[0]

        # Configuration wins for fields which can be edited without waiting
        # for another check.
        $row.LocalPath=[string]$configured.LocalPath
        $row.Bucket=[string]$configured.Bucket
        $row.S3Path=[string]$configured.S3Path
        $row.Keep=[int]$configured.Keep
        $row.ExpectedBackupTime=[string]$configured.ExpectedBackupTime
        $row.ExpectedDays=[string]$configured.ExpectedDays

        $jobs+=$row
    }else{
        $jobs+=New-UncheckedDashboardState $configured
    }
}

$jobs=@($jobs|Sort-Object Name)

$history = @()
$historyFile = Resolve-LocalConfigPath $config.Global.HistoryFile
if (Test-Path $historyFile) {
    try {
        $cutoff = (Get-Date).AddDays(-[int]$config.Global.HistoryDays)
        $history = @(
            Get-Content $historyFile -Encoding UTF8 |
            ForEach-Object {
                try { $_ | ConvertFrom-Json } catch { $null }
            } |
            Where-Object { $null -ne $_ -and [datetime]$_.timestamp -ge $cutoff }
        )
    } catch {}
}

function New-SparklineSvg {
    param($Points)
    $p=@($Points|Where-Object{[double]$_.sizeBytes -gt 0}|Select-Object -Last 30)
    if($p.Count -lt 2){return '<span class="muted">нет данных</span>'}
    $vals=@($p|ForEach-Object{[double]$_.sizeBytes})
    $min=($vals|Measure-Object -Minimum).Minimum;$max=($vals|Measure-Object -Maximum).Maximum
    if($max -eq $min){$max=$min+1}
    $coords=@()
    for($i=0;$i -lt $vals.Count;$i++){
        $x=[math]::Round(($i/($vals.Count-1))*120,1)
        $y=[math]::Round(28-(($vals[$i]-$min)/($max-$min))*24,1)
        $coords+="$x,$y"
    }
    return "<svg class='spark' viewBox='0 0 120 32' preserveAspectRatio='none'><polyline points='$($coords -join " ")'/></svg>"
}

$total = $jobs.Count
$ok = @($jobs | Where-Object {
    $_.Status -in @("OK","UPLOADED","READY") -and
    -not ([int]$_.S3ObjectCount -gt [int]$_.Keep)
}).Count

$waiting = @($jobs | Where-Object {
    $_.Status -eq "WAITING" -or
    (
        $_.Status -in @("OK","UPLOADED","READY") -and
        [int]$_.S3ObjectCount -gt [int]$_.Keep
    )
}).Count
$stale = @($jobs | Where-Object { $_.Status -eq "STALE" }).Count
$errors = @($jobs | Where-Object { $_.Status -eq "ERROR" }).Count

$localFiles = [int](($jobs | Measure-Object -Property LocalFileCount -Sum).Sum)
$localBytes = [Int64](($jobs | Measure-Object -Property LocalTotalBytes -Sum).Sum)
$s3Objects = [int](($jobs | Measure-Object -Property S3ObjectCount -Sum).Sum)
$s3Bytes = [Int64](($jobs | Measure-Object -Property S3TotalBytes -Sum).Sum)
$healthy = @($jobs | Where-Object { [int]$_.HealthScore -ge 90 }).Count
$problems = @($jobs | Where-Object {
    $_.Status -in @("ERROR","STALE","WARNING","WAITING") -or
    (
        $_.Status -in @("OK","UPLOADED","READY") -and
        [int]$_.S3ObjectCount -gt [int]$_.Keep
    )
}).Count

function Convert-EventToRussian {
    param(
        [string]$Event,
        [string]$Message = ""
    )

    switch($Event){
        "JOB_ADDED" {
            return "база добавлена в Backup S3 Manager"
        }
        "JOB_DELETED" {
            return "база удалена из Backup S3 Manager"
        }
        "BACKUP_SEEN" {
            return "обнаружена новая локальная резервная копия"
        }
        "UPLOAD_SUCCESS" {
            return "резервная копия успешно загружена на S3"
        }
        "ALERT" {
            if([string]::IsNullOrWhiteSpace($Message)){ return "обнаружена проблема" }
            return "проблема: $Message"
        }
        "RECOVERY" {
            if([string]::IsNullOrWhiteSpace($Message)){ return "работа восстановлена" }
            return "восстановлено: $Message"
        }
        "ERROR" {
            if([string]::IsNullOrWhiteSpace($Message)){ return "ошибка резервной копии" }
            return "ошибка: $Message"
        }
        "UPLOAD_FAILED" {
            if([string]::IsNullOrWhiteSpace($Message)){ return "ошибка загрузки на S3" }
            return "ошибка загрузки на S3: $Message"
        }
        "VERIFY_SUCCESS" {
            return "проверка резервной копии завершена успешно"
        }
        "VERIFY_FAILED" {
            if([string]::IsNullOrWhiteSpace($Message)){ return "ошибка проверки резервной копии" }
            return "ошибка проверки резервной копии: $Message"
        }
        default {
            if([string]::IsNullOrWhiteSpace($Message)){
                return $Event
            }
            return "$Event — $Message"
        }
    }
}


function Get-NextExpectedBackup {
    param(
        $Job,
        [datetime]$From = (Get-Date)
    )

    if($null -eq $Job -or [string]::IsNullOrWhiteSpace([string]$Job.ExpectedBackupTime)){
        return $null
    }

    try{
        $parts=([string]$Job.ExpectedBackupTime).Split(":")
        $hour=[int]$parts[0]
        $minute=[int]$parts[1]

        for($i=0;$i -le 8;$i++){
            $date=$From.Date.AddDays($i)

            $mode=[string]$Job.ExpectedDays
            if($mode -eq "Weekdays" -and $date.DayOfWeek -in @([DayOfWeek]::Saturday,[DayOfWeek]::Sunday)){continue}
            if($mode -eq "Weekends" -and $date.DayOfWeek -notin @([DayOfWeek]::Saturday,[DayOfWeek]::Sunday)){continue}
            if($mode -notin @("","Daily","Weekdays","Weekends") -and @($mode.Split(",")|ForEach-Object{$_.Trim()}) -notcontains [string]$date.DayOfWeek){continue}

            $candidate=$date.AddHours($hour).AddMinutes($minute)
            if($candidate -gt $From){
                return $candidate
            }
        }
    }catch{}

    return $null
}

function Get-RecentEventHint {
    param(
        $EventItem,
        $AllHistory,
        $AllJobs
    )

    $database=[string]$EventItem.database
    $event=[string]$EventItem.event
    $file=[string]$EventItem.file
    $eventTime=[datetime]$EventItem.timestamp
    $job=@($AllJobs|Where-Object{[string]$_.Name -eq $database}|Select-Object -First 1)[0]

    $next=Get-NextExpectedBackup -Job $job -From (Get-Date)
    $nextText=if($next){"Следующая плановая загрузка на S3: $($next.ToString('dd.MM.yyyy HH:mm'))."}else{"Время плановой загрузки не задано."}

    if($event -eq "BACKUP_SEEN"){
        $upload=@(
            $AllHistory |
            Where-Object {
                [string]$_.database -eq $database -and
                [string]$_.event -eq "UPLOAD_SUCCESS" -and
                ([datetime]$_.timestamp) -ge $eventTime -and
                (
                    [string]::IsNullOrWhiteSpace($file) -or
                    [string]$_.file -eq $file
                )
            } |
            Sort-Object {[datetime]$_.timestamp} |
            Select-Object -First 1
        )

        if($upload.Count){
            return "Файл уже загружен на S3: $(([datetime]$upload[0].timestamp).ToString('dd.MM.yyyy HH:mm:ss')). $nextText"
        }

        if($job -and $job.SyncStatus -eq "SYNCED" -and [string]$job.LocalFile -eq $file){
            return "Текущая резервная копия уже синхронизирована с S3. $nextText"
        }

        return "Файл обнаружен локально, но успешная загрузка ещё не подтверждена. При разрешённой загрузке файл будет отправлен по расписанию. $nextText"
    }

    if($event -eq "UPLOAD_SUCCESS"){
        return "Загрузка на S3 уже выполнена: $($eventTime.ToString('dd.MM.yyyy HH:mm:ss')). $nextText"
    }

    if($event -eq "ERROR" -or $event -eq "UPLOAD_FAILED" -or $event -eq "ALERT"){
        return "Последнее событие требует внимания. $nextText"
    }

    if($event -eq "RECOVERY"){
        return "Работа восстановлена: $($eventTime.ToString('dd.MM.yyyy HH:mm:ss')). $nextText"
    }

    return $nextText
}

$todayUploads = @($history | Where-Object { $_.event -eq "UPLOAD_SUCCESS" -and ([datetime]$_.timestamp).Date -eq (Get-Date).Date })
$todayBytes = [Int64](($todayUploads | Measure-Object -Property sizeBytes -Sum).Sum)


$uiSettingsFile = Join-Path $PSScriptRoot "State\ui-settings.json"
$uiSettings = [PSCustomObject]@{
    Jobs=[PSCustomObject]@{}
    DefaultSort="priority"
    ShowFavorites=$true
}
if(Test-Path $uiSettingsFile){
    try{$uiSettings=Get-Content $uiSettingsFile -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
}

function Get-JobUi {
    param([string]$Name)
    $default=[PSCustomObject]@{
        Pinned=$false
        Priority="Normal"
        Accent="default"
        Alias=""
        Group=""
        Note=""
    }

    if($null -ne $uiSettings.Jobs){
        $p=$uiSettings.Jobs.PSObject.Properties[$Name]
        if($null -ne $p){
            foreach($prop in $p.Value.PSObject.Properties){
                $default.$($prop.Name)=$prop.Value
            }
        }
    }
    return $default
}

function Get-PriorityWeight {
    param([string]$Priority)
    switch($Priority){
        "Critical"{0}
        "High"{1}
        "Normal"{2}
        "Low"{3}
        default{2}
    }
}

$displayJobs=@(
    $jobs|ForEach-Object{
        $ui=Get-JobUi $_.Name
        [PSCustomObject]@{
            Job=$_
            Ui=$ui
            PinWeight=if([bool]$ui.Pinned){0}else{1}
            PriorityWeight=Get-PriorityWeight ([string]$ui.Priority)
        }
    }|Sort-Object PinWeight,PriorityWeight,@{Expression={$_.Job.Name}}
)


function Get-NextExpectedForDashboard {
    param($Job,[datetime]$From=(Get-Date))
    if($null -eq $Job -or [string]::IsNullOrWhiteSpace([string]$Job.ExpectedBackupTime)){return $null}
    try{
        $p=([string]$Job.ExpectedBackupTime).Split(":")
        $h=[int]$p[0];$m=[int]$p[1]
        for($i=0;$i -le 8;$i++){
            $d=$From.Date.AddDays($i)
            $mode=[string]$Job.ExpectedDays
            if($mode -eq "Weekdays" -and $d.DayOfWeek -in @([DayOfWeek]::Saturday,[DayOfWeek]::Sunday)){continue}
            if($mode -eq "Weekends" -and $d.DayOfWeek -notin @([DayOfWeek]::Saturday,[DayOfWeek]::Sunday)){continue}
            if($mode -notin @("","Daily","Weekdays","Weekends") -and @($mode.Split(",")|ForEach-Object{$_.Trim()}) -notcontains [string]$d.DayOfWeek){continue}
            $c=$d.AddHours($h).AddMinutes($m)
            if($c -gt $From){return $c}
        }
    }catch{}
    return $null
}

$rows = New-Object System.Text.StringBuilder

foreach ($entry in $displayJobs) {
    $job=$entry.Job
    $jobUi=$entry.Ui

    # v21.33: State from an older controller run may still say OK while the
    # already-known S3 inventory clearly exceeds Keep. The Dashboard must not
    # hide that condition.
    if(
        [int]$job.S3ObjectCount -gt [int]$job.Keep -and
        [string]$job.Status -in @("OK","UPLOADED","READY","UNKNOWN")
    ){
        $excess=[int]$job.S3ObjectCount-[int]$job.Keep
        $job.Status="WAITING"
        $job.StatusText=
            "На S3 файлов больше лимита: $($job.S3ObjectCount), хранить $($job.Keep). " +
            "Ожидается удаление $excess старых резервных копий"

        if(@($job.ReasonCodes) -notcontains "RETENTION_PENDING"){
            $job.ReasonCodes=@($job.ReasonCodes)+"RETENTION_PENDING"
        }
    }
    $nextExpected=Get-NextExpectedForDashboard $job
    $nextExpectedIso=if($nextExpected){$nextExpected.ToString("o")}else{""}

    $statusClass = switch ($job.Status) {
        "OK"       { "ok" }
        "UPLOADED" { "uploaded" }
        "READY"    { "ready" }
        "WAITING"  { "waiting" }
        "STALE"    { "stale" }
        "ERROR"    { "error" }
        default    { "unknown" }
    }

    $localObjectsHtml = "0"
    if ($null -ne $job.LocalObjects -and @($job.LocalObjects).Count -gt 0) {
        $localRows = New-Object System.Text.StringBuilder

        foreach ($obj in @($job.LocalObjects)) {
            [void]$localRows.AppendLine(
                "<tr><td>$(ConvertTo-HtmlSafe $obj.Name)</td><td>$(ConvertTo-HtmlSafe (Format-Bytes ([Int64]$obj.SizeBytes)))</td><td>$(ConvertTo-HtmlSafe (Format-DateValue $obj.LastWriteTime))</td></tr>"
            )
        }

        $localObjectsHtml = @"
<details>
    <summary>$($job.LocalFileCount) файл(ов)</summary>
    <div class="object-wrap local-object-wrap">
        <table class="object-table">
            <thead><tr><th>Имя файла</th><th>Размер</th><th>Дата изменения</th></tr></thead>
            <tbody>$($localRows.ToString())</tbody>
        </table>
    </div>
</details>
"@
    }

    $objectsHtml = '<span class="row-s3-summary">0 объект(ов)</span>'
    if ($null -ne $job.S3Objects -and @($job.S3Objects).Count -gt 0) {
        $objectRows = New-Object System.Text.StringBuilder
        foreach ($obj in @($job.S3Objects)) {
            [void]$objectRows.AppendLine(
                "<tr><td>$(ConvertTo-HtmlSafe $obj.Key)</td><td>$(ConvertTo-HtmlSafe (Format-Bytes ([Int64]$obj.SizeBytes)))</td><td>$(ConvertTo-HtmlSafe (Format-DateValue $obj.LastModified))</td></tr>"
            )
        }

        $objectsHtml = @"
<details>
    <summary class="row-s3-summary">$($job.S3ObjectCount) объект(ов)</summary>
    <div class="object-wrap">
        <table class="object-table">
            <thead><tr><th>Key</th><th>Размер</th><th>Дата изменения</th></tr></thead>
            <tbody>$($objectRows.ToString())</tbody>
        </table>
    </div>
</details>
"@
    }

    $retentionClass = if ([int]$job.S3ObjectCount -gt [int]$job.Keep) { "retention-warn" } else { "" }

    [void]$rows.AppendLine(@"
<tr class="db-row accent-$(ConvertTo-HtmlSafe $jobUi.Accent) $(if($jobUi.Pinned){'pinned-row'}else{''})" draggable="true"
    data-db="$(ConvertTo-HtmlSafe $job.Name)"
    data-status="$(ConvertTo-HtmlSafe $job.Status)"
    data-pinned="$(if($jobUi.Pinned){'1'}else{'0'})"
    data-priority="$(ConvertTo-HtmlSafe $jobUi.Priority)"
    data-age="$([double]$job.AgeHours)"
    data-size="$([Int64]$job.LocalSizeBytes)"
    data-search="$(ConvertTo-HtmlSafe (($job.Name + ' ' + $jobUi.Alias + ' ' + $jobUi.Group + ' ' + $job.Bucket + ' ' + $job.S3Path + ' ' + $job.LocalFile).ToLower()))">
    <td class="db">
        <div class="db-name db-hover-target"
             data-next="$(ConvertTo-HtmlSafe $nextExpectedIso)"
             data-sync="$(ConvertTo-HtmlSafe $job.SyncStatus)"
             data-health="$($job.HealthScore)"
             data-local-count="$($job.LocalFileCount)"
             data-s3-count="$($job.S3ObjectCount)"
             data-status-text="$(ConvertTo-HtmlSafe $job.StatusText)"
             data-expected-time="$(ConvertTo-HtmlSafe $job.ExpectedBackupTime)">
            <input class="db-select" type="checkbox" data-db="$(ConvertTo-HtmlSafe $job.Name)" title="Выбрать для групповой проверки">
            $(if($jobUi.Pinned){"<span class='pin-star' title='Закреплено'>★</span>"}else{""})
            <span class="db-display-name">$(ConvertTo-HtmlSafe $(if([string]::IsNullOrWhiteSpace([string]$jobUi.Alias)){$job.Name}else{$jobUi.Alias}))</span>
            <button class="edit-job edit-job-icon" type="button" data-job="$(ConvertTo-HtmlSafe $job.Name)" title="Редактировать базу" aria-label="Редактировать базу">✎</button>
        </div>
        $(if(-not [string]::IsNullOrWhiteSpace([string]$jobUi.Alias)){"<div class='db-tech-name'>$(ConvertTo-HtmlSafe $job.Name)</div>"}else{""})
        <div class="db-meta">
            $(if($jobUi.Priority -ne "Normal"){"<span class='priority-badge priority-$($jobUi.Priority.ToLower())'>$(ConvertTo-HtmlSafe $jobUi.Priority)</span>"}else{""})
            $(if(-not [string]::IsNullOrWhiteSpace([string]$jobUi.Group)){"<span class='group-badge'>$(ConvertTo-HtmlSafe $jobUi.Group)</span>"}else{""})
        </div>
        $(if(-not [string]::IsNullOrWhiteSpace([string]$jobUi.Note)){"<div class='db-note'>$(ConvertTo-HtmlSafe $jobUi.Note)</div>"}else{""})
        <div class="db-actions">
            <button class="check-job" type="button" data-job="$(ConvertTo-HtmlSafe $job.Name)" title="Проверить только эту базу">Проверить</button>
            <button class="maintenance-job" type="button" data-job="$(ConvertTo-HtmlSafe $job.Name)" data-active="$(if($job.Status -eq 'MAINTENANCE'){'1'}else{'0'})">$(if($job.Status -eq 'MAINTENANCE'){'Возобновить'}else{'Пауза 2ч'})</button>
            <button class="retention-job" type="button" data-job="$(ConvertTo-HtmlSafe $job.Name)">Очистка</button>
            <button class="delete-job" type="button" data-job="$(ConvertTo-HtmlSafe $job.Name)" title="Удалить базу">Удалить</button>
        </div>
    </td>
    <td>
        <span class="status $statusClass">$(ConvertTo-HtmlSafe (Get-StatusLabel $job.Status))</span>
        <div class="health-score">Состояние: $($job.HealthScore)%</div>
        <div class="reason-codes">$(ConvertTo-HtmlSafe ((@($job.ReasonCodes | ForEach-Object { Get-ReasonLabel ([string]$_) }) -join ", ")))</div>
    </td>
    <td class="message">$(ConvertTo-HtmlSafe $job.StatusText)</td>
    <td>
        <div class="filename">$(ConvertTo-HtmlSafe $job.LocalFile)</div>
        <div class="muted">$(ConvertTo-HtmlSafe $job.LocalPath)</div>
        <div class="db-upload-progress" data-upload-db="$(ConvertTo-HtmlSafe $job.Name)" hidden>
            <div class="db-upload-progress-head">
                <span class="db-upload-progress-text">Загрузка...</span>
                <span class="db-upload-progress-percent">0%</span>
            </div>
            <div class="db-upload-progress-track"><div class="db-upload-progress-fill"></div></div>
            <div class="db-upload-progress-meta"></div>
        </div>
    </td>
    <td>$(ConvertTo-HtmlSafe (Format-Bytes ([Int64]$job.LocalSizeBytes)))</td>
    <td>$localObjectsHtml<div class="muted">$(ConvertTo-HtmlSafe (Format-Bytes ([Int64]$job.LocalTotalBytes)))</div></td>
    <td>$(ConvertTo-HtmlSafe (Format-DateValue $job.LocalLastWrite))</td>
    <td>$([string]$job.AgeHours) ч</td>
    <td>
        <div>$(ConvertTo-HtmlSafe ("s3://{0}/{1}" -f $job.Bucket, $job.S3Path))</div>
        <div class="muted">$(ConvertTo-HtmlSafe $job.S3Key)</div>
    </td>
    <td class="$retentionClass">$objectsHtml<div class="muted">Хранить: $(ConvertTo-HtmlSafe $job.Keep) файла</div></td>
    <td class="row-s3-bytes">$(ConvertTo-HtmlSafe (Format-Bytes ([Int64]$job.S3TotalBytes)))</td>
    <td class="row-s3-latest">$(ConvertTo-HtmlSafe (Format-DateValue $job.S3Latest))</td>
    <td>
        <strong>$(ConvertTo-HtmlSafe (Get-SyncStatusLabel $job.SyncStatus))</strong>
        <div class="muted">Размер: $(if($null -eq $job.SizeMatch){"-"}elseif($job.SizeMatch){"совпадает"}else{"не совпадает"})</div>
    </td>
    <td>
        <div>$(ConvertTo-HtmlSafe $job.ExpectedBackupTime) ($(ConvertTo-HtmlSafe $job.ExpectedDays))</div>
        <div class="muted">delay: $(if($null -eq $job.ScheduleDelayMinutes){"-"}else{"$($job.ScheduleDelayMinutes) мин"})</div>
    </td>
    <td>$(New-SparklineSvg (@($history | Where-Object { $_.database -eq $job.Name -and $_.event -in @("BACKUP_SEEN","UPLOAD_SUCCESS") })))</td>
    <td>$(ConvertTo-HtmlSafe (Format-DateValue $job.LastChecked))</td>
</tr>
"@)
}

$generated = Format-DateValue $state.GeneratedAt
$cssHref = Split-Path $cssFile -Leaf

$html = @"
<!doctype html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Backup S3 Dashboard</title>
    <link rel="stylesheet" href="$cssHref">
<style>

    /* v23.12 — compact BackupS3 brand selected from logo concept D */
    .dashboard-brand{
        display:flex;
        align-items:center;
        gap:11px;
        min-width:0;
        cursor:pointer;
        border-radius:9px;
        padding:3px 5px 3px 2px;
    }
    .dashboard-brand:hover{background:rgba(89,197,255,.07)}
    .dashboard-brand:focus-visible{outline:2px solid #59c5ff;outline-offset:2px}
    .dashboard-brand-symbol{
        position:relative;
        width:46px;
        height:46px;
        flex:0 0 46px;
        overflow:hidden;
        border-radius:12px;
        box-shadow:0 0 18px rgba(73,185,255,.18);
    }
    .dashboard-brand-symbol::before{
        display:none;
    }
    .dashboard-brand-symbol::after{
        content:"";
        position:absolute;
        inset:-8px;
        border-radius:16px;
        background:conic-gradient(transparent 0 76%,rgba(89,197,255,.15) 82%,#8bdcff 91%,transparent 98%);
        -webkit-mask:linear-gradient(#000 0 0) content-box,linear-gradient(#000 0 0);
        -webkit-mask-composite:xor;
        mask-composite:exclude;
        padding:9px;
        animation:dashboard-brand-orbit 2.1s linear infinite;
        pointer-events:none;
    }
    .dashboard-brand-symbol img{display:block;width:100%;height:100%;object-fit:cover;border-radius:12px}
    .dashboard-brand-title{
        display:flex;
        align-items:baseline;
        gap:8px;
        white-space:nowrap;
    }
    .dashboard-brand-title h1{margin:0;font-weight:650;letter-spacing:-.55px}
    .dashboard-brand-title h1 strong{color:#59c5ff;font-weight:700}
    .dashboard-brand-title em{color:#8f9caf;font-size:13px;font-style:normal;font-weight:500;letter-spacing:.08em;text-transform:uppercase}
    @keyframes dashboard-brand-orbit{to{transform:rotate(360deg)}}
    @media(prefers-reduced-motion:reduce){.dashboard-brand-symbol::after{animation:none}}
    @media(max-width:720px){.dashboard-brand-title em{display:none}.dashboard-brand-symbol{width:40px;height:40px;flex-basis:40px}}

    /* v19 visual accent palette */
    .accent-field{
        display:flex;
        flex-direction:column;
        gap:7px;
    }
    .accent-palette{
        display:flex;
        align-items:center;
        flex-wrap:wrap;
        gap:10px;
        min-height:42px;
        padding:8px 10px;
        border:1px solid #3b4652;
        border-radius:8px;
        background:#11161c;
    }
    .accent-swatch{
        width:27px;
        height:27px;
        min-width:27px;
        padding:0;
        border:2px solid transparent;
        border-radius:50%;
        cursor:pointer;
        box-shadow:0 0 0 1px rgba(255,255,255,.14);
        transition:transform .12s ease,box-shadow .12s ease,border-color .12s ease;
    }
    .accent-swatch:hover{
        transform:scale(1.12);
        box-shadow:0 0 0 2px rgba(255,255,255,.28);
    }
    .accent-swatch.selected{
        transform:scale(1.12);
        border-color:#fff;
        box-shadow:0 0 0 2px #11161c,0 0 0 4px rgba(115,177,230,.9);
    }
    .swatch-default{
        background:linear-gradient(135deg,#59616c 0 44%,#222831 44% 56%,#59616c 56% 100%);
    }
    .swatch-red{background:#d45a64}
    .swatch-orange{background:#db8b45}
    .swatch-yellow{background:#d6b94d}
    .swatch-green{background:#4ca878}
    .swatch-blue{background:#4b8fc7}
    .swatch-purple{background:#8b6bc7}

    html[data-theme="light"] .accent-palette{
        background:#f7f9fb;
        border-color:#ccd5df;
    }
    html[data-theme="light"] .accent-swatch.selected{
        border-color:#fff;
        box-shadow:0 0 0 2px #f7f9fb,0 0 0 4px #3f78a8;
    }

</style>
<style>

    /* v19 — unified modal action buttons */
    .modal-btn{
        appearance:none;
        min-height:32px;
        padding:6px 12px;
        border-radius:6px;
        font:inherit;
        font-size:12px;
        font-weight:600;
        line-height:1.2;
        cursor:pointer;
        transition:background-color .15s ease,border-color .15s ease,box-shadow .15s ease,transform .08s ease;
    }
    .modal-btn:hover{
        transform:translateY(-1px);
    }
    .modal-btn:active{
        transform:translateY(0);
    }
    .modal-btn-secondary{
        color:#d9e1ea;
        background:#20262e;
        border:1px solid #46515e;
    }
    .modal-btn-secondary:hover{
        background:#29313b;
        border-color:#5b6877;
    }
    .modal-btn-primary{
        color:#dff1ff;
        background:#153d59;
        border:1px solid #377ba8;
        box-shadow:inset 0 0 0 1px rgba(255,255,255,.025);
    }
    .modal-btn-primary:hover{
        background:#1b4c6d;
        border-color:#4b94c3;
    }
    .modal-btn:focus-visible{
        outline:none;
        box-shadow:0 0 0 2px rgba(75,143,199,.32);
    }

    html[data-theme="light"] .modal-btn-secondary{
        color:#34404d;
        background:#f3f5f7;
        border-color:#b9c2cc;
    }
    html[data-theme="light"] .modal-btn-secondary:hover{
        background:#e8edf2;
        border-color:#9da9b5;
    }
    html[data-theme="light"] .modal-btn-primary{
        color:#fff;
        background:#2f6f9d;
        border-color:#275f88;
    }
    html[data-theme="light"] .modal-btn-primary:hover{
        background:#285f87;
        border-color:#204f72;
    }

    /* v23.12 — themed replacement for browser alert/confirm dialogs */
    .app-dialog-backdrop{z-index:10050;background:rgba(2,7,13,.78);backdrop-filter:blur(7px)}
    .app-dialog-card{width:min(520px,calc(100vw - 32px));padding:0;overflow:hidden;border:1px solid #344252;background:#151b22;box-shadow:0 28px 90px rgba(0,0,0,.58)}
    .app-dialog-top{display:flex;gap:14px;padding:22px 22px 14px;align-items:flex-start}
    .app-dialog-icon{width:38px;height:38px;flex:0 0 38px;display:grid;place-items:center;border-radius:11px;color:#dff3ff;background:#173d58;border:1px solid #347aa8;font-size:20px;font-weight:800}
    .app-dialog-card[data-kind="danger"] .app-dialog-icon{color:#ffe6e8;background:#52242a;border-color:#a94d58}
    .app-dialog-card[data-kind="error"] .app-dialog-icon{color:#ffe6e8;background:#52242a;border-color:#d45a64}
    .app-dialog-copy{min-width:0;padding-top:1px}
    .app-dialog-title{margin:0 0 8px;color:#f2f6fa;font-size:17px;line-height:1.25}
    .app-dialog-message{margin:0;color:#b9c6d3;font-size:13px;line-height:1.55;white-space:pre-line;overflow-wrap:anywhere}
    .app-dialog-actions{display:flex;justify-content:flex-end;gap:9px;padding:14px 22px 20px;border-top:1px solid #2a3440;background:#12171d}
    .app-dialog-card[data-kind="danger"] .app-dialog-confirm,.app-dialog-card[data-kind="error"] .app-dialog-confirm{background:#6b2831;border-color:#ba5965;color:#fff0f1}
    .app-dialog-card[data-kind="danger"] .app-dialog-confirm:hover,.app-dialog-card[data-kind="error"] .app-dialog-confirm:hover{background:#80313b;border-color:#d66b77}
    body.app-dialog-open{overflow:hidden}
    html[data-theme="light"] .app-dialog-card{background:#fff;border-color:#c4d0dc;box-shadow:0 28px 80px rgba(25,42,58,.28)}
    html[data-theme="light"] .app-dialog-title{color:#1e2b37}
    html[data-theme="light"] .app-dialog-message{color:#526171}
    html[data-theme="light"] .app-dialog-actions{background:#f4f7f9;border-color:#d8e0e7}

</style>
<style>

    /* v19.1 — collapsible editor sections */
    .collapsible-section{
        overflow:hidden;
    }
    .section-toggle{
        appearance:none;
        width:100%;
        display:flex;
        align-items:center;
        justify-content:space-between;
        gap:12px;
        margin:0 0 12px;
        padding:0;
        border:0;
        background:transparent;
        color:#e8edf3;
        font:inherit;
        font-size:14px;
        font-weight:700;
        text-align:left;
        cursor:pointer;
    }
    .section-toggle:hover{
        color:#9fd1f4;
    }
    .section-chevron{
        display:inline-flex;
        align-items:center;
        justify-content:center;
        width:24px;
        height:24px;
        border:1px solid #3a4653;
        border-radius:6px;
        color:#9bc6e9;
        font-size:15px;
        line-height:1;
        flex:0 0 24px;
    }
    .collapsible-section.collapsed{
        padding-bottom:10px;
    }
    .collapsible-section.collapsed .section-toggle{
        margin-bottom:0;
    }
    .section-content[hidden]{
        display:none !important;
    }
    .visually-hidden{
        position:absolute !important;
        width:1px !important;
        height:1px !important;
        padding:0 !important;
        margin:-1px !important;
        overflow:hidden !important;
        clip:rect(0,0,0,0) !important;
        white-space:nowrap !important;
        border:0 !important;
    }

    /* Better feedback for modal auto-scroll zones */
    #editJobModal .modal-card{
        scroll-behavior:auto;
    }

    html[data-theme="light"] .section-toggle{
        color:#27313c;
    }
    html[data-theme="light"] .section-toggle:hover{
        color:#2f6f9d;
    }
    html[data-theme="light"] .section-chevron{
        border-color:#cbd4dd;
        color:#356f99;
        background:#f6f9fb;
    }

</style>
<style>

    /* v19.1 — modal footer buttons aligned with dashboard styling */
    .edit-modal-actions{
        gap:10px;
    }
    .action-btn{
        appearance:none;
        min-height:34px;
        padding:7px 13px;
        border-radius:6px;
        font:inherit;
        font-size:12px;
        font-weight:600;
        line-height:1.1;
        cursor:pointer;
        transition:background-color .15s ease,border-color .15s ease,transform .08s ease;
    }
    .action-btn:hover{transform:translateY(-1px)}
    .action-btn:active{transform:translateY(0)}
    .action-btn-neutral{
        background:#20262e;
        border:1px solid #46515e;
        color:#dbe3ec;
    }
    .action-btn-neutral:hover{
        background:#29313b;
        border-color:#647181;
    }
    .action-btn-primary{
        background:#173e5a;
        border:1px solid #3b7ca8;
        color:#dff2ff;
    }
    .action-btn-primary:hover{
        background:#1e4e70;
        border-color:#55a0cf;
    }

    /* v19.1 — local backup section */
    .edit-local-section{
        margin-top:16px;
        padding:14px;
        border:1px solid #303642;
        border-radius:10px;
        background:#14171c;
    }
    .edit-local-head{
        display:flex;
        justify-content:space-between;
        align-items:flex-start;
        gap:15px;
        margin-bottom:9px;
    }
    .edit-local-head p{
        margin:0;
        color:#8f98a5;
        font-size:11px;
    }
    .edit-local-controls{
        display:flex;
        align-items:center;
        gap:10px;
        white-space:nowrap;
    }
    .edit-local-list{
        max-height:330px;
        overflow:auto;
        border-top:1px solid #303642;
    }
    .edit-local-row{
        display:flex;
        align-items:center;
        justify-content:space-between;
        gap:14px;
        padding:9px 0;
        border-bottom:1px solid #292e37;
    }
    .local-file-actions{
        display:flex;
        align-items:center;
        gap:8px;
        flex:0 0 auto;
    }
    .local-s3-badge{
        display:inline-flex;
        align-items:center;
        padding:3px 7px;
        border-radius:999px;
        font-size:9px;
        white-space:nowrap;
    }
    .local-s3-badge.on-s3{
        background:#173a2b;
        border:1px solid #2f7755;
        color:#8be0b7;
    }
    .local-s3-badge.missing-s3{
        background:#3d2d18;
        border:1px solid #78602e;
        color:#f1c86d;
    }
    .manual-upload-button{
        min-width:112px;
        padding:6px 9px;
        border:1px solid #3e719a;
        border-radius:6px;
        background:#18324a;
        color:#b9dcf6;
        cursor:pointer;
        font-size:10px;
    }
    .manual-upload-button:hover{
        background:#234966;
        color:#fff;
    }
    .manual-upload-button:disabled{
        opacity:.6;
        cursor:wait;
    }

    html[data-theme="light"] .action-btn-neutral{
        color:#34404d;
        background:#f3f5f7;
        border-color:#b9c2cc;
    }
    html[data-theme="light"] .action-btn-primary{
        color:#fff;
        background:#2f6f9d;
        border-color:#275f88;
    }
    html[data-theme="light"] .edit-local-section{
        background:#f8fafc;
        border-color:#d7dde4;
    }

</style>
<style>

    /* ============================================================
       v20 — live log
       ============================================================ */
    .log-button{
        padding:8px 12px;
        border:1px solid #536f89;
        border-radius:7px;
        background:#1a2a37;
        color:#a9d4f3;
        cursor:pointer;
    }
    .log-button:hover{
        background:#24445f;
        border-color:#79acd2;
        color:#fff;
    }

    .log-modal-card{
        width:min(1250px,97vw);
        height:min(84vh,900px);
        display:flex;
        flex-direction:column;
    }

    .log-toolbar{
        display:grid;
        grid-template-columns:125px 125px minmax(140px,200px) minmax(220px,1fr) 120px auto auto auto;
        gap:8px;
        align-items:center;
        margin-bottom:9px;
    }

    .log-toolbar input,
    .log-toolbar select{
        min-height:34px;
        padding:7px 9px;
        border:1px solid #353d48;
        border-radius:6px;
        background:#11161c;
        color:#e7edf4;
    }

    .log-follow{
        display:flex;
        align-items:center;
        gap:6px;
        white-space:nowrap;
        color:#adb7c3;
        font-size:11px;
    }

    .log-status{
        min-height:20px;
        margin-bottom:7px;
        color:#8fa3b5;
        font-size:10px;
    }

    .log-output{
        flex:1 1 auto;
        min-height:300px;
        margin:0;
        padding:12px;
        overflow:auto;
        border:1px solid #303945;
        border-radius:8px;
        background:#0c1015;
        color:#cbd5df;
        font:11px/1.55 Consolas,"Courier New",monospace;
        white-space:pre-wrap;
        word-break:break-word;
    }

    .log-output span{
        display:block;
    }

    .log-line-info{color:#c4ced8}
    .log-line-warn{color:#f0c96d}
    .log-line-error{color:#ff858e}
    .log-line-success{color:#79d6a5}

    .progress-right{
        display:flex;
        align-items:center;
        gap:12px;
    }

    .progress-stall{
        font-size:10px;
        font-weight:600;
    }
    .progress-stall.warning{color:#f0c96d}
    .progress-stall.danger{color:#ff858e}

    html[data-theme="light"] .log-button{
        background:#e9f2f8;
        color:#2b638b;
        border-color:#82abc8;
    }

    html[data-theme="light"] .log-toolbar input,
    html[data-theme="light"] .log-toolbar select{
        background:#fff;
        color:#222b35;
        border-color:#c7d0da;
    }

    html[data-theme="light"] .log-output{
        background:#f7f9fb;
        color:#2d3742;
        border-color:#cbd4dd;
    }

    html[data-theme="light"] .log-line-info{color:#34404d}
    html[data-theme="light"] .log-line-warn{color:#986b00}
    html[data-theme="light"] .log-line-error{color:#b72c36}
    html[data-theme="light"] .log-line-success{color:#26734a}

    @media(max-width:1000px){
        .log-toolbar{
            grid-template-columns:1fr 1fr;
        }
    }

</style>
<style>

    /* v20.1 — Log button in header */
    .header-log-button{
        margin-right:2px;
        min-height:36px;
    }

</style>
<style>

    /* ============================================================
       v20.2 — Recent events: tooltip + navigation to DB row
       ============================================================ */
    .recent-event{
        position:relative;
        padding:2px 0;
        overflow:visible;
    }

    .event-time{
        color:#a9b3bf;
    }

    .event-db-link{
        appearance:none;
        padding:0;
        border:0;
        background:transparent;
        color:#e8edf3;
        font:inherit;
        font-weight:700;
        cursor:pointer;
        text-decoration:none;
    }

    .event-db-link:hover{
        color:#77bde8;
        text-decoration:underline;
        text-underline-offset:2px;
    }

    .recent-event::after{
        content:attr(data-tooltip);
        position:absolute;
        left:0;
        bottom:calc(100% + 8px);
        z-index:1200;
        width:min(440px,70vw);
        padding:9px 11px;
        border:1px solid #465363;
        border-radius:7px;
        background:#101820;
        color:#dce7ef;
        font-size:10px;
        line-height:1.45;
        box-shadow:0 8px 28px rgba(0,0,0,.38);
        opacity:0;
        visibility:hidden;
        transform:translateY(4px);
        transition:opacity .12s ease,transform .12s ease,visibility .12s ease;
        pointer-events:none;
        white-space:normal;
    }

    .recent-event::before{
        content:"";
        position:absolute;
        left:18px;
        bottom:calc(100% + 2px);
        z-index:1201;
        border:6px solid transparent;
        border-top-color:#465363;
        opacity:0;
        visibility:hidden;
        transition:opacity .12s ease,visibility .12s ease;
    }

    .recent-event:hover::after,
    .recent-event:hover::before{
        opacity:1;
        visibility:visible;
        transform:translateY(0);
    }

    #jobs tbody tr.event-row-highlight{
        position:relative;
        background:linear-gradient(
            90deg,
            rgba(62,130,180,.22),
            rgba(62,130,180,.08) 52%,
            rgba(62,130,180,.02)
        ) !important;
        outline:2px solid rgba(82,159,211,.72);
        outline-offset:-2px;
        box-shadow:
            inset 5px 0 0 #4c9bd0,
            0 0 20px rgba(72,145,194,.22);
    }

    #jobs tbody tr.event-row-highlight td:first-child{
        background:#1b2b39 !important;
        box-shadow:
            inset 5px 0 0 #4c9bd0,
            1px 0 0 #435a6d,
            10px 0 20px rgba(0,0,0,.18);
    }

    #jobs tbody tr.event-row-highlight-pulse{
        animation:eventRowPulse .8s ease-in-out 3;
    }

    @keyframes eventRowPulse{
        0%,100%{
            outline-color:rgba(82,159,211,.55);
        }
        50%{
            outline-color:rgba(122,202,255,1);
            box-shadow:
                inset 5px 0 0 #62b7ef,
                0 0 28px rgba(85,180,240,.38);
        }
    }

    html[data-theme="light"] .event-db-link{
        color:#2d3d4c;
    }

    html[data-theme="light"] .event-db-link:hover{
        color:#276f9f;
    }

    html[data-theme="light"] .recent-event::after{
        background:#fff;
        color:#303a45;
        border-color:#bfcbd6;
        box-shadow:0 8px 24px rgba(20,35,50,.18);
    }

    html[data-theme="light"] #jobs tbody tr.event-row-highlight{
        background:linear-gradient(
            90deg,
            rgba(70,145,196,.20),
            rgba(70,145,196,.06) 55%,
            transparent
        ) !important;
    }

    html[data-theme="light"] #jobs tbody tr.event-row-highlight td:first-child{
        background:#e4f1f9 !important;
    }

</style>
<style>

/* v20.3 — Recent events UX fix */
.events-list{
    overflow-x:hidden !important;
    overflow-y:visible !important;
    scrollbar-width:none;
}
.events-list::-webkit-scrollbar{
    display:none;
}
.ops-card:has(.events-list){
    overflow:visible !important;
}
.recent-event{
    overflow:visible !important;
}
.recent-event::after,
.recent-event::before{
    display:none !important;
}
#recentEventTooltip{
    position:fixed;
    z-index:99999;
    display:none;
    max-width:min(480px,calc(100vw - 24px));
    padding:10px 12px;
    border:1px solid #465363;
    border-radius:8px;
    background:#101820;
    color:#dce7ef;
    font-size:12px;
    line-height:1.45;
    box-shadow:0 10px 30px rgba(0,0,0,.45);
    pointer-events:none;
    white-space:normal;
}
html[data-theme="light"] #recentEventTooltip{
    background:#fff;
    color:#263441;
    border-color:#bfcbd6;
    box-shadow:0 10px 28px rgba(20,35,50,.20);
}

</style>
<style>

    /* ============================================================
       v21
       ============================================================ */
    .modal-actions-spacer{flex:1}
    .db-select{
        width:15px!important;height:15px!important;min-width:15px;
        accent-color:#4b8fc7;cursor:pointer;margin:0 2px 0 0;
    }
    .db-hover-tooltip{
        position:fixed;z-index:100000;display:none;width:min(390px,calc(100vw - 20px));
        padding:10px 12px;border:1px solid #496075;border-radius:8px;
        background:#101820;color:#dce7ef;box-shadow:0 10px 28px rgba(0,0,0,.4);
        pointer-events:none;font-size:11px;line-height:1.5;
    }
    .db-hover-tooltip strong{display:block;font-size:12px;margin-bottom:4px;color:#fff}
    .selected-check-button{
        border:1px solid #4d7fa4;border-radius:7px;background:#1b3d57;color:#cdeaff;
        padding:8px 12px;cursor:pointer;
    }
    .cancel-check-button{
        border:1px solid #a34c52;border-radius:6px;background:#402126;color:#ffb1b7;
        padding:4px 9px;cursor:pointer;font-size:10px;
    }
    .report-modal-card{width:min(680px,95vw)}
    .report-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}
    .report-grid label{display:flex;flex-direction:column;gap:5px;color:#aeb8c4;font-size:11px}
    .report-grid input,.report-grid select{
        min-height:36px;padding:8px 10px;border:1px solid #39424e;border-radius:7px;
        background:#11161c;color:#edf3f8;
    }
    .report-hint{margin:14px 0;color:#8f9aa7;font-size:11px}
    html[data-theme="light"] .db-hover-tooltip{background:#fff;color:#263441;border-color:#bccbd7}
    html[data-theme="light"] .db-hover-tooltip strong{color:#1c2b38}
    html[data-theme="light"] .report-grid input,
    html[data-theme="light"] .report-grid select{background:#fff;color:#27313c;border-color:#c9d2db}

</style>
<style>

    /* ============================================================
       v21.7 — add-base + sorting layout
       ============================================================ */
    #sortMode{
        border-color:#3d4d5f;
    }
    #sortMode:focus{
        border-color:#6aa7d1;
        box-shadow:0 0 0 1px rgba(106,167,209,.22);
    }

    /* Nested Local/S3 tables must never inherit dimensions from the main table. */
    #jobs .object-wrap{
        display:block;
        width:min(100%,980px);
        max-width:980px;
        overflow-x:auto;
        overflow-y:hidden;
        margin-top:7px;
        border:1px solid #2d3540;
        border-radius:6px;
    }
    #jobs .object-table{
        width:100%!important;
        min-width:760px!important;
        max-width:none!important;
        table-layout:fixed!important;
        border-collapse:collapse!important;
    }
    #jobs .local-object-wrap .object-table th:nth-child(1),
    #jobs .local-object-wrap .object-table td:nth-child(1){
        width:58%!important;
    }
    #jobs .local-object-wrap .object-table th:nth-child(2),
    #jobs .local-object-wrap .object-table td:nth-child(2){
        width:17%!important;
    }
    #jobs .local-object-wrap .object-table th:nth-child(3),
    #jobs .local-object-wrap .object-table td:nth-child(3){
        width:25%!important;
    }

    #jobs .object-table th,
    #jobs .object-table td{
        position:static!important;
        min-width:0!important;
        max-width:none!important;
        box-shadow:none!important;
        padding:7px 9px!important;
        vertical-align:top;
        overflow:hidden;
        text-overflow:ellipsis;
    }
    #jobs .object-table td:first-child{
        white-space:normal!important;
        overflow-wrap:anywhere!important;
        word-break:break-word!important;
    }
    #jobs .object-table td:nth-child(2),
    #jobs .object-table td:nth-child(3){
        white-space:nowrap!important;
    }

    #jobModal .modal-actions .action-btn{
        min-width:92px;
        min-height:34px;
    }

    html[data-theme="light"] #jobs .object-wrap{
        border-color:#ccd4dc;
    }

</style>
<style>

    /* ============================================================
       v21.10 — nested Local/S3 tables are independent from main grid
       ============================================================ */

    /* Critical: the expanded table lives inside a narrow main-table cell.
       Therefore percentage width shrinks it and causes text overlap.
       Give it its own fixed readable viewport which may extend over
       neighbouring main-table cells. */
    #jobs details{
        position:relative;
        overflow:visible!important;
    }

    #jobs details[open]{
        z-index:35;
    }

    #jobs .object-wrap,
    #jobs .local-object-wrap,
    #jobs .object-wrap:not(.local-object-wrap){
        position:relative!important;
        z-index:40!important;
        display:block!important;
        width:860px!important;
        min-width:860px!important;
        max-width:860px!important;
        overflow:auto!important;
        box-sizing:border-box!important;
        background:#15191f!important;
        border:1px solid #35404d!important;
        border-radius:7px!important;
        box-shadow:0 12px 30px rgba(0,0,0,.38)!important;
    }

    #jobs .object-table,
    #jobs .local-object-wrap .object-table,
    #jobs .object-wrap:not(.local-object-wrap) .object-table{
        display:table!important;
        width:858px!important;
        min-width:858px!important;
        max-width:858px!important;
        table-layout:fixed!important;
        border-collapse:collapse!important;
        margin:0!important;
        background:#181b21!important;
    }

    /* Completely neutralise styles inherited from the main #jobs table. */
    #jobs .object-table thead,
    #jobs .object-table tbody{
        display:table-row-group!important;
        width:auto!important;
    }

    #jobs .object-table thead{
        display:table-header-group!important;
    }

    #jobs .object-table tr{
        display:table-row!important;
        width:auto!important;
        height:auto!important;
        background:transparent!important;
    }

    #jobs .object-table th,
    #jobs .object-table td,
    #jobs .object-table th:first-child,
    #jobs .object-table td:first-child{
        display:table-cell!important;
        position:static!important;
        left:auto!important;
        top:auto!important;
        z-index:auto!important;
        min-width:0!important;
        max-width:none!important;
        height:auto!important;
        padding:8px 10px!important;
        box-sizing:border-box!important;
        border-bottom:1px solid #2b323c!important;
        box-shadow:none!important;
        vertical-align:top!important;
        line-height:1.35!important;
        font-size:12px!important;
    }

    #jobs .object-table th{
        background:#222832!important;
        color:#d1d8e0!important;
        white-space:nowrap!important;
    }

    #jobs .object-table td{
        background:#181d24!important;
        color:#edf1f5!important;
    }

    #jobs .object-table th:nth-child(1),
    #jobs .object-table td:nth-child(1){
        width:520px!important;
    }

    #jobs .object-table th:nth-child(2),
    #jobs .object-table td:nth-child(2){
        width:125px!important;
        white-space:nowrap!important;
    }

    #jobs .object-table th:nth-child(3),
    #jobs .object-table td:nth-child(3){
        width:213px!important;
        white-space:nowrap!important;
    }

    #jobs .object-table td:nth-child(1){
        white-space:normal!important;
        overflow-wrap:anywhere!important;
        word-break:break-word!important;
        font-family:Consolas,monospace!important;
    }

    /* Keep wide popout inside the browser on narrower windows. */
    @media (max-width:980px){
        #jobs .object-wrap,
        #jobs .local-object-wrap,
        #jobs .object-wrap:not(.local-object-wrap){
            width:calc(100vw - 80px)!important;
            min-width:720px!important;
            max-width:calc(100vw - 80px)!important;
        }

        #jobs .object-table,
        #jobs .local-object-wrap .object-table,
        #jobs .object-wrap:not(.local-object-wrap) .object-table{
            width:858px!important;
            min-width:858px!important;
        }
    }

    .title-row{
        display:flex;
        align-items:center;
        gap:10px;
    }

    .title-row h1{
        margin:0;
    }

    .restart-dashboard-button{
        min-height:29px;
        padding:5px 10px;
        border:1px solid #3c5267;
        border-radius:7px;
        background:#172432;
        color:#aad6f5;
        cursor:pointer;
        font-size:11px;
        font-weight:600;
    }

    .restart-dashboard-button:hover{
        background:#1c3347;
        border-color:#5791bd;
        color:#e8f6ff;
    }

    .restart-dashboard-button:disabled{
        opacity:.6;
        cursor:wait;
    }

    .server-restart-overlay{
        position:fixed;
        inset:0;
        z-index:200000;
        background:rgba(6,9,13,.72);
        backdrop-filter:blur(4px);
        display:flex;
        align-items:center;
        justify-content:center;
    }

    .server-restart-overlay[hidden]{
        display:none!important;
    }

    .server-restart-card{
        min-width:310px;
        padding:24px 28px;
        border:1px solid #394756;
        border-radius:12px;
        background:#171c23;
        box-shadow:0 20px 70px rgba(0,0,0,.5);
        text-align:center;
    }

    .server-restart-card strong{
        display:block;
        font-size:16px;
        margin:10px 0 6px;
    }

    .server-restart-card span{
        color:#9eabb8;
        font-size:12px;
    }

    .restart-spinner{
        width:28px;
        height:28px;
        margin:0 auto;
        border:3px solid #2f3944;
        border-top-color:#6bb6e8;
        border-radius:50%;
        animation:restartSpin .8s linear infinite;
    }

    @keyframes restartSpin{
        to{transform:rotate(360deg)}
    }

    html[data-theme="light"] #jobs .object-wrap{
        background:#fff!important;
        border-color:#bac6d0!important;
        box-shadow:0 12px 28px rgba(30,45,60,.18)!important;
    }

    html[data-theme="light"] #jobs .object-table th{
        background:#e9eef3!important;
        color:#263442!important;
    }

    html[data-theme="light"] #jobs .object-table td{
        background:#fff!important;
        color:#263442!important;
    }

    html[data-theme="light"] .restart-dashboard-button{
        background:#eef5fa;
        border-color:#a8bfce;
        color:#326b91;
    }

</style>
<style>
    /* v21.22: finished progress is transient, not a permanent dashboard state */
    #progressPanel.finished .progress-bar{
        width:100%!important;
    }
</style><style>

    /* v21.23: safe reintroduction of AutoScheduler settings only */
    .settings-inline-note{
        margin-top:10px;
        padding:9px 11px;
        border-left:3px solid #3d769e;
        background:#111820;
        color:#92a5b5;
        font-size:10px;
        line-height:1.5;
    }

    .auto-scheduler-grid{
        margin-top:10px;
        grid-template-columns:minmax(220px,320px);
    }

    .auto-scheduler-grid input:disabled{
        opacity:.5;
        cursor:not-allowed;
    }

    html[data-theme="light"] .settings-inline-note{
        background:#eef5fa;
        color:#526877;
    }

</style>
<style>

    /* v21.24: scheduler summary inside "Проблемы сейчас" */
    .scheduler-status-box{
        margin-top:14px;
        padding-top:12px;
        border-top:1px solid #303945;
        font-size:10px;
    }

    .scheduler-status-head,
    .scheduler-status-line{
        display:flex;
        align-items:center;
        justify-content:space-between;
        gap:10px;
    }

    .scheduler-status-head{
        margin-bottom:9px;
        color:#91a4b5;
    }

    .scheduler-status-line{
        min-height:23px;
        color:#8395a5;
    }

    .scheduler-status-line strong{
        color:#dce6ef;
        text-align:right;
    }

    .scheduler-status-line .scheduler-on{
        color:#55d39a;
    }

    .scheduler-status-line .scheduler-off{
        color:#d2aa52;
    }

    .scheduler-status-line .scheduler-error{
        color:#ff858e;
    }

    .scheduler-now-button{
        min-height:27px;
        padding:5px 10px;
        border:1px solid #3d769e;
        border-radius:6px;
        background:#12324a;
        color:#dceeff;
        cursor:pointer;
        font-size:10px;
        font-weight:600;
    }

    .scheduler-now-button:hover{
        background:#184564;
    }

    html[data-theme="light"] .scheduler-status-box{
        border-top-color:#d1d8df;
    }

    html[data-theme="light"] .scheduler-now-button{
        background:#e8f3fa;
        color:#235e87;
    }

</style>
<style>

    /* v21.26: show every checked database even when the whole scan is very fast */
    .progress-checked-wrap{
        display:flex;
        align-items:flex-start;
        gap:8px;
        margin-top:8px;
        padding-top:8px;
        border-top:1px solid #2b343e;
    }

    .progress-checked-wrap[hidden]{
        display:none!important;
    }

    .progress-checked-label{
        flex:0 0 auto;
        padding-top:4px;
        color:#8294a5;
        font-size:10px;
    }

    .progress-checked{
        display:flex;
        flex-wrap:wrap;
        gap:5px;
    }

    .progress-checked-item{
        display:inline-flex;
        align-items:center;
        min-height:21px;
        padding:3px 7px;
        border:1px solid #35424e;
        border-radius:999px;
        background:#121920;
        color:#aebbc7;
        font-size:9px;
    }

    .progress-checked-item.current{
        border-color:#3e976e;
        background:#153428;
        color:#6fe0a7;
    }

    html[data-theme="light"] .progress-checked-wrap{
        border-top-color:#d0d9e1;
    }

    html[data-theme="light"] .progress-checked-item{
        background:#f3f6f8;
        border-color:#c8d2dc;
        color:#52606d;
    }

    html[data-theme="light"] .progress-checked-item.current{
        background:#e2f5eb;
        border-color:#78b899;
        color:#28714e;
    }

</style>
<style>

    /* v21.28: checked database chips are navigation buttons */
    button.progress-checked-item{
        appearance:none;
        font-family:inherit;
        cursor:pointer;
        outline:none;
    }

    button.progress-checked-item:hover{
        border-color:#4d98c8;
        background:#182b39;
        color:#8fd1ff;
        transform:translateY(-1px);
    }

    button.progress-checked-item:focus-visible{
        box-shadow:0 0 0 2px rgba(91,174,229,.35);
    }

    html[data-theme="light"] button.progress-checked-item:hover{
        background:#e6f3fb;
        border-color:#62a6d2;
        color:#236c9b;
    }

</style>
<style>

    .retention-clean-button{
        min-height:30px;
        padding:6px 10px;
        border:1px solid #a97827;
        border-radius:6px;
        background:#352811;
        color:#f4c96a;
        cursor:pointer;
        font-size:10px;
        font-weight:600;
    }
    .retention-clean-button:hover:not(:disabled){
        background:#493617;
    }
    .retention-clean-button:disabled{
        opacity:.45;
        cursor:not-allowed;
    }

</style>
<style>

    /* v21.31: completed result is visually static, not an active check */
    #progressPanel.finished .progress-bar{
        transition:none!important;
        background:#42b883!important;
    }

    #progressPanel.finished{
        box-shadow:none;
    }

    .progress-checked-item.status-ok{
        border-color:#27784f;
        background:#113525;
        color:#64d99c;
    }

    .progress-checked-item.status-waiting{
        border-color:#9b6f19;
        background:#392b0e;
        color:#f0c75c;
    }

    .progress-checked-item.status-warning{
        border-color:#a86224;
        background:#3a2110;
        color:#f3a85e;
    }

    .progress-checked-item.status-error{
        border-color:#a9424a;
        background:#40191e;
        color:#ff8992;
    }

    .progress-checked-item.status-maintenance{
        border-color:#3e6f96;
        background:#152b3c;
        color:#82b9e0;
    }

    .progress-checked-item.status-neutral{
        border-color:#35424e;
        background:#121920;
        color:#aebbc7;
    }

    /* Current means last checked, but status color remains dominant. */
    .progress-checked-item.current{
        box-shadow:0 0 0 1px rgba(255,255,255,.10);
    }

    html[data-theme="light"] .progress-checked-item.status-ok{
        background:#e4f6ec;
        border-color:#72b991;
        color:#28724f;
    }
    html[data-theme="light"] .progress-checked-item.status-waiting{
        background:#fff5d9;
        border-color:#d5aa43;
        color:#86620e;
    }
    html[data-theme="light"] .progress-checked-item.status-warning{
        background:#fff0df;
        border-color:#dc9a58;
        color:#95591e;
    }
    html[data-theme="light"] .progress-checked-item.status-error{
        background:#ffe7e9;
        border-color:#da7d85;
        color:#9d343d;
    }

</style>
<style>

    /* v21.32: real per-database upload bytes */
    .db-upload-progress{
        margin-top:7px;
        max-width:430px;
        padding:7px 8px;
        border:1px solid #315f7d;
        border-radius:6px;
        background:#101b23;
    }
    .db-upload-progress[hidden]{display:none!important}
    .db-upload-progress-head{
        display:flex;
        justify-content:space-between;
        gap:8px;
        margin-bottom:5px;
        font-size:9px;
        color:#9dc8e5;
    }
    .db-upload-progress-percent{
        font-weight:700;
        color:#76c9ff;
    }
    .db-upload-progress-track{
        height:6px;
        overflow:hidden;
        border-radius:999px;
        background:#26323c;
    }
    .db-upload-progress-fill{
        width:0;
        height:100%;
        border-radius:inherit;
        background:linear-gradient(90deg,#3d8fc3,#62c2ff);
        transition:width .3s linear;
    }
    .db-upload-progress-meta{
        margin-top:5px;
        color:#8ea4b4;
        font-size:9px;
        white-space:normal;
    }
    .db-upload-progress.error{
        border-color:#9b3d48;
        background:#291519;
    }
    .db-upload-progress.error .db-upload-progress-fill{
        background:#d95c67;
    }
    .db-upload-progress.error .db-upload-progress-percent{
        color:#ff8d96;
    }

</style>

<style>
/* v21.36: byte-level Manual Upload progress disabled.
   Stable AWS CLI upload is used instead. */
.manual-upload-progress,
.upload-progress,
.upload-progress-bar,
.upload-byte-progress,
[data-manual-upload-progress] {
    display:none !important;
}
</style>

<style>
    .s3-status-wrap{position:relative}
    .s3-status-button{
        min-height:32px;
        padding:6px 11px;
        border:1px solid #425365;
        border-radius:7px;
        background:#172331;
        color:#cfe9ff;
        font:inherit;
        font-size:12px;
        font-weight:600;
        cursor:pointer;
        white-space:nowrap;
    }
    .s3-status-button:hover{background:#203247;border-color:#5b7691}
    .s3-status-button.s3-ok{border-color:#23794f;background:#123224;color:#70e4a7}
    .s3-status-button.s3-warn{border-color:#9a7420;background:#34280e;color:#ffd568}
    .s3-status-button.s3-error{border-color:#9b3d48;background:#32171b;color:#ff9aa2}
    .s3-status-popover{
        position:absolute;
        z-index:10050;
        top:calc(100% + 8px);
        right:0;
        width:min(520px,80vw);
        padding:12px;
        border:1px solid #394754;
        border-radius:9px;
        background:#171d24;
        box-shadow:0 18px 50px rgba(0,0,0,.45);
    }
    .s3-status-popover[hidden]{display:none}
    .s3-status-head{
        display:flex;align-items:center;justify-content:space-between;gap:12px;
        margin-bottom:9px;
    }
    .s3-status-head strong{font-size:13px}
    .s3-status-refresh{
        padding:5px 9px;border:1px solid #3f607b;border-radius:6px;
        background:#14314a;color:#dcefff;cursor:pointer;font-size:11px;
    }
    .s3-status-endpoint{font-size:10px;color:#90a7bb;margin-bottom:8px;word-break:break-all}
    .s3-connection-row{
        display:grid;
        grid-template-columns:minmax(70px,1fr) minmax(75px,1fr) auto;
        gap:9px;
        align-items:center;
        padding:8px 0;
        border-top:1px solid #2b343e;
        font-size:11px;
    }
    .s3-connection-row:first-child{border-top:0}
    .s3-connection-bucket{font-weight:700;color:#e8f2fb}
    .s3-connection-profile{color:#9fb0bf}
    .s3-connection-state{font-weight:700}
    .s3-connection-state.ok{color:#62d993}
    .s3-connection-state.error{color:#ff7f89}
    .s3-connection-error{
        grid-column:1/-1;
        font-size:10px;
        color:#e8a4a9;
        white-space:normal;
        word-break:break-word;
    }
    html[data-theme="light"] .s3-status-popover{background:#fff;border-color:#cad5df;color:#1f2933}
    html[data-theme="light"] .s3-connection-bucket{color:#1f2933}
</style>

</head>
<body>
<div id="serverRestartOverlay" class="server-restart-overlay" hidden>
    <div class="server-restart-card">
        <div class="restart-spinner"></div>
        <strong>Перезапускаю Dashboard</strong>
        <span id="serverRestartMessage">Останавливаю web-сервер...</span>
    </div>
</div>
<div class="page">
    <header>
        <div>
            <div class="title-row">
                <div id="dashboardBrand" class="dashboard-brand" role="button" tabindex="0" aria-label="BackupS3 Dashboard. Показать или скрыть служебную панель" title="Показать или скрыть Диагностику и обновление Dashboard">
                    <div class="dashboard-brand-symbol" aria-hidden="true"><img src="BackupS3-Login.png" alt=""></div>
                    <div class="dashboard-brand-title"><h1>Backup<strong>S3</strong></h1><em>Dashboard</em></div>
                </div>
                <button id="restartDashboardButton" type="button" class="restart-dashboard-button" title="Полностью перезапустить Dashboard Server">Перезапустить</button>
            </div>
            <p>Host: <strong>$(ConvertTo-HtmlSafe $state.Host)</strong> · Обновлено: <strong id="generatedAt">$(ConvertTo-HtmlSafe $generated)</strong></p>
        </div>
        <div class="header-actions">
            <div class="s3-status-wrap">
                <button id="s3StatusButton" type="button" class="s3-status-button" title="Проверить доступные S3 подключения">S3 · проверка…</button>
                <div id="s3StatusPopover" class="s3-status-popover" hidden>
                    <div class="s3-status-head">
                        <strong>S3 подключения</strong>
                        <button id="s3StatusRefresh" class="s3-status-refresh" type="button">Проверить снова</button>
                    </div>
                    <div id="s3StatusEndpoint" class="s3-status-endpoint"></div>
                    <div id="s3StatusList">Проверяю подключения…</div>
                </div>
            </div>
            <button id="logButton" type="button" class="log-button header-log-button" title="Живой лог BackupS3">Log</button>
            <button id="reportButton" type="button" class="settings-button" title="Сформировать отчёт">Отчёт</button>
            <button id="profilesButton" type="button" class="settings-button" title="Профили баз и подключения S3">Профили и S3</button>
            <button id="settingsButton" type="button" class="settings-button" title="Настройки">⚙ Настройки</button>
            <button id="themeToggle" type="button" class="theme-toggle" title="Переключить тему">
                <span class="theme-icon" aria-hidden="true">☀</span>
                <span id="themeLabel">Светлая</span>
            </button>
            <div class="endpoint">$(ConvertTo-HtmlSafe $state.Endpoint)</div>
        </div>
    </header>

    <div id="modeBanner" class="mode-banner">
        <strong id="modeTitle">Безопасный режим</strong>
        <span id="modeText">Загрузка, удаление и Graylog отключены.</span>
    </div>

    <section class="cards">
        <div class="card"><span>Баз</span><strong>$total</strong></div>
        <div class="card ok-card"><span>В норме</span><strong>$ok</strong></div>
        <div class="card waiting-card"><span>Ожидание</span><strong>$waiting</strong></div>
        <div class="card stale-card"><span>Устарело</span><strong>$stale</strong></div>
        <div class="card error-card"><span>Ошибки</span><strong>$errors</strong></div>
        <div class="card"><span>Локальных копий</span><strong>$localFiles</strong><small>$(ConvertTo-HtmlSafe (Format-Bytes $localBytes))</small></div>
        <div class="card"><span>S3 объектов</span><strong id="dashboardS3ObjectCount">$s3Objects</strong><small id="dashboardS3Bytes">$(ConvertTo-HtmlSafe (Format-Bytes $s3Bytes))</small></div>
    </section>

    <section class="toolbar">
        <input id="search" type="search" placeholder="Поиск: база, файл, bucket...">
        <select id="statusFilter">
            <option value="">Все статусы</option>
            <option value="OK">В норме</option>
            <option value="UPLOADED">Загружено</option>
            <option value="READY">Готово</option>
            <option value="WAITING">Ожидание</option>
            <option value="STALE">Устарело</option>
            <option value="ERROR">Ошибка</option>
        </select>
        <select id="favoriteFilter">
            <option value="">Все базы</option>
            <option value="pinned">★ Закреплённые</option>
            <option value="critical">Критические</option>
        </select>
        <select id="sortMode" title="Сортировка баз">
            <option value="priority">Приоритет</option>
            <option value="name">По имени</option>
            <option value="age-desc">Возраст: сначала старые</option>
            <option value="age-asc">Возраст: сначала новые</option>
            <option value="size-desc">Размер: сначала большие</option>
            <option value="size-asc">Размер: сначала маленькие</option>
        </select>
        <button id="refreshButton" type="button">Проверить сейчас</button>
        <button id="selectAllJobsButton" type="button">Выбрать все</button>
        <button id="checkSelectedButton" type="button" class="selected-check-button" hidden>Проверить выбранные (0)</button>
        <button id="deleteSelectedButton" type="button" class="danger-button" hidden>Удалить выбранные (0)</button>
        <button id="addJobButton" type="button" class="primary-button">Добавить базу</button>
    </section>


    <section id="favoritesSection" class="favorites-section">
        <div class="favorites-head">
            <div>
                <h3>★ Важные базы</h3>
                <p>Перетащите сюда строку базы, чтобы закрепить её.</p>
            </div>
        </div>
        <div id="favoritesGrid" class="favorites-grid">
        $(
            $fav=@($displayJobs|Where-Object{$_.Ui.Pinned -or $_.Ui.Priority -eq "Critical"})
            if($fav.Count -eq 0){
                "<div class='favorites-empty'><strong>Перетащите базу сюда</strong><span>Или включите «Закрепить» в окне редактирования.</span></div>"
            }else{
                (@($fav|ForEach-Object{
                    $j=$_.Job;$u=$_.Ui
                    $name=if([string]::IsNullOrWhiteSpace([string]$u.Alias)){$j.Name}else{$u.Alias}
                    $unpinButton=if($u.Pinned){
                        "<button class='unpin-job' type='button' data-job='$(ConvertTo-HtmlSafe $j.Name)' title='Открепить базу' aria-label='Открепить базу'>×</button>"
                    }else{""}
                    "<div class='favorite-card accent-$($u.Accent)' data-db='$([System.Net.WebUtility]::HtmlEncode($j.Name))'>
                        <div class='favorite-title'><span><i aria-hidden='true'>★</i>$(ConvertTo-HtmlSafe $name)</span><div class='favorite-actions'>$unpinButton<button class='edit-job favorite-edit-button' type='button' data-job='$(ConvertTo-HtmlSafe $j.Name)' title='Редактировать базу' aria-label='Редактировать базу'>✎</button></div></div>
                        <div class='favorite-sub'>$(ConvertTo-HtmlSafe $j.Name)</div>
                        <div class='favorite-status'><span class='status'>$(ConvertTo-HtmlSafe (Get-StatusLabel $j.Status))</span><strong>$($j.HealthScore)%</strong></div>
                        <div class='favorite-health'><span style='width:$([Math]::Max(0,[Math]::Min(100,[int]$j.HealthScore)))%'></span></div>
                        <div class='favorite-sync'><span>$(ConvertTo-HtmlSafe (Get-SyncStatusLabel $j.SyncStatus))</span><span>$(ConvertTo-HtmlSafe (Format-Bytes ([Int64]$j.LocalSizeBytes)))</span></div>
                    </div>"
                }) -join "")
            }
        )
        </div>
    </section>

    <section id="progressPanel" class="progress-panel">
        <div class="progress-head">
            <div>
                <span id="progressTitle">Готов к проверке</span>
                <span id="progressDatabase" class="progress-db"></span>
            </div>
            <strong id="progressPercent">0%</strong>
        </div>
        <div class="progress-track">
            <div id="progressBar" class="progress-bar" style="width:0%"></div>
        </div>
        <div class="progress-foot">
            <span id="progressMessage">Нажмите «Проверить сейчас»</span>
            <span class="progress-right">
                <span id="progressStall" class="progress-stall" hidden></span>
                <button id="cancelCheckButton" type="button" class="cancel-check-button" hidden>Остановить</button>
                <span id="progressCounter">0 / 0</span>
            </span>
        </div>

        <div id="progressCheckedWrap" class="progress-checked-wrap" hidden>
            <span class="progress-checked-label">Проверено:</span>
            <div id="progressChecked" class="progress-checked"></div>
        </div>
    </section>



    <div id="logModal" class="modal-backdrop" hidden>
        <div class="modal-card log-modal-card">
            <div class="modal-head">
                <div>
                    <h2>Живой лог BackupS3</h2>
                    <p id="logMeta">Чтение controller log...</p>
                </div>
                <button id="closeLogModal" class="icon-button" type="button">×</button>
            </div>

            <div class="log-toolbar">
                <select id="logSource">
                    <option value="controller">BackupS3</option>
                    <option value="server">Приложение / WebView2</option>
                    <option value="audit">Действия</option>
                </select>
                <select id="logLevel">
                    <option value="">Все уровни</option>
                    <option value="INFO">INFO</option>
                    <option value="WARN">WARN</option>
                    <option value="ERROR">ERROR</option>
                </select>

                <input id="logDatabase" placeholder="База, например rmTrade11">
                <input id="logSearch" placeholder="Поиск по логу...">

                <select id="logLines">
                    <option value="100">100 строк</option>
                    <option value="250" selected>250 строк</option>
                    <option value="500">500 строк</option>
                    <option value="1000">1000 строк</option>
                </select>

                <label class="log-follow">
                    <input id="logFollow" type="checkbox" checked>
                    <span>Автопрокрутка</span>
                </label>

                <button id="logPause" type="button" class="action-btn action-btn-neutral">Пауза</button>
                <button id="logRefresh" type="button" class="action-btn action-btn-primary">Обновить</button>
            </div>

            <div id="logStatus" class="log-status"></div>
            <pre id="logOutput" class="log-output"></pre>

            <div class="modal-actions">
                <button id="closeLogBottom" type="button" class="action-btn action-btn-neutral">Закрыть</button>
            </div>
        </div>
    </div>

    <div id="jobModal" class="modal-backdrop" hidden>
        <div class="modal-card" role="dialog" aria-modal="true" aria-labelledby="jobModalTitle">
            <div class="modal-head">
                <div>
                    <h2 id="jobModalTitle">Добавить базу</h2>
                    <p>Укажи локальную папку и параметры S3.</p>
                </div>
                <button id="closeJobModal" class="icon-button" type="button" aria-label="Закрыть">×</button>
            </div>

            <div id="serverVersionWarning" class="server-version-warning" hidden></div>
            <form id="addJobForm">
                <div class="form-grid">
                    <label>
                        <span>Имя базы <i class="field-help" data-help="Название базы в BackupS3 Manager.">?</i></span>
                        <input id="jobName" required placeholder="Например: NewBase">
                    </label>

                    <label class="wide">
                        <span>Локальная папка <i class="field-help" data-help="Место, где хранится резервная копия или файл, который нужно загрузить на S3.">?</i></span>
                        <div class="path-picker">
                            <input id="jobLocalPath" required placeholder="K:\MSSQL\BACKUPS\NewBase">
                            <button id="browseFolderButton" type="button" class="browse-button">Обзор...</button>
                        </div>
                        <small class="field-hint">Нажми «Обзор...», чтобы выбрать папку через Проводник Windows.</small>
                    </label>

                    <label>
                        <span>S3-бакет <i class="field-help" data-help="Имя хранилища S3, в которое отправляются файлы этой базы.">?</i></span>
                        <select id="jobBucket" required>
                            <option value="pw1" selected>pw1</option>
                            <option value="kom1">kom1</option>
                        </select>
                    </label>

                    <label class="s3-folder-field">
                        <span>Папка S3 <i class="field-help" data-help="Каталог внутри выбранного S3-бакета.">?</i></span>
                        <div class="s3-folder-picker">
                            <input id="jobS3Path" value="ANI" autocomplete="off">
                            <button id="loadS3FoldersButton" type="button" class="folder-list-button" title="Показать папки S3">⌄</button>
                            <div id="s3FolderMenu" class="s3-folder-menu" hidden>
                                <div class="s3-folder-menu-title">Папки в bucket</div>
                                <div id="s3FolderOptions"></div>
                                <div class="s3-folder-new">Можно выбрать существующую папку или ввести новое имя.</div>
                            </div>
                        </div>
                    </label>

                    <label class="wide">
                        <span>Префикс файлов <i class="field-help" data-help="Начало имени резервных копий. Только подходящие файлы участвуют в проверке и загрузке.">?</i></span>
                        <input id="jobFilePrefix" required placeholder="NewBase_backup_">
                    </label>

                    <label>
                        <span>Профиль AWS <i class="field-help" data-help="Профиль с ключами доступа S3. Пустое значение использует стандартный профиль AWS.">?</i></span>
                        <input id="jobAwsProfile" placeholder="пусто = стандартный">
                    </label>

                    <label>
                        <span>Хранить файлов на S3 <i class="field-help" data-help="Сколько самых новых файлов оставить на S3. При включённой автоочистке более старые удаляются.">?</i></span>
                        <input id="jobKeep" type="number" min="1" value="2">
                    </label>

                    <label>
                        <span>Макс. возраст, часов <i class="field-help" data-help="Если последняя локальная копия старше этого значения, база получает предупреждение.">?</i></span>
                        <input id="jobMaxAge" type="number" min="1" value="26">
                    </label>

                    <label><span>Время загрузки на S3 <i class="field-help" data-help="Время, после которого автоматический запуск может отправить новую копию на S3.">?</i></span><input id="jobExpectedTime" type="time" value="01:00"></label>
                    <label><span>Дни загрузки <i class="field-help" data-help="Дни, в которые разрешена автоматическая отправка на S3.">?</i></span><select id="jobExpectedDays"><option value="Daily">Каждый день</option><option value="Weekdays">Понедельник–пятница</option><option value="Weekends">Суббота–воскресенье</option><option value="Monday">Понедельник</option><option value="Tuesday">Вторник</option><option value="Wednesday">Среда</option><option value="Thursday">Четверг</option><option value="Friday">Пятница</option><option value="Saturday">Суббота</option><option value="Sunday">Воскресенье</option></select></label>
                    <label><span>Окно загрузки, минут <i class="field-help" data-help="Сколько минут после заданного времени разрешена автоматическая загрузка. Значение должно быть не меньше интервала автопроверки.">?</i></span><input id="jobGraceMinutes" type="number" min="1" max="1440" value="180"></label>
                    <label><span>Аномалия размера, % <i class="field-help" data-help="Допустимое отличие размера новой копии от обычного размера. Превышение создаёт предупреждение.">?</i></span><input id="jobSizeAnomaly" type="number" min="5" max="500" value="35"></label>
                </div>

                <div id="jobFormError" class="form-error"></div>

                <div class="modal-actions edit-modal-actions">
                    <button id="cancelJobModal" type="button" class="action-btn action-btn-neutral">Отмена</button>
                    <button id="submitAddJob" type="submit" class="action-btn action-btn-primary">Добавить</button>
                </div>
            </form>
        </div>
    </div>


    <section class="ops-grid">
        <div class="ops-card">
            <h3>Проблемы сейчас</h3>
            <div class="ops-list">
            $(
                if($problems -eq 0){"<div class='good-line'>Проблем нет</div>"}
                else {
                    (@($jobs|Where-Object{$_.Status -in @("ERROR","STALE","WARNING")}|ForEach-Object{
                        "<div><strong>$(ConvertTo-HtmlSafe $_.Name)</strong> — $(ConvertTo-HtmlSafe $_.StatusText)</div>"
                    }) -join "")
                }
            )
            </div>

            <div class="scheduler-status-box">
                <div class="scheduler-status-head">
                    <span>Автоматическая проверка</span>
                    <button id="schedulerCheckNow" type="button" class="scheduler-now-button">Обновить сейчас</button>
                </div>

                <div class="scheduler-status-line">
                    <span>Состояние</span>
                    <strong id="schedulerState">Загрузка...</strong>
                </div>

                <div class="scheduler-status-line">
                    <span>Следующая проверка</span>
                    <strong id="schedulerNextCheck">—</strong>
                </div>

                <div class="scheduler-status-line">
                    <span>До проверки</span>
                    <strong id="schedulerCountdown">--:--</strong>
                </div>
            </div>
        </div>
        <div class="ops-card">
            <h3>Последние 24 часа</h3>
            <div class="metric-line"><span>Загрузок</span><strong>$($todayUploads.Count)</strong></div>
            <div class="metric-line"><span>Передано</span><strong>$(ConvertTo-HtmlSafe (Format-Bytes $todayBytes))</strong></div>
            <div class="metric-line"><span>Исправны</span><strong>$healthy / $total</strong></div>
        </div>
        <div class="ops-card">
            <h3>Самые большие резервные копии</h3>
            $(
                (@($jobs|Sort-Object LocalSizeBytes -Descending|Select-Object -First 5|ForEach-Object{
                    "<div class='metric-line'><span>$(ConvertTo-HtmlSafe $_.Name)</span><strong>$(ConvertTo-HtmlSafe (Format-Bytes ([Int64]$_.LocalSizeBytes)))</strong></div>"
                }) -join "")
            )
        </div>
        <div class="ops-card">
            <h3>Недавние события</h3>
            <div class="events-list">
            $(
                (@($history|Sort-Object {[datetime]$_.timestamp} -Descending|Select-Object -First 8|ForEach-Object{
                    $hint=Get-RecentEventHint -EventItem $_ -AllHistory $history -AllJobs $jobs
                    "<div class='recent-event' data-tooltip='$(ConvertTo-HtmlSafe $hint)'>
                        <span class='event-time'>$(ConvertTo-HtmlSafe (([datetime]$_.timestamp).ToString('dd.MM HH:mm')))</span>
                        <button type='button' class='event-db-link' data-db='$(ConvertTo-HtmlSafe $_.database)' title='Перейти к базе $(ConvertTo-HtmlSafe $_.database)'>$(ConvertTo-HtmlSafe $_.database)</button>
                        <span> — $(ConvertTo-HtmlSafe (Convert-EventToRussian -Event ([string]$_.event) -Message ([string]$_.message)))</span>
                    </div>"
                }) -join "")
            )
            </div>
        </div>
    </section>




    <div id="recentEventTooltip" role="tooltip"></div>
    <div id="dbHoverTooltip" class="db-hover-tooltip" role="tooltip"></div>
    <div id="fieldHelpTooltip" class="field-help-tooltip" role="tooltip" hidden></div>

    <div id="editJobModal" class="modal-backdrop" hidden>
        <div class="modal-card edit-job-card">
            <div class="modal-head">
                <div>
                    <h2>Редактирование базы: <span id="editJobTitle"></span></h2>
                    <p>Пути, расписание загрузки и политика хранения S3.</p>
                </div>
                <button id="closeEditJobModal" class="icon-button" type="button">×</button>
            </div>

            <form id="editJobForm">
                <input id="editJobName" type="hidden">

                <div class="edit-info-strip">
                    <div><span>Последняя локальная копия</span><strong id="editLocalFile">-</strong></div>
                    <div><span>Последний объект S3</span><strong id="editS3Latest">-</strong></div>
                    <div><span>Синхронизация</span><strong id="editSyncStatus">-</strong></div>
                    <div><span>Последняя проверка</span><strong id="editLastChecked">-</strong></div>
                </div>

                <div class="form-grid">
                    <label class="wide">
                        <span>Локальная папка <i class="field-help" data-help="Место, где хранится резервная копия или файл, который нужно загрузить на S3.">?</i></span>
                        <div class="path-picker">
                            <input id="editLocalPath" required>
                            <button id="editBrowseFolder" type="button" class="browse-button">Обзор...</button>
                        </div>
                    </label>

                    <label>
                        <span>S3-бакет <i class="field-help" data-help="Имя хранилища S3 для этой базы.">?</i></span>
                        <select id="editBucket">
                            <option value="pw1">pw1</option>
                            <option value="kom1">kom1</option>
                        </select>
                    </label>

                    <label>
                        <span>Папка S3 <i class="field-help" data-help="Каталог внутри выбранного S3-бакета.">?</i></span>
                        <input id="editS3Path">
                    </label>

                    <label class="wide">
                        <span>Префикс файлов <i class="field-help" data-help="Начало имени файлов, относящихся к этой базе.">?</i></span>
                        <input id="editFilePrefix" required>
                    </label>

                    <label>
                        <span>Профиль AWS <i class="field-help" data-help="Профиль с ключами доступа. Пустое значение использует стандартный профиль AWS.">?</i></span>
                        <input id="editAwsProfile" placeholder="пусто = стандартный">
                    </label>

                    <label>
                        <span>Хранить файлов на S3 <i class="field-help" data-help="После успешной загрузки сохраняются самые новые файлы в указанном количестве. Лишние старые файлы удаляются, если автоочистка разрешена.">?</i></span>
                        <input id="editKeep" type="number" min="1" max="100">
                    </label>

                    <label>
                        <span>Время загрузки на S3 <i class="field-help" data-help="В это время автоматический запуск получает разрешение загрузить новую локальную копию.">?</i></span>
                        <input id="editExpectedTime" type="time">
                    </label>

                    <label>
                        <span>Дни загрузки <i class="field-help" data-help="Дни, в которые разрешена автоматическая загрузка на S3.">?</i></span>
                        <select id="editExpectedDays">
                            <option value="Daily">Каждый день</option>
                            <option value="Weekdays">Понедельник–пятница</option>
                            <option value="Weekends">Суббота–воскресенье</option>
                            <option value="Monday">Понедельник</option><option value="Tuesday">Вторник</option><option value="Wednesday">Среда</option><option value="Thursday">Четверг</option><option value="Friday">Пятница</option><option value="Saturday">Суббота</option><option value="Sunday">Воскресенье</option>
                        </select>
                    </label>

                    <label>
                        <span>Окно загрузки, минут <i class="field-help" data-help="Сколько минут после заданного времени автоматическая загрузка ещё разрешена. Установите не меньше интервала автопроверки.">?</i></span>
                        <input id="editGraceMinutes" type="number" min="1" max="1440">
                    </label>

                    <label>
                        <span>Макс. возраст, часов <i class="field-help" data-help="Максимально допустимый возраст последней локальной копии. Более старый файл считается устаревшим.">?</i></span>
                        <input id="editMaxAgeHours" type="number" min="1" max="240">
                    </label>

                    <label>
                        <span>Аномалия размера, % <i class="field-help" data-help="Допустимое отклонение размера новой копии от медианного размера предыдущих файлов.">?</i></span>
                        <input id="editSizeAnomaly" type="number" min="5" max="500">
                    </label>

                    <label class="enabled-row">
                        <span>Мониторинг включён</span>
                        <input id="editEnabled" type="checkbox">
                    </label>
                </div>


                <section class="customization-section collapsible-section" data-section="customization">
                    <button type="button" class="section-toggle" aria-expanded="true">
                        <span>Отображение и приоритет</span>
                        <span class="section-chevron">⌃</span>
                    </button>
                    <div class="section-content">
                    <div class="form-grid">
                        <label>
                            <span>Отображаемое имя</span>
                            <input id="editAlias" placeholder="Например: UTRADE — ОСНОВНАЯ">
                        </label>
                        <label>
                            <span>Группа</span>
                            <input id="editGroup" placeholder="Критические / Бухгалтерия / Тестовые">
                        </label>
                        <label>
                            <span>Приоритет</span>
                            <select id="editPriority">
                                <option value="Critical">Критический</option>
                                <option value="High">Высокий</option>
                                <option value="Normal">Обычный</option>
                                <option value="Low">Низкий</option>
                            </select>
                        </label>
                        <label class="accent-field">
                            <span>Цветовой акцент</span>
                            <input id="editAccent" type="hidden" value="default">
                            <div id="accentPalette" class="accent-palette" role="radiogroup" aria-label="Цветовой акцент">
                                <button type="button" class="accent-swatch swatch-default selected" data-accent="default" title="Стандартный" aria-label="Стандартный"></button>
                                <button type="button" class="accent-swatch swatch-red" data-accent="red" title="Красный" aria-label="Красный"></button>
                                <button type="button" class="accent-swatch swatch-orange" data-accent="orange" title="Оранжевый" aria-label="Оранжевый"></button>
                                <button type="button" class="accent-swatch swatch-yellow" data-accent="yellow" title="Жёлтый" aria-label="Жёлтый"></button>
                                <button type="button" class="accent-swatch swatch-green" data-accent="green" title="Зелёный" aria-label="Зелёный"></button>
                                <button type="button" class="accent-swatch swatch-blue" data-accent="blue" title="Синий" aria-label="Синий"></button>
                                <button type="button" class="accent-swatch swatch-purple" data-accent="purple" title="Фиолетовый" aria-label="Фиолетовый"></button>
                            </div>
                        </label>
                        <label class="pin-option">
                            <span>★ Закрепить базу вверху</span>
                            <input id="editPinned" type="checkbox">
                        </label>
                        <label class="wide">
                            <span>Комментарий администратора</span>
                            <input id="editNote" placeholder="Главная рабочая база, не удалять вручную...">
                        </label>
                    </div>
                                    </div>
</section>


                <section class="edit-local-section collapsible-section" data-section="localfiles">
                    <button type="button" class="section-toggle" aria-expanded="true">
                        <span>Локальные файлы</span>
                        <span class="section-chevron">⌃</span>
                    </button>
                    <div class="section-content">
                        <div class="edit-local-head">
                            <div>
                                <p>Файлы из локальной папки базы. Отсюда можно вручную отправить выбранную резервную копию на S3.</p>
                            </div>
                            <div class="edit-local-controls">
                                <span id="editLocalCount">0 файл(ов)</span>
                                <button id="editRefreshLocal" type="button" class="s3-refresh-button">Проверить локально</button>
                            </div>
                        </div>
                        <div id="editLocalCheckedAt" class="edit-s3-checked muted"></div>
                        <div id="editLocalObjects" class="edit-local-list"></div>
                    </div>
                </section>

                <section class="edit-s3-section collapsible-section" data-section="s3files">
                    <button type="button" class="section-toggle" aria-expanded="true">
                        <span>Файлы на S3</span>
                        <span class="section-chevron">⌃</span>
                    </button>
                    <div class="section-content">
                    <div class="edit-s3-head">
                        <div>
                            <h3 class="visually-hidden">Файлы на S3</h3>
                            <p>Список можно проверить напрямую в S3. Последняя резервная копия защищена от удаления.</p>
                        </div>
                        <div class="edit-s3-controls">
                            <span id="editS3Count">0 объект(ов)</span>
                            <button id="editDeleteExtras" type="button" class="retention-clean-button">Удалить лишние</button>
                            <button id="editRefreshS3" type="button" class="s3-refresh-button">Проверить S3</button>
                        </div>
                    </div>
                    <div id="editS3CheckedAt" class="edit-s3-checked muted"></div>
                    <div id="editS3Objects" class="edit-s3-list"></div>
                                    </div>
</section>

                <div id="editJobError" class="form-error"></div>

                <div class="modal-actions edit-modal-actions">
                    <button id="exportJobPs1" type="button" class="action-btn action-btn-neutral">Экспорт .ps1</button>
                    <span class="modal-actions-spacer"></span>
                    <button id="cancelEditJob" type="button" class="action-btn action-btn-neutral">Отмена</button>
                    <button type="submit" class="action-btn action-btn-primary">Сохранить изменения</button>
                </div>
            </form>
        </div>
    </div>


    <div id="reportModal" class="modal-backdrop" hidden>
        <div class="modal-card report-modal-card">
            <div class="modal-head">
                <div><h2>Отчёт BackupS3</h2><p>Сводка по всем базам и событиям за выбранный период.</p></div>
                <button id="closeReportModal" class="icon-button" type="button">×</button>
            </div>
            <div class="report-grid">
                <label><span>Период</span><input id="reportValue" type="number" min="1" max="365" value="1"></label>
                <label><span>Единица</span><select id="reportUnit"><option value="hours">Часы</option><option value="days" selected>Дни</option></select></label>
                <label><span>Формат</span><select id="reportFormat"><option value="html">HTML</option><option value="csv">CSV</option><option value="json">JSON</option></select></label>
            </div>
            <div class="report-hint">Отчёт включает текущий статус всех баз, количество загрузок и объём переданных данных за период.</div>
            <div class="modal-actions edit-modal-actions">
                <button id="cancelReport" type="button" class="action-btn action-btn-neutral">Отмена</button>
                <button id="downloadReport" type="button" class="action-btn action-btn-primary">Сформировать</button>
            </div>
        </div>
    </div>

    <div id="settingsModal" class="modal-backdrop" hidden>
        <div class="modal-card settings-modal-card">
            <div class="modal-head">
                <div>
                    <h2>Настройки BackupS3</h2>
                    <p>Настройки применяются без редактирования BackupJobs.psd1.</p>
                </div>
                <button id="closeSettingsModal" class="icon-button" type="button">×</button>
            </div>

            <form id="settingsForm">
                <div class="settings-section danger-section">
                    <div class="setting-row main-safe-row">
                        <div>
                            <strong>Безопасный режим</strong>
                            <p>Когда включён, блокирует загрузку, очистку S3 и отправку в Graylog.</p>
                        </div>
                        <label class="switch">
                            <input id="settingSafeMode" type="checkbox">
                            <span class="slider"></span>
                        </label>
                    </div>
                </div>

                <div class="settings-section">
                    <h3>Действия</h3>
                    <div class="setting-row">
                        <div><strong>Загрузка на S3</strong><p>Разрешить отправку новых резервных копий.</p></div>
                        <label class="switch"><input id="settingUpload" type="checkbox"><span class="slider"></span></label>
                    </div>
                    <div class="setting-row">
                        <div><strong>Удалять старые резервные копии автоматически</strong><p>После проверки оставлять на S3 только количество файлов, указанное у базы. Безопасный режим всегда блокирует удаление.</p></div>
                        <label class="switch"><input id="settingCleanup" type="checkbox"><span class="slider"></span></label>
                    </div>
                    <div class="setting-row">
                        <div><strong>Graylog</strong><p>Отправлять ALERT / RECOVERY.</p></div>
                        <label class="switch"><input id="settingGraylog" type="checkbox"><span class="slider"></span></label>
                    </div>
                </div>

                <div class="settings-section">
                    <h3>Автоматическая проверка</h3>

                    <div class="setting-row">
                        <div>
                            <strong>Запустить автоматическую проверку</strong>
                            <p>BackupS3 Manager выполняет полную проверку в фоне, пока приложение запущено.</p>
                        </div>
                        <label class="switch">
                            <input id="settingAutoScheduler" type="checkbox">
                            <span class="slider"></span>
                        </label>
                    </div>

                    <div class="settings-number-grid auto-scheduler-grid">
                        <label>
                            <span>Проверять каждые, минут</span>
                            <input id="settingAutoSchedulerInterval" type="number" min="1" max="60" value="2">
                        </label>
                    </div>

                    <div class="settings-inline-note">
                        Через указанный интервал запускается полная проверка всех баз. Загрузка выполняется только в день и время, заданные у конкретной базы.
                        Для автоматической загрузки: Безопасный режим = выкл. и Загрузка на S3 = вкл.
                    </div>
                </div>

                <div class="settings-section">
                    <h3>Запуск приложения</h3>
                    <div class="setting-row">
                        <div>
                            <strong>Автозапуск в фоновом режиме</strong>
                            <p>Запускать BackupS3 вместе с Windows сразу в системном трее, без открытия главного окна.</p>
                        </div>
                        <label class="switch">
                            <input id="settingAutoStartBackground" type="checkbox">
                            <span class="slider"></span>
                        </label>
                    </div>
                    <div class="settings-inline-note">
                        Значок BS3 в области уведомлений показывает краткую сводку. Двойной щелчок открывает приложение, а пункт «Выход» полностью завершает его работу.
                    </div>
                </div>

                <div class="settings-section">
                    <h3>Обновления BackupS3</h3>
                    <div class="setting-row">
                        <div><strong>Установленная версия</strong><p id="settingsCurrentVersion">Определяю версию…</p></div>
                        <div class="manager-actions">
                            <button id="checkUpdatesButton" type="button">Проверить обновления</button>
                            <button id="downloadUpdateButton" type="button" class="primary-button" hidden>Скачать обновление</button>
                        </div>
                    </div>
                    <label class="accent-field"><span>Канал обновлений GitHub</span><input id="settingUpdateManifestUrl" type="url" placeholder="https://github.com/…/releases/latest/download/manifest.json"></label>
                    <div id="updateCheckStatus" class="settings-inline-note">Адрес будет заполнен после публикации проекта в Replit.</div>
                </div>

                <div class="settings-section">
                    <h3>Проверка и повторные попытки</h3>
                    <div class="settings-number-grid">
                        <label><span>Файл не менялся, мин.</span><input id="settingIdle" type="number" min="1" max="120"></label>
                        <label><span>Попыток загрузки</span><input id="settingRetryCount" type="number" min="1" max="10"></label>
                        <label><span>Задержка повтора, сек.</span><input id="settingRetryDelay" type="number" min="5" max="600"></label>
                        <label><span>История, дней</span><input id="settingHistoryDays" type="number" min="1" max="365"></label>
                        <label><span>Аномалия размера, %</span><input id="settingSizeAnomaly" type="number" min="5" max="500"></label>
                        <label><span>Автообновление, сек.</span><input id="settingAutoRefresh" type="number" min="10" max="3600"></label>
                    </div>
                </div>

                <div id="settingsWarning" class="settings-warning" hidden>
                    <strong>Внимание:</strong> после выключения безопасного режима разрешённые операции смогут изменять S3.
                </div>

                <div id="settingsError" class="form-error"></div>
                <div id="settingsSuccess" class="form-success"></div>

                <div class="modal-actions edit-modal-actions">
                    <button id="cancelSettings" type="button" class="action-btn action-btn-neutral">Отмена</button>
                    <button id="saveSettings" type="submit" class="action-btn action-btn-primary">Сохранить</button>
                </div>
            </form>
        </div>
    </div>

    <div id="retentionModal" class="modal-backdrop" hidden>
        <div class="modal-card">
            <div class="modal-head"><div><h2>Предварительный просмотр очистки</h2><p id="retentionSubtitle"></p></div><button id="closeRetentionModal" class="icon-button" type="button">×</button></div>
            <div id="retentionBody"></div>
            <div class="modal-actions"><button id="cancelRetentionModal" type="button">Закрыть</button><button id="applyRetention" class="danger-button" type="button">Применить удаление</button></div>
        </div>
    </div>

    <div id="profilesModal" class="modal-backdrop" hidden>
        <div class="modal-card profiles-manager-card">
            <div class="modal-head">
                <div><h2>Профили конфигурации и S3</h2><p>Сохраняйте наборы баз и управляйте учётными данными AWS CLI.</p><span id="activeWorkspaceBadge" class="endpoint">Текущая конфигурация: …</span></div>
                <button id="closeProfilesModal" class="icon-button" type="button">×</button>
            </div>
            <div class="profiles-manager-grid">
                <section class="manager-panel">
                    <h3>Профили баз</h3>
                    <p class="muted">Профиль содержит базы, настройки и оформление. S3-пароли в экспорт не входят.</p>
                    <div class="inline-form"><input id="configProfileName" maxlength="80" placeholder="Например: Сервер бухгалтерии"><button id="saveConfigProfile" type="button">Сохранить текущий</button></div>
                    <div id="configProfilesList" class="manager-list"></div>
                    <div class="manager-actions"><label class="file-action">Импорт JSON<input id="importConfigProfile" type="file" accept="application/json,.json" hidden></label></div>
                </section>
                <section class="manager-panel">
                    <h3>S3-профили</h3>
                    <p class="muted">Хранятся в стандартном файле AWS CLI. Секреты скрыты до нажатия «Показать».</p>
                    <div id="s3ProfilesList" class="manager-list"></div>
                    <form id="s3ProfileForm" class="s3-profile-form">
                        <input id="s3ProfileName" required maxlength="80" placeholder="Имя профиля">
                        <input id="s3AccessKey" autocomplete="off" placeholder="Access Key ID">
                        <div class="secret-input"><input id="s3SecretKey" type="password" autocomplete="new-password" placeholder="Secret Access Key"><button class="toggle-secret" type="button" data-target="s3SecretKey">Показать</button></div>
                        <div class="secret-input"><input id="s3SessionToken" type="password" autocomplete="new-password" placeholder="Session Token (необязательно)"><button class="toggle-secret" type="button" data-target="s3SessionToken">Показать</button></div>
                        <input id="s3Region" placeholder="Регион, например ru-1">
                        <input id="s3Endpoint" type="url" placeholder="Endpoint, например https://s3.example.ru">
                        <div class="manager-actions"><button id="clearS3ProfileForm" type="button">Очистить</button><button class="primary-button" type="submit">Сохранить S3-профиль</button></div>
                    </form>
                </section>
            </div>
            <div id="profilesError" class="form-error"></div>
        </div>
    </div>

    <style>
        .startup-workspace-card{max-width:560px;padding:28px;background:#171d25;border:1px solid #344353;border-radius:16px;box-shadow:0 24px 70px rgba(0,0,0,.58);text-align:center}
        .startup-workspace-brand{width:82px;height:82px;margin:0 auto 10px;overflow:hidden;border-radius:20px;box-shadow:0 0 24px rgba(58,174,255,.24)}
        .startup-workspace-brand img{display:block;width:100%;height:100%;object-fit:cover}
        .startup-workspace-card h2{margin:8px 0;color:#f0f6ff;font-size:27px}.startup-workspace-card>p{margin:0 0 20px;color:#a9b9cb;font-size:15px}
        .workspace-choice{display:flex;align-items:center;gap:14px;margin:10px 0;padding:16px 18px;border:1px solid #344353;border-radius:12px;background:#121920;text-align:left;cursor:pointer;transition:.15s ease}
        .workspace-choice:hover{border-color:#4a7898;background:#152331}.workspace-choice.selected{border-color:#49b9ff;background:#122b3b;box-shadow:inset 3px 0 #49b9ff}
        .workspace-choice strong{display:block;color:#edf5ff;font-size:16px}.workspace-choice small{display:block;margin-top:6px;color:#9fb2c7;line-height:1.4}
        .workspace-choice input{accent-color:#49b9ff;width:18px;height:18px}
        .workspace-auto-enter{display:flex;align-items:flex-start;gap:10px;margin:18px 2px;color:#d8e5f4;text-align:left;cursor:pointer}.workspace-auto-enter input{margin-top:3px;accent-color:#49b9ff}.workspace-auto-enter small{display:block;margin-top:3px;color:#8fa4ba}
        #startupWorkspaceContinue{width:100%;min-height:42px;margin-top:8px;background:#19547a;border-color:#378bc0;color:#fff;font-weight:700}
    </style>
    <div id="startupWorkspaceModal" class="modal-backdrop startup-workspace-modal" hidden>
        <div class="modal-card startup-workspace-card">
            <div class="startup-workspace-brand"><img src="BackupS3-Login.png" alt="BackupS3"></div>
            <h2>Добро пожаловать в BackupS3</h2>
            <p>С какой конфигурацией открыть приложение?</p>
            <label class="workspace-choice selected"><input type="radio" name="startupWorkspace" value="saved" checked><span><strong>Сохранённая конфигурация</strong><small>Открыть текущие базы, настройки и оформление.</small></span></label>
            <label class="workspace-choice"><input type="radio" name="startupWorkspace" value="new"><span><strong>Новая конфигурация</strong><small>Открыть чистое пространство без баз. Сохранённая конфигурация останется доступной.</small></span></label>
            <label class="workspace-auto-enter"><input id="startupWorkspaceAutoEnter" type="checkbox"><span><strong>Входить автоматически</strong><small>При следующих запусках сразу открывать выбранную конфигурацию.</small></span></label>
            <div id="startupWorkspaceError" class="form-error"></div>
            <button id="startupWorkspaceContinue" type="button" class="action-btn action-btn-primary">Продолжить</button>
        </div>
    </div>

    <div id="appDialogBackdrop" class="modal-backdrop app-dialog-backdrop" hidden>
        <div id="appDialogCard" class="modal-card app-dialog-card" data-kind="info" role="dialog" aria-modal="true" aria-labelledby="appDialogTitle" aria-describedby="appDialogMessage">
            <div class="app-dialog-top">
                <div id="appDialogIcon" class="app-dialog-icon" aria-hidden="true">i</div>
                <div class="app-dialog-copy">
                    <h2 id="appDialogTitle" class="app-dialog-title">Сообщение</h2>
                    <p id="appDialogMessage" class="app-dialog-message"></p>
                </div>
            </div>
            <div class="app-dialog-actions">
                <button id="appDialogCancel" type="button" class="modal-btn modal-btn-secondary">Отмена</button>
                <button id="appDialogConfirm" type="button" class="modal-btn modal-btn-primary app-dialog-confirm">OK</button>
            </div>
        </div>
    </div>

    <div id="floatingHeader" class="floating-header" hidden>
        <div id="floatingHeaderInner" class="floating-header-inner"></div>
    </div>

    <section class="table-wrap">
        <table id="jobs">
            <thead>
                <tr>
                    <th>База</th>
                    <th>Статус</th>
                    <th>Комментарий</th>
                    <th>Локальная копия</th>
                    <th>Последний размер</th>
                    <th>Локально</th>
                    <th>Дата изменения</th>
                    <th>Возраст</th>
                    <th>S3</th>
                    <th>Объекты S3</th>
                    <th>Объём S3</th>
                    <th>Последний объект S3</th>
                    <th>Синхронизация</th>
                    <th>Расписание</th>
                    <th>30 дней</th>
                    <th>Проверено</th>
                </tr>
            </thead>
            <tbody>
                $($rows.ToString())
            </tbody>
        </table>
    </section>
    <button id="backToTopButton" class="back-to-top" type="button" title="Наверх" aria-label="Наверх" hidden><span>↑</span><small>Наверх</small></button>
</div>

<script>
(function () {
    const statusLabels={OK:'В норме',UPLOADED:'Загружено',READY:'Готово',WAITING:'Ожидание',STALE:'Устарело',WARNING:'Предупреждение',ERROR:'Ошибка',MAINTENANCE:'Обслуживание'};
    const syncStatusLabels={SYNCED:'Синхронизировано',S3_MISSING:'Нет на S3',UNKNOWN:'Не проверено',NOT_CHECKED:'Ещё не проверено'};
    function statusLabel(value){const key=String(value||'').toUpperCase();return statusLabels[key]||value||'Неизвестно';}
    function syncStatusLabel(value){const key=String(value||'').toUpperCase();return syncStatusLabels[key]||value||'Неизвестно';}
    const appDialogBackdrop=document.getElementById('appDialogBackdrop');
    const appDialogCard=document.getElementById('appDialogCard');
    const appDialogIcon=document.getElementById('appDialogIcon');
    const appDialogTitle=document.getElementById('appDialogTitle');
    const appDialogMessage=document.getElementById('appDialogMessage');
    const appDialogCancel=document.getElementById('appDialogCancel');
    const appDialogConfirm=document.getElementById('appDialogConfirm');
    let appDialogResolve=null;

    function finishAppDialog(result){
        if(appDialogBackdrop.hidden)return;
        appDialogBackdrop.hidden=true;
        document.body.classList.remove('app-dialog-open');
        const resolve=appDialogResolve;
        appDialogResolve=null;
        if(resolve)resolve(result);
    }

    function showAppDialog(options){
        const o=options||{};
        const kind=String(o.kind||'info');
        appDialogCard.dataset.kind=kind;
        appDialogIcon.textContent=kind==='danger'?'!':(kind==='error'?'×':'i');
        appDialogTitle.textContent=String(o.title||'Сообщение');
        appDialogMessage.textContent=String(o.message==null?'':o.message);
        appDialogConfirm.textContent=String(o.confirmText||'OK');
        appDialogCancel.textContent=String(o.cancelText||'Отмена');
        appDialogCancel.hidden=!o.showCancel;
        appDialogBackdrop.hidden=false;
        document.body.classList.add('app-dialog-open');
        setTimeout(()=>appDialogConfirm.focus(),0);
        return new Promise(resolve=>{appDialogResolve=resolve;});
    }

    function appConfirm(message,options){
        const o=Object.assign({title:'Подтверждение',message:message,kind:'info',showCancel:true,confirmText:'Продолжить'},options||{});
        return showAppDialog(o);
    }

    window.alert=function(message){
        return showAppDialog({title:'Сообщение',message:message,kind:'error',showCancel:false,confirmText:'Понятно'});
    };
    appDialogConfirm.addEventListener('click',()=>finishAppDialog(true));
    appDialogCancel.addEventListener('click',()=>finishAppDialog(false));
    document.addEventListener('keydown',e=>{
        if(appDialogBackdrop.hidden)return;
        if(e.key==='Escape'){e.preventDefault();finishAppDialog(false);}
    });

    // v23.14: workspace chooser. It is shown once per application session;
    // internal Dashboard reloads do not ask the same question again.
    const startupWorkspaceModal=document.getElementById('startupWorkspaceModal');
    const startupWorkspaceContinue=document.getElementById('startupWorkspaceContinue');
    const startupWorkspaceError=document.getElementById('startupWorkspaceError');
    const startupWorkspaceAutoEnter=document.getElementById('startupWorkspaceAutoEnter');
    document.querySelectorAll('input[name="startupWorkspace"]').forEach(radio=>radio.addEventListener('change',()=>{
        document.querySelectorAll('.workspace-choice').forEach(x=>x.classList.toggle('selected',x.querySelector('input').checked));
    }));
    async function selectStartupWorkspace(selected,autoEnter){
        startupWorkspaceContinue.disabled=true;startupWorkspaceContinue.textContent='Открываю...';startupWorkspaceError.textContent='';
        try{
            const r=await fetch('/api/startup-workspace/select',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Mode:selected,AutoEnter:!!autoEnter})});
            if(!r.ok){let t=await r.text();try{t=JSON.parse(t).error||t}catch(_){}throw new Error(t);}
            sessionStorage.setItem('backupS3WorkspaceChosen','1');
            location.reload();
        }catch(e){startupWorkspaceError.textContent=e.message;startupWorkspaceContinue.disabled=false;startupWorkspaceContinue.textContent='Продолжить';}
    }
    startupWorkspaceContinue.addEventListener('click',async()=>{
        const selected=document.querySelector('input[name="startupWorkspace"]:checked').value;
        await selectStartupWorkspace(selected,startupWorkspaceAutoEnter.checked);
    });
    if(!sessionStorage.getItem('backupS3WorkspaceChosen')){
        fetch('/api/startup-workspace?t='+Date.now(),{cache:'no-store'}).then(r=>r.json()).then(status=>{
            const mode=status.recommendedMode==='new'?'new':'saved';
            const radio=document.querySelector('input[name="startupWorkspace"][value="'+mode+'"]');
            if(radio)radio.checked=true;
            document.querySelectorAll('.workspace-choice').forEach(x=>x.classList.toggle('selected',x.querySelector('input').checked));
            startupWorkspaceAutoEnter.checked=!!status.autoEnter;
            if(status.autoEnter)selectStartupWorkspace(mode,true);
            else{startupWorkspaceModal.hidden=false;document.body.classList.add('modal-open');}
        }).catch(()=>{startupWorkspaceModal.hidden=false;document.body.classList.add('modal-open');});
    }

    const search = document.getElementById('search');
    const status = document.getElementById('statusFilter');
    const favoriteFilter = document.getElementById('favoriteFilter');
    const sortMode = document.getElementById('sortMode');
    const refreshButton = document.getElementById('refreshButton');
    const refreshStatus = document.getElementById('refreshStatus');
    const rows = Array.from(document.querySelectorAll('#jobs tbody tr'));
    const dashboardBrand=document.getElementById('dashboardBrand');
    function toggleDesktopTools(){
        try{chrome.webview.postMessage({type:'toggle-tools'});}catch(_){}
    }
    dashboardBrand.addEventListener('click',toggleDesktopTools);
    dashboardBrand.addEventListener('keydown',event=>{
        if(event.key==='Enter'||event.key===' '){event.preventDefault();toggleDesktopTools();}
    });
    const favoritesSection = document.getElementById('favoritesSection');
    const favoritesGrid = document.getElementById('favoritesGrid');

    async function setJobPinned(name,pinned){
        const response=await fetch('/api/ui-settings/job',{
            method:'POST',
            headers:{'Content-Type':'application/json'},
            body:JSON.stringify({Name:name,Pinned:!!pinned})
        });
        if(!response.ok){
            let detail=await response.text();
            try{detail=JSON.parse(detail).error||detail}catch(_){}
            throw new Error(detail);
        }
    }

    rows.forEach(row=>{
        row.addEventListener('dragstart',event=>{
            if(event.target.closest('button,input,details,a')){event.preventDefault();return;}
            event.dataTransfer.effectAllowed='copy';
            event.dataTransfer.setData('text/x-backups3-database',row.dataset.db||'');
            row.classList.add('dragging-db-row');
            favoritesSection.classList.add('drag-ready');
        });
        row.addEventListener('dragend',()=>{
            row.classList.remove('dragging-db-row');
            favoritesSection.classList.remove('drag-ready','drag-over');
        });
    });

    favoritesSection.addEventListener('dragover',event=>{
        if(!Array.from(event.dataTransfer.types||[]).includes('text/x-backups3-database'))return;
        event.preventDefault();
        event.dataTransfer.dropEffect='copy';
        favoritesSection.classList.add('drag-over');
    });
    favoritesSection.addEventListener('dragleave',event=>{
        if(!favoritesSection.contains(event.relatedTarget))favoritesSection.classList.remove('drag-over');
    });
    favoritesSection.addEventListener('drop',async event=>{
        event.preventDefault();
        favoritesSection.classList.remove('drag-ready','drag-over');
        const name=event.dataTransfer.getData('text/x-backups3-database');
        if(!name)return;
        try{
            favoritesGrid.innerHTML='<div class="favorites-empty"><strong>Закрепляю '+name+'…</strong></div>';
            await setJobPinned(name,true);
            location.reload();
        }catch(error){alert('Не удалось закрепить базу: '+error.message);}
    });

    document.querySelectorAll('.unpin-job').forEach(button=>{
        button.addEventListener('click',async event=>{
            event.stopPropagation();
            try{button.disabled=true;await setJobPinned(button.dataset.job,false);location.reload();}
            catch(error){button.disabled=false;alert('Не удалось открепить базу: '+error.message);}
        });
    });

    function applyFilter() {
        const q = search.value.toLowerCase().trim();
        const s = status.value;
        const f = favoriteFilter.value;
        rows.forEach(row => {
            const matchText = !q || row.dataset.search.includes(q);
            const matchStatus = !s || row.dataset.status === s;
            const matchFavorite =
                !f ||
                (f === 'pinned' && row.dataset.pinned === '1') ||
                (f === 'critical' && row.dataset.priority === 'Critical');
            row.style.display = (matchText && matchStatus && matchFavorite) ? '' : 'none';
        });
    }

    search.addEventListener('input', applyFilter);
    status.addEventListener('change', applyFilter);
    favoriteFilter.addEventListener('change', applyFilter);


    function closeExpandedObjectLists(){
        document.querySelectorAll('#jobs tbody details[open]').forEach(d=>{
            d.open=false;
        });
    }

    function sortRows(mode){
        const tbody=document.querySelector('#jobs tbody');
        const priorityWeight={Critical:0,High:1,Normal:2,Low:3};

        // Закрываем раскрытые Local/S3 списки перед перестановкой DOM.
        // Это предотвращает визуальное наложение вложенных таблиц при сортировке.
        closeExpandedObjectLists();

        rows.sort((a,b)=>{
            const ap=a.dataset.pinned==='1'?0:1;
            const bp=b.dataset.pinned==='1'?0:1;
            if(ap!==bp)return ap-bp;

            if(mode==='name'){
                return (a.dataset.db||'').localeCompare((b.dataset.db||''),'ru',{sensitivity:'base'});
            }

            if(mode==='priority'){
                const diff=(priorityWeight[a.dataset.priority]??2)-(priorityWeight[b.dataset.priority]??2);
                if(diff!==0)return diff;
                return (a.dataset.db||'').localeCompare((b.dataset.db||''),'ru',{sensitivity:'base'});
            }

            if(mode==='age-desc' || mode==='age-asc'){
                const av=Number(a.dataset.age||0);
                const bv=Number(b.dataset.age||0);
                const diff=mode==='age-desc' ? (bv-av) : (av-bv);
                if(diff!==0)return diff;
            }

            if(mode==='size-desc' || mode==='size-asc'){
                const av=Number(a.dataset.size||0);
                const bv=Number(b.dataset.size||0);
                const diff=mode==='size-desc' ? (bv-av) : (av-bv);
                if(diff!==0)return diff;
            }

            return (a.dataset.db||'').localeCompare((b.dataset.db||''),'ru',{sensitivity:'base'});
        });

        rows.forEach(r=>tbody.appendChild(r));
        applyFilter();

        // После сортировки возвращаем горизонтальный скролл к колонке «База».
        const tableWrap=document.querySelector('.table-wrap');
        if(tableWrap) tableWrap.scrollLeft=0;
    }

    sortMode.addEventListener('change',function(){sortRows(this.value);});


    async function fetchWithTimeout(url,options={},timeoutMs=8000){
        const controller=new AbortController();
        const timer=setTimeout(()=>controller.abort(),timeoutMs);
        try{
            return await fetch(url,{...options,signal:controller.signal});
        }finally{
            clearTimeout(timer);
        }
    }

    // v20: live controller log.
    const logButton=document.getElementById('logButton');
    const logModal=document.getElementById('logModal');
    const logOutput=document.getElementById('logOutput');
    const logMeta=document.getElementById('logMeta');
    const logStatus=document.getElementById('logStatus');
    const logSource=document.getElementById('logSource');
    const logLevel=document.getElementById('logLevel');
    const logDatabase=document.getElementById('logDatabase');
    const logSearch=document.getElementById('logSearch');
    const logLines=document.getElementById('logLines');
    const logFollow=document.getElementById('logFollow');
    const logPause=document.getElementById('logPause');
    const logRefresh=document.getElementById('logRefresh');

    let logTimer=null;
    let logRequestBusy=false;
    let logPaused=false;

    function escapeHtml(value){
        return String(value??'')
            .replace(/&/g,'&amp;')
            .replace(/</g,'&lt;')
            .replace(/>/g,'&gt;');
    }

    function colorizeLogLine(line){
        const safe=escapeHtml(line);
        let cls='log-line-info';
        if(line.includes('[ERROR]')) cls='log-line-error';
        else if(line.includes('[WARN]')) cls='log-line-warn';
        else if(line.includes('UPLOADED') || line.includes('UPLOAD_SUCCESS')) cls='log-line-success';

        return '<span class="'+cls+'">'+safe+'</span>';
    }

    async function loadLiveLog(){
        if(logPaused)return;

        const params=new URLSearchParams({
            lines:logLines.value||'250',
            source:logSource.value||'controller'
        });

        if(logLevel.value)params.set('level',logLevel.value);
        if(logDatabase.value.trim())params.set('database',logDatabase.value.trim());
        if(logSearch.value.trim())params.set('q',logSearch.value.trim());

        try{
            logStatus.textContent='Обновляю...';

            const r=await fetchWithTimeout('/api/log?'+params.toString()+'&t='+Date.now(),{cache:'no-store'},10000);
            if(!r.ok){
                let t=await r.text();
                try{t=JSON.parse(t).error||t}catch(_){}
                throw new Error(t);
            }

            const d=await r.json();
            const lines=Array.isArray(d.lines)?d.lines:(d.lines?[d.lines]:[]);

            logOutput.innerHTML=lines.map(colorizeLogLine).join('\n');

            const lastWrite=d.lastWrite?new Date(d.lastWrite).toLocaleString('ru-RU'):'-';
            const size=(Number(d.sizeBytes||0)/1024/1024).toFixed(2);

            logMeta.textContent=d.exists
                ? d.file+' · '+size+' MB · изменён '+lastWrite
                : 'Файл лога ещё не создан: '+d.file;

            const approxKb=Math.round(Number(d.responseChars||0)/1024);
            logStatus.textContent='Обновлено: '+new Date(d.checkedAt).toLocaleTimeString('ru-RU')+
                ' · строк: '+lines.length+
                ' · ответ: ~'+approxKb+' KB';

            if(logFollow.checked){
                logOutput.scrollTop=logOutput.scrollHeight;
            }
        }
        catch(e){
            logStatus.textContent='Ошибка чтения лога: '+e.message;
        }
    }

    function openLogModal(){
        logModal.hidden=false;
        document.body.classList.add('modal-open');
        logPaused=false;
        logPause.textContent='Пауза';
        loadLiveLog();

        if(logTimer)clearInterval(logTimer);
        logTimer=setInterval(loadLiveLog,2000);
    }

    function closeLogModal(){
        logModal.hidden=true;
        document.body.classList.remove('modal-open');

        if(logTimer){
            clearInterval(logTimer);
            logTimer=null;
        }
    }

    logButton.addEventListener('click',openLogModal);
    document.getElementById('closeLogModal').addEventListener('click',closeLogModal);
    document.getElementById('closeLogBottom').addEventListener('click',closeLogModal);

    logRefresh.addEventListener('click',loadLiveLog);

    logPause.addEventListener('click',function(){
        logPaused=!logPaused;
        logPause.textContent=logPaused?'Продолжить':'Пауза';
        logStatus.textContent=logPaused?'Обновление лога приостановлено':'Live обновление включено';
        if(!logPaused)loadLiveLog();
    });

    logSource.addEventListener('change',()=>{
        if((logSource.value==='server' || logSource.value==='audit') && Number(logLines.value)>100){
            logLines.value='100';
        }
        loadLiveLog();
    });
    [logLevel,logLines].forEach(el=>el.addEventListener('change',loadLiveLog));

    let logFilterDelay=null;
    [logDatabase,logSearch].forEach(el=>{
        el.addEventListener('input',()=>{
            clearTimeout(logFilterDelay);
            logFilterDelay=setTimeout(loadLiveLog,300);
        });
    });



    // v20.3: отдельная плавающая подсказка для «Недавних событий».
    // Она рисуется поверх карточек и не обрезается overflow-контейнерами.
    const recentEventTooltip=document.getElementById('recentEventTooltip');

    function showRecentEventTooltip(eventRow,mouseEvent){
        if(!recentEventTooltip || !eventRow)return;
        const text=eventRow.dataset.tooltip || '';
        if(!text)return;

        recentEventTooltip.textContent=text;
        recentEventTooltip.style.display='block';

        const gap=12;
        const rect=recentEventTooltip.getBoundingClientRect();
        let x=mouseEvent.clientX+gap;
        let y=mouseEvent.clientY+gap;

        if(x+rect.width>window.innerWidth-8){
            x=mouseEvent.clientX-rect.width-gap;
        }
        if(y+rect.height>window.innerHeight-8){
            y=mouseEvent.clientY-rect.height-gap;
        }

        recentEventTooltip.style.left=Math.max(8,x)+'px';
        recentEventTooltip.style.top=Math.max(8,y)+'px';
    }

    document.querySelectorAll('.recent-event').forEach(eventRow=>{
        eventRow.addEventListener('mouseenter',e=>showRecentEventTooltip(eventRow,e));
        eventRow.addEventListener('mousemove',e=>showRecentEventTooltip(eventRow,e));
        eventRow.addEventListener('mouseleave',()=>{
            if(recentEventTooltip)recentEventTooltip.style.display='none';
        });
    });

    // v20.2: переход из «Недавних событий» к строке базы.
    function focusDatabaseRow(databaseName){
        const target=Array.from(document.querySelectorAll('#jobs tbody tr[data-db]'))
            .find(row=>row.dataset.db===databaseName);

        if(!target)return;

        // Если база была скрыта фильтрами — показываем её.
        const searchInput=document.getElementById('search');
        const statusSelect=document.getElementById('statusFilter');
        const favoriteSelect=document.getElementById('favoriteFilter');

        if(searchInput)searchInput.value='';
        if(statusSelect)statusSelect.value='';
        if(favoriteSelect)favoriteSelect.value='';

        if(typeof applyFilter==='function')applyFilter();

        document.querySelectorAll('#jobs tbody tr.event-row-highlight')
            .forEach(row=>row.classList.remove('event-row-highlight'));

        target.classList.add('event-row-highlight');

        // При вертикальном скролле строка окажется примерно в центре экрана.
        target.scrollIntoView({
            behavior:'smooth',
            block:'center',
            inline:'nearest'
        });

        // Если таблица была прокручена далеко вправо, возвращаем начало,
        // чтобы сразу было видно название базы.
        const tableWrap=document.querySelector('.table-wrap');
        if(tableWrap){
            tableWrap.scrollTo({
                left:0,
                behavior:'smooth'
            });
        }

        setTimeout(()=>{
            target.classList.add('event-row-highlight-pulse');
        },350);

        setTimeout(()=>{
            target.classList.remove('event-row-highlight-pulse');
        },3000);

        setTimeout(()=>{
            target.classList.remove('event-row-highlight');
        },8000);
    }

    document.querySelectorAll('.event-db-link').forEach(button=>{
        button.addEventListener('click',function(event){
            event.stopPropagation();
            focusDatabaseRow(button.dataset.db);
        });
    });


    // v21: tooltip on DB name, selection, cancel, report and PS1 export.
    const dbHoverTooltip=document.getElementById('dbHoverTooltip');

    function formatCountdown(ms){
        if(ms<=0)return '00:00:00';
        const total=Math.floor(ms/1000);
        const h=Math.floor(total/3600);
        const m=Math.floor((total%3600)/60);
        const s=total%60;
        return String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')+':'+String(s).padStart(2,'0');
    }

    let hoverTarget=null;
    let hoverTimer=null;

    function renderDbHover(target,event){
        if(!target||!dbHoverTooltip)return;
        const next=target.dataset.next?new Date(target.dataset.next):null;
        let schedule='Расписание не задано';
        if(next && !isNaN(next)){
            schedule='Ожидаемое время: '+next.toLocaleString('ru-RU')+
                ' · осталось '+formatCountdown(next.getTime()-Date.now());
        }

        const sync=target.dataset.sync||'-';
        const uploadText=sync==='S3_MISSING'
            ? 'S3: загрузка по заданному расписанию после готовности файла'
            : (sync==='SYNCED'?'S3: синхронизировано':'S3: '+sync);

        dbHoverTooltip.innerHTML=
            '<strong>'+target.closest('tr').dataset.db+'</strong>'+
            '<div>'+schedule+'</div>'+
            '<div>'+uploadText+'</div>'+
            '<div>Health '+(target.dataset.health||'-')+
            '% · Local '+(target.dataset.localCount||0)+
            ' · S3 '+(target.dataset.s3Count||0)+'</div>';

        dbHoverTooltip.style.display='block';
        const r=dbHoverTooltip.getBoundingClientRect();
        let x=event.clientX+14,y=event.clientY+14;
        if(x+r.width>innerWidth-8)x=event.clientX-r.width-14;
        if(y+r.height>innerHeight-8)y=event.clientY-r.height-14;
        dbHoverTooltip.style.left=Math.max(8,x)+'px';
        dbHoverTooltip.style.top=Math.max(8,y)+'px';
    }

    document.querySelectorAll('.db-hover-target').forEach(t=>{
        t.addEventListener('mouseenter',e=>{
            hoverTarget=t;
            renderDbHover(t,e);
            if(hoverTimer)clearInterval(hoverTimer);
            hoverTimer=setInterval(()=>renderDbHover(t,e),1000);
        });
        t.addEventListener('mousemove',e=>renderDbHover(t,e));
        t.addEventListener('mouseleave',()=>{
            hoverTarget=null;
            if(hoverTimer){clearInterval(hoverTimer);hoverTimer=null;}
            dbHoverTooltip.style.display='none';
        });
    });

    const selectedButton=document.getElementById('checkSelectedButton');
    const deleteSelectedButton=document.getElementById('deleteSelectedButton');
    const selectAllJobsButton=document.getElementById('selectAllJobsButton');
    const selectionBoxes=Array.from(document.querySelectorAll('.db-select'));

    function updateSelection(){
        const count=selectionBoxes.filter(x=>x.checked).length;
        selectedButton.hidden=count===0;
        deleteSelectedButton.hidden=count===0;
        selectedButton.textContent='Проверить выбранные ('+count+')';
        deleteSelectedButton.textContent='Удалить выбранные ('+count+')';
        const visible=selectionBoxes.filter(function(box){return box.closest('.db-row').style.display!=='none';});
        selectAllJobsButton.textContent=visible.length>0&&visible.every(x=>x.checked)?'Снять выделение':'Выбрать все';
    }
    selectionBoxes.forEach(cb=>{
        cb.addEventListener('click',e=>e.stopPropagation());
        cb.addEventListener('change',updateSelection);
    });

    selectAllJobsButton.addEventListener('click',function(){
        const visible=selectionBoxes.filter(function(box){return box.closest('.db-row').style.display!=='none';});
        const shouldSelect=!visible.length?false:!visible.every(x=>x.checked);
        visible.forEach(function(box){box.checked=shouldSelect;});
        updateSelection();
    });

    deleteSelectedButton.addEventListener('click',async function(){
        const names=selectionBoxes.filter(x=>x.checked).map(x=>x.dataset.db);
        if(!names.length)return;
        if(!await appConfirm('Удалить выбранные базы из BackupS3: '+names.length+'?\n\nЛокальные копии и объекты S3 удалены НЕ будут.',{title:'Групповое удаление баз',confirmText:'Удалить '+names.length,kind:'danger'}))return;
        deleteSelectedButton.disabled=true;
        selectedButton.disabled=true;
        selectAllJobsButton.disabled=true;
        try{
            const response=await fetch('/api/jobs/delete-selected',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Names:names})});
            if(!response.ok){let text=await response.text();try{text=JSON.parse(text).error||text}catch(_){}throw new Error(text);}
            location.reload();
        }catch(e){
            deleteSelectedButton.disabled=false;selectedButton.disabled=false;selectAllJobsButton.disabled=false;
            await showAppDialog({title:'Ошибка удаления',message:e.message,kind:'error'});
        }
    });

    selectedButton.addEventListener('click',async()=>{
        const names=selectionBoxes.filter(x=>x.checked).map(x=>x.dataset.db);
        if(!names.length)return;

        selectedButton.disabled=true;
        stopProgressReplay();
        progressRunStartedAt=Date.now();
        progressLastRenderedCurrent=0;
        progressForceReplay=false;
        refreshButton.disabled=true;

        progressTitle.textContent='Запускаю выбранные базы';
        progressDatabase.textContent='';
        progressPercent.textContent='0%';
        progressBar.style.width='0%';
        progressMessage.textContent='Выбрано баз: '+names.length;
        progressCounter.textContent='0 / '+names.length;
        progressPanel.classList.add('running');
        progressPanel.classList.remove('finished');
        cancelCheckButton.hidden=false;

        try{
            const r=await fetchWithTimeout('/api/jobs/check-selected',{
                method:'POST',
                headers:{'Content-Type':'application/json'},
                body:JSON.stringify({Names:names})
            },8000);

            if(!r.ok){
                let t=await r.text();
                try{t=JSON.parse(t).error||t}catch(_){}

                if(r.status===409){
                    progressTitle.textContent='Проверка уже выполняется';
                    progressMessage.textContent=t;
                    progressPanel.classList.add('running');
                    cancelCheckButton.hidden=false;
                    lastWasRunning=true;
                    if(progressTimer)clearInterval(progressTimer);
                    progressTimer=setInterval(pollProgress,250);
                    await pollProgress();
                    return;
                }

                throw new Error(t);
            }

            lastWasRunning=true;
            if(progressTimer)clearInterval(progressTimer);
            progressTimer=setInterval(pollProgress,250);
            await pollProgress();
        }catch(e){
            progressPanel.classList.remove('running');
            progressTitle.textContent='Ошибка запуска';
            progressMessage.textContent=e.message;
            cancelCheckButton.hidden=true;
            refreshButton.disabled=false;
        }finally{
            selectedButton.disabled=false;
        }
    });

    const cancelCheckButton=document.getElementById('cancelCheckButton');
    cancelCheckButton.addEventListener('click',async()=>{
        if(!await appConfirm('Остановить текущую проверку BackupS3?',{title:'Остановка проверки',confirmText:'Остановить',kind:'danger'}))return;
        cancelCheckButton.disabled=true;
        try{
            const r=await fetchWithTimeout('/api/cancel',{method:'POST'},5000);
            if(!r.ok)throw new Error(await r.text());
            progressTitle.textContent='Проверка остановлена';
            progressMessage.textContent='Процесс остановлен пользователем';
            progressPanel.classList.remove('running');
            cancelCheckButton.hidden=true;
        }catch(e){
            alert('Не удалось остановить проверку: '+e.message);
        }finally{
            cancelCheckButton.disabled=false;
        }
    });


    // v23.11 Desktop: S3 connection health in the upper-right corner.
    // IMPORTANT: this block intentionally uses no JavaScript template literals.
    // Generate-Dashboard.ps1 stores HTML in an expandable PowerShell here-string,
    // so JS backticks / ${...} can corrupt the generated JavaScript and stop
    // every button on the page from registering its event handlers.
    const s3StatusButton=document.getElementById('s3StatusButton');
    const s3StatusPopover=document.getElementById('s3StatusPopover');
    const s3StatusRefresh=document.getElementById('s3StatusRefresh');
    const s3StatusEndpoint=document.getElementById('s3StatusEndpoint');
    const s3StatusList=document.getElementById('s3StatusList');

    function escapeS3Html(value){
        return String(value==null?'':value)
            .replaceAll('&','&amp;')
            .replaceAll('<','&lt;')
            .replaceAll('>','&gt;')
            .replaceAll('"','&quot;')
            .replaceAll("'",'&#39;');
    }

    async function loadS3ConnectionStatus(showPopover){
        if(!s3StatusButton)return;

        s3StatusButton.classList.remove('s3-ok','s3-warn','s3-error');
        s3StatusButton.textContent='S3 · проверка…';

        if(showPopover && s3StatusPopover){
            s3StatusPopover.hidden=false;
            s3StatusList.textContent='Проверяю подключения…';
        }

        try{
            const r=await fetchWithTimeout('/api/s3-connections',{cache:'no-store'},15000);
            let data={};
            try{data=await r.json();}catch(_){}

            if(!r.ok)throw new Error(data.error||('HTTP '+r.status));

            const total=Number(data.total||0);
            const okCount=Number(data.ok||0);

            if(total===0){
                s3StatusButton.textContent='S3 · нет конфигураций';
                s3StatusButton.classList.add('s3-warn');
            }else if(okCount===total){
                s3StatusButton.textContent='S3 · '+okCount+'/'+total;
                s3StatusButton.classList.add('s3-ok');
            }else if(okCount>0){
                s3StatusButton.textContent='S3 · '+okCount+'/'+total;
                s3StatusButton.classList.add('s3-warn');
            }else{
                s3StatusButton.textContent='S3 · 0/'+total;
                s3StatusButton.classList.add('s3-error');
            }

            if(s3StatusEndpoint){
                s3StatusEndpoint.textContent=data.endpoint?('Endpoint: '+data.endpoint):'';
            }

            const rows=Array.isArray(data.connections)?data.connections:[];
            if(!s3StatusList)return;

            if(!rows.length){
                s3StatusList.innerHTML='<div class="muted">S3 подключения ещё не настроены.</div>';
            }else{
                const html=[];
                rows.forEach(function(item){
                    const itemOk=!!item.ok;
                    html.push(
                        '<div class="s3-connection-row">'+
                            '<div class="s3-connection-bucket">'+escapeS3Html(item.bucket)+'</div>'+
                            '<div class="s3-connection-profile">профиль: '+escapeS3Html(item.profileDisplay||'стандартный')+'</div>'+
                            '<div class="s3-connection-state '+(itemOk?'ok':'error')+'">'+(itemOk?'Доступен':'Ошибка')+'</div>'+
                            (itemOk?'':'<div class="s3-connection-error">'+escapeS3Html(item.message||'Нет ответа')+'</div>')+
                        '</div>'
                    );
                });
                s3StatusList.innerHTML=html.join('');
            }
        }catch(e){
            s3StatusButton.textContent='S3 · ошибка';
            s3StatusButton.classList.add('s3-error');
            if(s3StatusList){
                s3StatusList.textContent='Не удалось проверить S3: '+(e&&e.message?e.message:String(e));
            }
        }
    }

    if(s3StatusButton && s3StatusPopover && s3StatusRefresh){
        s3StatusButton.addEventListener('click',async function(event){
            event.stopPropagation();
            const opening=s3StatusPopover.hidden;
            s3StatusPopover.hidden=!opening;
            if(opening)await loadS3ConnectionStatus(true);
        });

        s3StatusRefresh.addEventListener('click',async function(event){
            event.stopPropagation();
            await loadS3ConnectionStatus(true);
        });

        document.addEventListener('click',function(event){
            const wrap=event.target&&event.target.closest?event.target.closest('.s3-status-wrap'):null;
            if(!wrap)s3StatusPopover.hidden=true;
        });

        // Do not block normal dashboard initialization.
        setTimeout(function(){loadS3ConnectionStatus(false);},700);
    }

    // Report.
    const reportModal=document.getElementById('reportModal');
    document.getElementById('reportButton').addEventListener('click',()=>{reportModal.hidden=false;document.body.classList.add('modal-open');});
    function closeReport(){reportModal.hidden=true;document.body.classList.remove('modal-open');}
    document.getElementById('closeReportModal').addEventListener('click',closeReport);
    document.getElementById('cancelReport').addEventListener('click',closeReport);

    async function downloadApiFile(url,fileName){
        const response=await fetch(url,{cache:'no-store'});
        if(!response.ok){let text=await response.text();try{text=JSON.parse(text).error||text}catch(_){}throw new Error(text);}
        const objectUrl=URL.createObjectURL(await response.blob());
        const link=document.createElement('a');link.href=objectUrl;link.download=fileName;document.body.appendChild(link);link.click();link.remove();
        setTimeout(function(){URL.revokeObjectURL(objectUrl);},1500);
    }

    document.getElementById('downloadReport').addEventListener('click',async()=>{
        const value=Math.max(1,Number(document.getElementById('reportValue').value)||1);
        const unit=document.getElementById('reportUnit').value;
        const format=document.getElementById('reportFormat').value;
        const button=document.getElementById('downloadReport');
        button.disabled=true;
        try{await downloadApiFile('/api/report?value='+encodeURIComponent(value)+'&unit='+encodeURIComponent(unit)+'&format='+encodeURIComponent(format),'BackupS3-report.'+format);}
        catch(e){await showAppDialog({title:'Ошибка формирования отчёта',message:e.message,kind:'error'});}
        finally{button.disabled=false;}
    });

    document.getElementById('exportJobPs1').addEventListener('click',async()=>{
        const name=document.getElementById('editJobName').value;
        if(!name)return;
        try{await downloadApiFile('/api/jobs/export-ps1?name='+encodeURIComponent(name),'BackupS3-'+name+'.ps1');}
        catch(e){editJobError.textContent='Ошибка экспорта: '+e.message;}
    });


    // v21.10: full Dashboard Server restart from the browser.
    const restartDashboardButton=document.getElementById('restartDashboardButton');
    const serverRestartOverlay=document.getElementById('serverRestartOverlay');
    const serverRestartMessage=document.getElementById('serverRestartMessage');

    async function waitForDashboardAfterRestart(){
        const started=Date.now();
        let sawOffline=false;
        let consecutiveOk=0;

        while(Date.now()-started < 30000){
            await new Promise(resolve=>setTimeout(resolve,800));

            try{
                const r=await fetch('/api/health?t='+Date.now(),{
                    cache:'no-store'
                });

                if(r.ok){
                    consecutiveOk++;

                    // Two consecutive successful health checks mean the listener
                    // is stable again. This also works on machines where the
                    // offline window is too short for the browser to observe.
                    if((sawOffline && consecutiveOk>=1) || consecutiveOk>=2){
                        serverRestartMessage.textContent='Dashboard запущен. Обновляю страницу...';
                        await new Promise(resolve=>setTimeout(resolve,350));
                        location.reload();
                        return;
                    }
                }else{
                    consecutiveOk=0;
                }
            }catch(_){
                sawOffline=true;
                consecutiveOk=0;
                serverRestartMessage.textContent='Web-сервер перезапускается...';
            }
        }

        serverRestartMessage.textContent='Desktop API не ответил. Перезапусти BackupS3Manager.exe.';
        restartDashboardButton.disabled=false;
    }

    restartDashboardButton.addEventListener('click',async()=>{
        if(!await appConfirm('Полностью перезапустить Backup S3 Dashboard? Текущая проверка BackupS3, если она идёт, не будет остановлена.',{title:'Перезапуск Dashboard',confirmText:'Перезапустить'})){
            return;
        }

        restartDashboardButton.disabled=true;
        serverRestartOverlay.hidden=false;
        serverRestartMessage.textContent='Отправляю команду перезапуска...';

        let requestReachedServer=false;

        try{
            const r=await fetchWithTimeout('/api/server/restart',{
                method:'POST'
            },7000);

            requestReachedServer=true;

            if(!r.ok){
                let t=await r.text();
                try{t=JSON.parse(t).error||t}catch(_){}
                throw new Error(t);
            }

            serverRestartMessage.textContent='Старый web-сервер останавливается...';
            waitForDashboardAfterRestart();
        }catch(e){
            // During a self-restart the TCP connection can disappear while the
            // browser is finalising fetch. Treat network abort as expected and
            // verify /api/health instead of showing a false error popup.
            const msg=String(e && e.message ? e.message : e);
            if(msg.includes('Failed to fetch') || msg.includes('aborted') || msg.includes('NetworkError')){
                serverRestartMessage.textContent='Соединение разорвано — ожидаю новый Dashboard...';
                waitForDashboardAfterRestart();
                return;
            }

            serverRestartOverlay.hidden=true;
            restartDashboardButton.disabled=false;
            alert('Не удалось перезапустить Dashboard: '+msg);
        }
    });

    const progressPanel = document.getElementById('progressPanel');
    const progressTitle = document.getElementById('progressTitle');
    const progressDatabase = document.getElementById('progressDatabase');
    const progressPercent = document.getElementById('progressPercent');
    const progressBar = document.getElementById('progressBar');
    const progressMessage = document.getElementById('progressMessage');
    const progressCheckedWrap = document.getElementById('progressCheckedWrap');
    const progressChecked = document.getElementById('progressChecked');
    const progressCounter = document.getElementById('progressCounter');
    const progressStall = document.getElementById('progressStall');

    let progressTimer = null;
    let progressFinishedResetTimer = null;
    let progressReplayTimer = null;
    let progressRunStartedAt = 0;
    let progressLastRenderedCurrent = 0;
    let progressReplayActive = false;
    let progressReplayLatestData = null;
    let progressForceReplay = false;
    let lastWasRunning = false;

    function resetProgressPanelToReady(){
        if(progressFinishedResetTimer){
            clearTimeout(progressFinishedResetTimer);
            progressFinishedResetTimer=null;
        }
        stopProgressReplay();
        progressRunStartedAt=0;
        progressLastRenderedCurrent=0;
        progressForceReplay=false;

        progressPanel.classList.remove('running','finished');
        progressTitle.textContent='Готов к проверке';
        progressDatabase.textContent='';
        progressPercent.textContent='0%';
        progressBar.style.width='0%';
        progressMessage.textContent='Нажмите «Проверить сейчас»';
        progressCounter.textContent='0 / 0';
        // v21.30: строку «Проверено:» сохраняем.
        // Она очищается только при фактическом старте новой проверки,
        // после чего снова заполняется реальными результатами progress.json.
        progressStall.hidden=true;
        progressStall.textContent='';
        cancelCheckButton.hidden=true;
        refreshButton.disabled=false;
    }

    function renderCheckedDatabases(data){
        if(!progressChecked || !progressCheckedWrap)return;

        const checked=Array.isArray(data.checked)?data.checked:[];

        progressChecked.innerHTML='';

        if(checked.length===0){
            progressCheckedWrap.hidden=true;
            return;
        }

        progressCheckedWrap.hidden=false;

        checked.forEach(function(name,index){
            const item=document.createElement('button');
            item.type='button';

            const row=document.querySelector('.db-row[data-db="'+CSS.escape(String(name))+'"]');
            const status=row ? String(row.dataset.status||'').toUpperCase() : '';

            let statusClass=' status-neutral';
            if(['OK','UPLOADED','READY'].includes(status)){
                statusClass=' status-ok';
            }else if(status==='WAITING'){
                statusClass=' status-waiting';
            }else if(['STALE','WARNING'].includes(status)){
                statusClass=' status-warning';
            }else if(status==='ERROR'){
                statusClass=' status-error';
            }else if(status==='MAINTENANCE'){
                statusClass=' status-maintenance';
            }

            item.className=
                'progress-checked-item'+
                statusClass+
                (index===checked.length-1?' current':'');
            item.textContent=String(name);
            item.dataset.db=String(name);
            item.dataset.status=status;
            item.title='Перейти к базе '+String(name)+(status?' · статус: '+statusLabel(status):'');

            item.addEventListener('click',function(event){
                event.preventDefault();
                event.stopPropagation();

                if(typeof focusDatabaseRow==='function'){
                    focusDatabaseRow(item.dataset.db);
                }
            });

            progressChecked.appendChild(item);
        });
    }


    function stopProgressReplay(){
        if(progressReplayTimer){
            clearTimeout(progressReplayTimer);
            progressReplayTimer=null;
        }
        progressReplayActive=false;
        progressReplayLatestData=null;
    }

    // v21.30:
    // Искусственное воспроизведение уже завершённой проверки отключено.
    // Dashboard показывает только фактический progress.json.
    function startOrUpdateProgressReplay(data){
        return false;
    }

    function renderProgress(data) {
        const pct = Math.max(0, Math.min(100, Number(data.percent || 0)));
        const current = Number(data.current || 0);
        const total = Number(data.total || 0);
        const checkedCount=Array.isArray(data.checked)?data.checked.length:0;

        if(data.running && !progressRunStartedAt){
            progressRunStartedAt=Date.now();
        }

        // v21.30: только реальное состояние контроллера.
        // Никакого повторного "проигрывания" уже завершённых 19 баз.
        progressLastRenderedCurrent=current;

        progressPercent.textContent = pct + '%';
        progressBar.style.width = pct + '%';
        progressCounter.textContent = current + ' / ' + total;
        progressDatabase.textContent = data.database ? '· ' + data.database : '';
        progressMessage.textContent = data.message || '';
        if(data.phase==='FINISHED' && data.updatedAt){
            const finishedAt=new Date(data.updatedAt);
            if(!Number.isNaN(finishedAt.getTime())){
                progressMessage.textContent=
                    (data.message||'Проверка завершена')+
                    ' · '+finishedAt.toLocaleString('ru-RU');
            }
        }
        renderCheckedDatabases(data);

        if(data.running && data.updatedAt){
            const seconds=Math.max(0,Math.floor((Date.now()-new Date(data.updatedAt).getTime())/1000));

            if(seconds>=120){
                progressStall.hidden=false;
                progressStall.className='progress-stall danger';
                progressStall.textContent='⚠ Нет обновления '+seconds+' сек. — открой Лог';
            }
            else if(seconds>=45){
                progressStall.hidden=false;
                progressStall.className='progress-stall warning';
                progressStall.textContent='Нет обновления '+seconds+' сек.';
            }
            else{
                progressStall.hidden=true;
                progressStall.textContent='';
            }
        }else{
            progressStall.hidden=true;
            progressStall.textContent='';
        }

        progressPanel.classList.toggle('running', !!data.running);
        progressPanel.classList.toggle('finished', data.phase === 'FINISHED');

        if (data.phase === 'FINISHED') {
            progressTitle.textContent = 'Последняя проверка завершена';

            // v21.31: FINISHED — это статический результат, а не активная проверка.
            // Всегда прекращаем частый polling progress.json.
            if(progressTimer){
                clearInterval(progressTimer);
                progressTimer=null;
            }

            progressPanel.classList.remove('running');
            cancelCheckButton.hidden=true;
            refreshButton.disabled=false;

            if(progressFinishedResetTimer){
                clearTimeout(progressFinishedResetTimer);
                progressFinishedResetTimer=null;
            }
        } else if (data.phase === 'CHECKED') {
            progressTitle.textContent = 'База проверена';
        } else if (data.phase === 'STARTING') {
            if(progressFinishedResetTimer){
                clearTimeout(progressFinishedResetTimer);
                progressFinishedResetTimer=null;
            }
            progressTitle.textContent = 'Подготовка проверки';
        } else if (data.running) {
            if(progressFinishedResetTimer){
                clearTimeout(progressFinishedResetTimer);
                progressFinishedResetTimer=null;
            }
            progressTitle.textContent = 'Проверка резервных копий';
        } else {
            progressTitle.textContent = 'Готов к проверке';
        }

        if (!data.running && data.phase === 'FINISHED') {
            refreshButton.disabled=false;
            cancelCheckButton.hidden=true;
        }

        if (!data.running && data.phase === 'CANCELLED') {
            if(progressTimer){
                clearInterval(progressTimer);
                progressTimer=null;
            }
            refreshButton.disabled=false;
            selectedButton.disabled=false;
            cancelCheckButton.hidden=true;
            progressTitle.textContent='Проверка остановлена';
            progressMessage.textContent=data.message||'Остановлено пользователем';
        }

        lastWasRunning = !!data.running;
    }

    async function pollProgress() {
        try {
            const response = await fetch('/api/progress?t=' + Date.now());
            if (!response.ok) return;
            const data = await response.json();
            renderProgress(data);
        } catch (_) {}
    }

    refreshButton.addEventListener('click', async function () {
        refreshButton.disabled = true;
        stopProgressReplay();
        progressRunStartedAt=Date.now();
        progressLastRenderedCurrent=0;
        progressForceReplay=false;

        progressTitle.textContent = 'Запускаю проверку';
        progressDatabase.textContent = '';
        progressPercent.textContent = '0%';
        progressBar.style.width = '0%';
        progressMessage.textContent = 'Запуск BackupS3.ps1...';
        progressCounter.textContent = '0 / 0';
        if(progressChecked)progressChecked.innerHTML='';
        if(progressCheckedWrap)progressCheckedWrap.hidden=true;
        progressPanel.classList.add('running');
        progressPanel.classList.remove('finished');
        cancelCheckButton.hidden=false;

        try {
            const response = await fetchWithTimeout('/api/refresh', { method: 'POST' }, 8000);
            if (!response.ok) {
                let t=await response.text();
                try{t=JSON.parse(t).error||t}catch(_){}

                if(response.status===409){
                    progressTitle.textContent='Проверка уже выполняется';
                    progressMessage.textContent=t;
                    progressPanel.classList.add('running');
                    cancelCheckButton.hidden=false;
                    lastWasRunning=true;
                    if(progressTimer)clearInterval(progressTimer);
                    progressTimer=setInterval(pollProgress,250);
                    await pollProgress();
                    return;
                }

                throw new Error(t);
            }

            lastWasRunning = true;

            if (progressTimer) clearInterval(progressTimer);
            progressTimer = setInterval(pollProgress, 250);
            await pollProgress();
        }
        catch (e) {
            refreshButton.disabled = false;
            progressPanel.classList.remove('running');
            cancelCheckButton.hidden = true;
            progressTitle.textContent = 'Ошибка запуска';
            progressMessage.textContent =
                e.name==='AbortError'
                    ? 'Web-сервер не ответил за 8 секунд. Открой «Лог» → «Web-сервер».'
                    : e.message;
        }
    });

    async function syncControllerStatus(){
        try{
            const r=await fetchWithTimeout('/api/controller-status?t='+Date.now(),{cache:'no-store'},3000);
            if(!r.ok)return;
            const d=await r.json();

            if(d.running){
                cancelCheckButton.hidden=false;
                refreshButton.disabled=true;
                lastWasRunning=true;

                if(progressTimer)clearInterval(progressTimer);
                progressTimer=setInterval(pollProgress,250);
                await pollProgress();
            }
        }catch(_){}
    }

    // При открытии страницы показываем фактическое состояние процесса и progress.json.
    pollProgress();
    syncControllerStatus();






    // v21.32: реальный прогресс загрузки AWS CLI для каждой базы.
    function renderDatabaseUploadProgress(item){
        const db=String(item.database||'');
        if(!db)return;

        const box=document.querySelector(
            '.db-upload-progress[data-upload-db="'+CSS.escape(db)+'"]'
        );
        if(!box)return;

        const status=String(item.status||'');
        const updatedAt=item.updatedAt ? new Date(item.updatedAt).getTime() : 0;
        const fresh=updatedAt && (Date.now()-updatedAt)<15000;
        const active=status==='UPLOADING' && fresh;

        if(!active && status!=='ERROR'){
            box.hidden=true;
            return;
        }

        box.hidden=false;

        const pct=Math.max(0,Math.min(100,Number(item.percent||0)));
        const total=Number(item.totalBytes||0);
        const uploaded=Number(item.uploadedBytes||0);
        const remaining=Number(item.remainingBytes||Math.max(0,total-uploaded));

        box.querySelector('.db-upload-progress-percent').textContent=
            status==='ERROR'?'Ошибка':pct.toFixed(pct<10?1:0)+'%';

        box.querySelector('.db-upload-progress-fill').style.width=pct+'%';

        box.querySelector('.db-upload-progress-text').textContent=
            status==='ERROR'
                ? 'Ошибка загрузки'
                : 'Загрузка на S3';

        box.querySelector('.db-upload-progress-meta').textContent=
            'Загружено '+fmtBytesClient(uploaded)+
            ' из '+fmtBytesClient(total)+
            ' · осталось '+fmtBytesClient(remaining)+
            (item.speedText?' · '+item.speedText:'');

        box.classList.toggle('error',status==='ERROR');
    }

    async function pollDatabaseUploadProgress(){
        try{
            const r=await fetch(
                '/api/upload-progress?t='+Date.now(),
                {cache:'no-store'}
            );
            if(!r.ok)return;

            const data=await r.json();
            const activeNames=new Set();

            (Array.isArray(data.items)?data.items:[]).forEach(item=>{
                if(String(item.status||'')==='UPLOADING'){
                    activeNames.add(String(item.database||''));
                }
                renderDatabaseUploadProgress(item);
            });

            document.querySelectorAll('.db-upload-progress').forEach(box=>{
                const db=String(box.dataset.uploadDb||'');
                if(!activeNames.has(db) && !box.classList.contains('error')){
                    box.hidden=true;
                }
            });
        }catch(_){}
    }

    pollDatabaseUploadProgress();
    setInterval(pollDatabaseUploadProgress,750);


    // Scheduler display uses persisted backend time and launches the real
    // AutoScheduler when the visible deadline is reached.
    const schedulerState=document.getElementById('schedulerState');
    const schedulerNextCheck=document.getElementById('schedulerNextCheck');
    const schedulerCountdown=document.getElementById('schedulerCountdown');
    const schedulerCheckNow=document.getElementById('schedulerCheckNow');

    let schedulerEnabled=false;
    let schedulerIntervalMinutes=0;
    let schedulerNextAt=null;
    let schedulerCountdownTimer=null;
    let schedulerStarting=false;

    // Render help in a body-level fixed layer so modal scrolling and window
    // edges can never clip the text.
    const fieldHelpTooltip=document.getElementById('fieldHelpTooltip');
    function showFieldHelp(target){
        fieldHelpTooltip.textContent=target.dataset.help||'';
        fieldHelpTooltip.hidden=false;
        const anchor=target.getBoundingClientRect();
        const tip=fieldHelpTooltip.getBoundingClientRect();
        const margin=12;
        let left=anchor.left+(anchor.width-tip.width)/2;
        left=Math.max(margin,Math.min(left,window.innerWidth-tip.width-margin));
        let top=anchor.top-tip.height-8;
        if(top<margin)top=Math.min(window.innerHeight-tip.height-margin,anchor.bottom+8);
        fieldHelpTooltip.style.left=Math.round(left)+'px';
        fieldHelpTooltip.style.top=Math.round(Math.max(margin,top))+'px';
    }
    document.querySelectorAll('.field-help').forEach(help=>{
        help.tabIndex=0;
        help.setAttribute('aria-label',help.dataset.help||'Подсказка');
        help.addEventListener('mouseenter',()=>showFieldHelp(help));
        help.addEventListener('focus',()=>showFieldHelp(help));
        help.addEventListener('mouseleave',()=>{fieldHelpTooltip.hidden=true;});
        help.addEventListener('blur',()=>{fieldHelpTooltip.hidden=true;});
    });

    function formatCountdown(ms){
        if(ms<=0)return '00:00';

        const totalSeconds=Math.ceil(ms/1000);
        const hours=Math.floor(totalSeconds/3600);
        const minutes=Math.floor((totalSeconds%3600)/60);
        const seconds=totalSeconds%60;

        const mm=String(minutes).padStart(2,'0');
        const ss=String(seconds).padStart(2,'0');

        return hours>0
            ? String(hours).padStart(2,'0')+':'+mm+':'+ss
            : mm+':'+ss;
    }

    function renderSchedulerCountdown(){
        if(!schedulerEnabled || !schedulerNextAt){
            schedulerCountdown.textContent='—';
            return;
        }

        let remaining=schedulerNextAt.getTime()-Date.now();

        if(remaining<=0){
            schedulerCountdown.textContent='Запуск...';
            if(!schedulerStarting)startScheduledCheck();
            return;
        }

        schedulerCountdown.textContent=formatCountdown(remaining);
    }

    async function startScheduledCheck(){
        schedulerStarting=true;
        try{
            const r=await fetchWithTimeout('/api/scheduler/run',{method:'POST'},5000);
            if(!r.ok && r.status!==409)throw new Error('HTTP '+r.status);
            await loadSchedulerDisplay();
            // State/progress are refreshed without navigating or closing the app.
            setTimeout(()=>{ if(typeof pollProgress==='function')pollProgress(); },400);
        }catch(e){
            schedulerState.textContent='Ошибка запуска автоматической проверки';
            schedulerState.className='scheduler-error';
            schedulerNextAt=new Date(Date.now()+15000);
        }finally{schedulerStarting=false;}
    }

    async function loadSchedulerDisplay(){
        // Reset cached scheduler display state first so stale "Включено"
        // never remains visible after the setting is disabled.
        schedulerEnabled=false;
        schedulerIntervalMinutes=0;
        schedulerNextAt=null;

        try{
            const r=await fetchWithTimeout(
                '/api/scheduler/status?t='+Date.now(),
                {cache:'no-store'},
                3000
            );

            if(!r.ok)throw new Error('HTTP '+r.status);

            const s=await r.json();

            schedulerEnabled=!!s.enabled;
            schedulerIntervalMinutes=Math.max(
                1,
                Number(s.intervalMinutes||2)
            );

            if(!schedulerEnabled){
                schedulerState.textContent='Выключено';
                schedulerState.className='scheduler-off';
                schedulerNextCheck.textContent='—';
                schedulerCountdown.textContent='—';
                schedulerNextAt=null;
                return;
            }

            schedulerState.textContent=
                'Включено · каждые '+schedulerIntervalMinutes+' мин.';
            schedulerState.className='scheduler-on';

            schedulerNextAt=s.nextRunAt?new Date(s.nextRunAt):new Date(Date.now()+schedulerIntervalMinutes*60000);

            schedulerNextCheck.textContent=
                schedulerNextAt.toLocaleTimeString('ru-RU',{
                    hour:'2-digit',
                    minute:'2-digit',
                    second:'2-digit'
                });

            renderSchedulerCountdown();
        }catch(e){
            schedulerState.textContent='Не удалось прочитать настройки';
            schedulerState.className='scheduler-error';
            schedulerNextCheck.textContent='—';
            schedulerCountdown.textContent='—';
            schedulerEnabled=false;
            schedulerNextAt=null;
        }
    }

    if(schedulerCountdownTimer)clearInterval(schedulerCountdownTimer);
    schedulerCountdownTimer=setInterval(renderSchedulerCountdown,1000);
    setInterval(()=>{if(!schedulerStarting)loadSchedulerDisplay();},15000);
    loadSchedulerDisplay();

    if(schedulerCheckNow){
        schedulerCheckNow.addEventListener('click',function(){
            // Reuse the already-stable manual check path.
            if(refreshButton && !refreshButton.disabled){
                refreshButton.click();
            }
        });
    }


    // v13: убеждаемся, что HTML открыт через актуальный web-сервер.
    const serverVersionWarning = document.getElementById('serverVersionWarning');

    async function checkServerVersion() {
        try {
            const response = await fetch('/api/version?t=' + Date.now(), { cache: 'no-store' });
            if (!response.ok) throw new Error('HTTP ' + response.status);
            const data = await response.json();

            // Desktop v23 uses an in-process API bridge, not Start-DashboardServer.ps1.
            const isDesktop = String(data.name || '').toLowerCase().includes('desktop') ||
                              String(data.version || '').startsWith('23.');
            if (!isDesktop && String(data.version) !== '21.37') {
                serverVersionWarning.hidden = false;
                serverVersionWarning.textContent =
                    'Запущена несовместимая версия API.';
            } else {
                serverVersionWarning.hidden = true;
                serverVersionWarning.textContent = '';
            }
        }
        catch (_) {
            serverVersionWarning.hidden = false;
            serverVersionWarning.textContent =
                'Desktop API недоступен. Закрой и снова запусти BackupS3Manager.exe';
        }
    }

    checkServerVersion();

    // v23.14: visible workspace passport.
    fetch('/api/startup-workspace?t='+Date.now(),{cache:'no-store'}).then(r=>r.json()).then(s=>{
        document.getElementById('activeWorkspaceBadge').textContent='Текущая конфигурация: '+(s.mode==='new'?'новая':'сохранённая');
    }).catch(()=>{});

    // v23.12: named configuration snapshots and AWS CLI S3 profiles.
    const profilesButton=document.getElementById('profilesButton');
    const profilesModal=document.getElementById('profilesModal');
    const profilesError=document.getElementById('profilesError');

    async function apiJson(url,options){
        const response=await fetch(url,options||{cache:'no-store'});
        const text=await response.text();
        let data={};
        try{data=text?JSON.parse(text):{};}catch(_){data={error:text};}
        if(!response.ok)throw new Error(data.error||text||('HTTP '+response.status));
        return data;
    }

    async function loadConfigProfiles(){
        const data=await apiJson('/api/config-profiles?t='+Date.now());
        const list=document.getElementById('configProfilesList');
        list.innerHTML='';
        (data.profiles||[]).forEach(function(profile){
            const row=document.createElement('div');row.className='manager-row';
            const main=document.createElement('div');main.className='manager-row-main';
            const strong=document.createElement('strong');strong.textContent=profile.name;
            const meta=document.createElement('span');meta.textContent='Изменён: '+fmtDateClient(profile.updatedAt);
            main.append(strong,meta);row.appendChild(main);
            [['Загрузить','load'],['Экспорт','export'],['Удалить','delete']].forEach(function(action){
                const button=document.createElement('button');button.type='button';button.textContent=action[0];button.dataset.action=action[1];
                if(action[1]==='delete')button.className='danger';
                button.addEventListener('click',async function(){
                    try{
                        if(action[1]==='load'){
                            if(!await appConfirm('Загрузить профиль «'+profile.name+'»? Текущий набор баз и настроек будет заменён.',{title:'Загрузка профиля',confirmText:'Загрузить'}))return;
                            await apiJson('/api/config-profiles/load',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:profile.name})});
                            location.reload();
                        }else if(action[1]==='delete'){
                            if(!await appConfirm('Удалить сохранённый профиль «'+profile.name+'»?',{title:'Удаление профиля',confirmText:'Удалить',kind:'danger'}))return;
                            await apiJson('/api/config-profiles/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:profile.name})});
                            await loadConfigProfiles();
                        }else{
                            const response=await fetch('/api/config-profiles/export?name='+encodeURIComponent(profile.name));
                            if(!response.ok)throw new Error(await response.text());
                            const link=document.createElement('a');link.href=URL.createObjectURL(await response.blob());link.download='BackupS3-profile-'+profile.name+'.json';link.click();setTimeout(function(){URL.revokeObjectURL(link.href);},1000);
                        }
                    }catch(e){profilesError.textContent=e.message;}
                });row.appendChild(button);
            });list.appendChild(row);
        });
        if(!(data.profiles||[]).length)list.innerHTML='<div class="favorites-empty">Сохранённых профилей пока нет.</div>';
    }

    function clearS3Form(){
        ['s3ProfileName','s3AccessKey','s3SecretKey','s3SessionToken','s3Region','s3Endpoint'].forEach(function(id){document.getElementById(id).value='';});
    }

    async function loadS3Profiles(){
        const data=await apiJson('/api/s3-profiles?t='+Date.now());
        const list=document.getElementById('s3ProfilesList');list.innerHTML='';
        (data.profiles||[]).forEach(function(profile){
            const row=document.createElement('div');row.className='manager-row';
            const main=document.createElement('div');main.className='manager-row-main';
            const strong=document.createElement('strong');strong.textContent=profile.name;
            const meta=document.createElement('span');meta.textContent=(profile.accessKey||'Ключ не задан')+(profile.endpoint?' · '+profile.endpoint:'');
            main.append(strong,meta);row.appendChild(main);
            const reveal=document.createElement('button');reveal.type='button';reveal.textContent='Показать';
            reveal.addEventListener('click',async function(){
                try{const full=await apiJson('/api/s3-profiles/reveal',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:profile.name})});
                    document.getElementById('s3ProfileName').value=full.name||'';document.getElementById('s3AccessKey').value=full.accessKey||'';document.getElementById('s3SecretKey').value=full.secretKey||'';document.getElementById('s3SessionToken').value=full.sessionToken||'';document.getElementById('s3Region').value=full.region||'';document.getElementById('s3Endpoint').value=full.endpoint||'';
                }catch(e){profilesError.textContent=e.message;}
            });row.appendChild(reveal);
            const test=document.createElement('button');test.type='button';test.textContent='Проверить';test.addEventListener('click',async function(){try{test.disabled=true;test.textContent='Проверяю…';const r=await apiJson('/api/s3-profiles/test',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:profile.name,Endpoint:profile.endpoint||''})});await showAppDialog({title:'S3-подключение',message:r.message||'Подключение успешно',kind:'info'});}catch(e){await showAppDialog({title:'Ошибка S3',message:e.message,kind:'error'});}finally{test.disabled=false;test.textContent='Проверить';}});row.appendChild(test);
            const del=document.createElement('button');del.type='button';del.textContent='Удалить';del.className='danger';del.addEventListener('click',async function(){if(!await appConfirm('Удалить S3-профиль «'+profile.name+'» из AWS CLI?',{title:'Удаление S3-профиля',confirmText:'Удалить',kind:'danger'}))return;try{await apiJson('/api/s3-profiles/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:profile.name})});await loadS3Profiles();clearS3Form();}catch(e){profilesError.textContent=e.message;}});row.appendChild(del);
            list.appendChild(row);
        });
        if(!(data.profiles||[]).length)list.innerHTML='<div class="favorites-empty">S3-профили AWS CLI не найдены.</div>';
    }

    profilesButton.addEventListener('click',async function(){profilesError.textContent='';profilesModal.hidden=false;document.body.classList.add('modal-open');try{await Promise.all([loadConfigProfiles(),loadS3Profiles()]);}catch(e){profilesError.textContent=e.message;}});
    function closeProfiles(){profilesModal.hidden=true;document.body.classList.remove('modal-open');profilesError.textContent='';}
    document.getElementById('closeProfilesModal').addEventListener('click',closeProfiles);
    document.getElementById('saveConfigProfile').addEventListener('click',async function(){try{const name=document.getElementById('configProfileName').value.trim();await apiJson('/api/config-profiles/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:name})});await loadConfigProfiles();}catch(e){profilesError.textContent=e.message;}});
    document.getElementById('importConfigProfile').addEventListener('change',async function(){const file=this.files&&this.files[0];if(!file)return;try{const profile=JSON.parse(await file.text());if(profile.format!=='BackupS3Manager.Profile'||!Array.isArray(profile.jobs))throw new Error('Файл не является профилем BackupS3 Manager.');const names=profile.jobs.map(x=>String(x&&x.Name||'').trim()).filter(Boolean);if(new Set(names.map(x=>x.toLowerCase())).size!==names.length)throw new Error('В профиле есть базы с повторяющимися именами.');const name=String(profile.name||file.name.replace(/\.json$/i,'')).trim();if(!await appConfirm('Профиль «'+name+'» содержит баз: '+names.length+'. Проверка структуры пройдена. Импортировать?',{title:'Проверка профиля',confirmText:'Импортировать'}))return;document.getElementById('configProfileName').value=name;await apiJson('/api/config-profiles/import',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:name,Profile:profile})});await loadConfigProfiles();await showAppDialog({title:'Профиль импортирован',message:'Профиль «'+name+'» добавлен в список. Баз: '+names.length+'.',kind:'info'});}catch(e){profilesError.textContent='Ошибка импорта: '+e.message;}finally{this.value='';}});
    document.getElementById('clearS3ProfileForm').addEventListener('click',clearS3Form);
    document.querySelectorAll('.toggle-secret').forEach(function(button){button.addEventListener('click',function(){const input=document.getElementById(button.dataset.target);const show=input.type==='password';input.type=show?'text':'password';button.textContent=show?'Скрыть':'Показать';});});
    document.getElementById('s3ProfileForm').addEventListener('submit',async function(event){event.preventDefault();profilesError.textContent='';try{await apiJson('/api/s3-profiles/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:document.getElementById('s3ProfileName').value.trim(),AccessKey:document.getElementById('s3AccessKey').value.trim(),SecretKey:document.getElementById('s3SecretKey').value.trim(),SessionToken:document.getElementById('s3SessionToken').value.trim(),Region:document.getElementById('s3Region').value.trim(),Endpoint:document.getElementById('s3Endpoint').value.trim()})});clearS3Form();await loadS3Profiles();await showAppDialog({title:'S3-профиль сохранён',message:'Учётные данные записаны в стандартное хранилище AWS CLI.',kind:'info'});}catch(e){profilesError.textContent=e.message;}});

    // v17: runtime settings.
    const settingsButton=document.getElementById('settingsButton');
    const settingsModal=document.getElementById('settingsModal');
    const settingsForm=document.getElementById('settingsForm');
    const settingsError=document.getElementById('settingsError');
    const settingsWarning=document.getElementById('settingsWarning');
    const modeBanner=document.getElementById('modeBanner');
    const modeTitle=document.getElementById('modeTitle');
    const modeText=document.getElementById('modeText');

    const settingSafeMode=document.getElementById('settingSafeMode');
    const settingUpload=document.getElementById('settingUpload');
    const settingCleanup=document.getElementById('settingCleanup');
    const settingGraylog=document.getElementById('settingGraylog');
    const settingAutoScheduler=document.getElementById('settingAutoScheduler');
    const settingAutoSchedulerInterval=document.getElementById('settingAutoSchedulerInterval');
    const settingAutoStartBackground=document.getElementById('settingAutoStartBackground');
    const settingUpdateManifestUrl=document.getElementById('settingUpdateManifestUrl');
    const checkUpdatesButton=document.getElementById('checkUpdatesButton');
    const downloadUpdateButton=document.getElementById('downloadUpdateButton');
    const updateCheckStatus=document.getElementById('updateCheckStatus');

    function updateSettingsDangerState(){
        const safe=settingSafeMode.checked;
        settingUpload.disabled=safe;
        settingCleanup.disabled=safe;
        settingGraylog.disabled=safe;
        settingsWarning.hidden=safe;

        if(safe){
            modeBanner.classList.remove('danger');
            modeBanner.classList.add('safe');
            modeTitle.textContent='Безопасный режим';
            modeText.textContent='Загрузка, очистка S3 и Graylog заблокированы.';
        }else{
            modeBanner.classList.remove('safe');
            modeBanner.classList.add('danger');
            modeTitle.textContent='Рабочий режим';
            const enabled=[];
            if(settingUpload.checked)enabled.push('Загрузка');
            if(settingCleanup.checked)enabled.push('Очистка S3');
            if(settingGraylog.checked)enabled.push('Graylog');
            modeText.textContent=enabled.length?'Разрешено: '+enabled.join(', '):'Изменяющие операции пока выключены.';
        }
    }

    async function loadSettings(){
        settingsError.textContent='';
        const r=await fetchWithTimeout('/api/settings?t='+Date.now(),{cache:'no-store'},5000);
        if(!r.ok)throw new Error(await r.text());
        const s=await r.json();

        settingSafeMode.checked=!!s.SafeMode;
        settingUpload.checked=!!s.EnableUpload;
        settingCleanup.checked=!!s.EnableCleanup;
        settingGraylog.checked=!!s.EnableGraylog;
        document.getElementById('settingIdle').value=s.MinFileIdleMinutes;
        document.getElementById('settingRetryCount').value=s.RetryCount;
        document.getElementById('settingRetryDelay').value=s.RetryDelaySeconds;
        document.getElementById('settingHistoryDays').value=s.HistoryDays;
        document.getElementById('settingSizeAnomaly').value=s.DefaultSizeAnomalyPercent;
        document.getElementById('settingAutoRefresh').value=s.AutoRefreshSeconds;

        settingAutoScheduler.checked=!!s.AutoSchedulerEnabled;
        settingAutoSchedulerInterval.value=Number(s.AutoSchedulerIntervalMinutes||2);
        settingAutoSchedulerInterval.disabled=!settingAutoScheduler.checked;
        settingAutoStartBackground.checked=!!s.AutoStartInBackground;
        settingUpdateManifestUrl.value=s.UpdateManifestUrl||'';
        fetch('/api/version?t='+Date.now(),{cache:'no-store'}).then(r=>r.json()).then(v=>{
            document.getElementById('settingsCurrentVersion').textContent='BackupS3 Manager v'+(v.version||'23.14');
        }).catch(()=>{document.getElementById('settingsCurrentVersion').textContent='BackupS3 Manager v23.14';});

        updateSettingsDangerState();
        return s;
    }

    settingsButton.addEventListener('click',async()=>{
        try{
            await loadSettings();
            settingsModal.hidden=false;
            document.body.classList.add('modal-open');
        }catch(e){alert('Не удалось загрузить настройки: '+e.message);}
    });

    function closeSettings(){
        settingsModal.hidden=true;
        document.body.classList.remove('modal-open');
        settingsError.textContent='';
    }

    document.getElementById('closeSettingsModal').addEventListener('click',closeSettings);
    document.getElementById('cancelSettings').addEventListener('click',closeSettings);
    settingSafeMode.addEventListener('change',updateSettingsDangerState);
    settingUpload.addEventListener('change',updateSettingsDangerState);
    settingCleanup.addEventListener('change',updateSettingsDangerState);
    settingGraylog.addEventListener('change',updateSettingsDangerState);
    settingAutoScheduler.addEventListener('change',function(){
        settingAutoSchedulerInterval.disabled=!settingAutoScheduler.checked;
    });
    checkUpdatesButton.addEventListener('click',async function(){
        const old=this.textContent;this.disabled=true;this.textContent='Проверяю…';downloadUpdateButton.hidden=true;
        try{
            const r=await fetch('/api/update/check?t='+Date.now(),{cache:'no-store'});
            const data=await r.json();if(!r.ok)throw new Error(data.error||'Ошибка проверки обновлений');
            updateCheckStatus.textContent=data.message||'Проверка завершена.';
            updateCheckStatus.classList.toggle('update-available',!!data.updateAvailable);
            downloadUpdateButton.hidden=!data.updateAvailable;
        }catch(e){updateCheckStatus.textContent='Ошибка: '+e.message;}
        finally{this.disabled=false;this.textContent=old;}
    });
    downloadUpdateButton.addEventListener('click',async function(){
        const old=this.textContent;this.disabled=true;this.textContent='Скачиваю…';
        try{
            const r=await fetch('/api/update/download',{method:'POST'});const data=await r.json();
            if(!r.ok)throw new Error(data.error||'Ошибка загрузки обновления');
            await showAppDialog({title:'Обновление загружено',message:'Файл сохранён: '+data.path,kind:'info'});
        }catch(e){await showAppDialog({title:'Ошибка обновления',message:e.message,kind:'error'});}
        finally{this.disabled=false;this.textContent=old;}
    });

    settingsForm.addEventListener('submit',async function(e){
        e.preventDefault();
        settingsError.textContent='';
        document.getElementById('settingsSuccess').textContent='';

        const payload={
            SafeMode:settingSafeMode.checked,
            EnableUpload:settingUpload.checked,
            EnableCleanup:settingCleanup.checked,
            EnableGraylog:settingGraylog.checked,
            MinFileIdleMinutes:Number(document.getElementById('settingIdle').value),
            RetryCount:Number(document.getElementById('settingRetryCount').value),
            RetryDelaySeconds:Number(document.getElementById('settingRetryDelay').value),
            HistoryDays:Number(document.getElementById('settingHistoryDays').value),
            DefaultSizeAnomalyPercent:Number(document.getElementById('settingSizeAnomaly').value),
            AutoRefreshSeconds:Number(document.getElementById('settingAutoRefresh').value),
            AutoSchedulerEnabled:settingAutoScheduler.checked,
            AutoSchedulerIntervalMinutes:Number(settingAutoSchedulerInterval.value||2),
            AutoStartInBackground:settingAutoStartBackground.checked,
            UpdateManifestUrl:settingUpdateManifestUrl.value.trim()
        };

        if(!payload.SafeMode){
            const enabled=[];
            if(payload.EnableUpload)enabled.push('Загрузка на S3');
            if(payload.EnableCleanup)enabled.push('Очистка S3');
            if(payload.EnableGraylog)enabled.push('Graylog');
            if(enabled.length && !await appConfirm('Безопасный режим будет выключен. Разрешить: '+enabled.join(', ')+'?',{title:'Опасные операции',confirmText:'Разрешить',kind:'danger'})){
                return;
            }
        }

        const saveButton=document.getElementById('saveSettings');
        const oldSaveText=saveButton.textContent;
        saveButton.disabled=true;
        saveButton.textContent='Применяю...';

        try{
            const r=await fetchWithTimeout('/api/settings',{
                method:'POST',
                headers:{'Content-Type':'application/json'},
                body:JSON.stringify(payload)
            },12000);

            if(!r.ok){
                let t=await r.text();
                try{t=JSON.parse(t).error||t}catch(_){}
                settingsError.textContent=t;
                return;
            }

            await loadSettings();
            document.getElementById('settingsSuccess').textContent=
                'Настройки сохранены. Автоматическая проверка '+
                (payload.AutoSchedulerEnabled?'запускается каждые '+payload.AutoSchedulerIntervalMinutes+' мин.':'выключена')+'. Автозапуск в фоне '+
                (payload.AutoStartInBackground?'включён.':'выключен.');

            // v21.25: keep the "Проблемы сейчас" scheduler card in sync
            // immediately after settings are saved.
            if(typeof loadSchedulerDisplay==='function'){
                await loadSchedulerDisplay();
            }
        }catch(e){
            settingsError.textContent=
                e.name==='AbortError'
                    ? 'Сохранение настроек не завершилось за 12 секунд.'
                    : e.message;
        }finally{
            saveButton.disabled=false;
            saveButton.textContent=oldSaveText;
        }
    });

    // Отображаем режим сразу после загрузки страницы.
    loadSettings().catch(()=>{});

    // v11: светлая/тёмная тема.
    const themeToggle = document.getElementById('themeToggle');
    const themeLabel = document.getElementById('themeLabel');
    const themeIcon = themeToggle.querySelector('.theme-icon');

    function applyTheme(theme) {
        document.documentElement.setAttribute('data-theme', theme);
        localStorage.setItem('backupS3Theme', theme);

        if (theme === 'light') {
            themeLabel.textContent = 'Тёмная';
            themeIcon.textContent = '☾';
            themeToggle.title = 'Переключить на тёмную тему';
        } else {
            themeLabel.textContent = 'Светлая';
            themeIcon.textContent = '☀';
            themeToggle.title = 'Переключить на светлую тему';
        }
    }

    const storedTheme = localStorage.getItem('backupS3Theme') || 'dark';
    applyTheme(storedTheme);

    themeToggle.addEventListener('click', function () {
        const current = document.documentElement.getAttribute('data-theme') || 'dark';
        applyTheme(current === 'dark' ? 'light' : 'dark');
    });

    // v11: выбор локальной папки через Проводник Windows на сервере.
    const browseFolderButton = document.getElementById('browseFolderButton');
    const jobLocalPathInput = document.getElementById('jobLocalPath');

    browseFolderButton.addEventListener('click', async function () {
        browseFolderButton.disabled = true;
        const oldText = browseFolderButton.textContent;
        browseFolderButton.textContent = 'Открываю...';
        jobFormError.textContent = '';

        try {
            const initialPath = encodeURIComponent(jobLocalPathInput.value.trim());
            const response = await fetch('/api/browse-folder?initialPath=' + initialPath, {
                method: 'GET',
                cache: 'no-store'
            });

            if (!response.ok) {
                let detail = await response.text();
                try {
                    const parsed = JSON.parse(detail);
                    detail = parsed.error || detail;
                } catch (_) {}
                throw new Error(detail);
            }

            const data = await response.json();

            if (!data.cancelled && data.path) {
                jobLocalPathInput.value = data.path;

                // Если имя базы ещё не задано — подставим имя выбранной папки.
                if (!jobName.value.trim()) {
                    const normalized = data.path.replace(/[\\/]+$/, '');
                    const pieces = normalized.split(/[\\/]/);
                    const folderName = pieces[pieces.length - 1] || '';

                    if (folderName) {
                        jobName.value = folderName;
                        if (!jobFilePrefix.dataset.userEdited) {
                            jobFilePrefix.value = folderName + '_backup_';
                        }
                    }
                }
            }
        }
        catch (e) {
            jobFormError.textContent = e.message;
        }
        finally {
            browseFolderButton.disabled = false;
            browseFolderButton.textContent = oldText;
        }
    });


    // v12: просмотр существующих S3-prefix (папок) с возможностью ввести новую.
    const jobBucketInput = document.getElementById('jobBucket');
    const jobAwsProfileInput = document.getElementById('jobAwsProfile');

    function applyBucketDefaults() {
        if (jobBucketInput.value === 'kom1') {
            jobAwsProfileInput.value = 'kom';
        } else if (jobBucketInput.value === 'pw1' && jobAwsProfileInput.value === 'kom') {
            jobAwsProfileInput.value = '';
        }
    }

    jobBucketInput.addEventListener('change', function () {
        applyBucketDefaults();
    });

    const jobS3PathInput = document.getElementById('jobS3Path');
    const loadS3FoldersButton = document.getElementById('loadS3FoldersButton');
    const s3FolderMenu = document.getElementById('s3FolderMenu');
    const s3FolderOptions = document.getElementById('s3FolderOptions');

    let s3FoldersLoadedFor = '';

    function hideS3FolderMenu() {
        s3FolderMenu.hidden = true;
    }

    function renderS3Folders(folders) {
        s3FolderOptions.innerHTML = '';

        if (!folders || folders.length === 0) {
            const empty = document.createElement('div');
            empty.className = 's3-folder-empty';
            empty.textContent = 'Папки не найдены. Можно ввести новое имя.';
            s3FolderOptions.appendChild(empty);
            return;
        }

        folders.forEach(folder => {
            const item = document.createElement('button');
            item.type = 'button';
            item.className = 's3-folder-option';
            item.textContent = folder;
            item.addEventListener('click', function () {
                jobS3PathInput.value = folder;
                hideS3FolderMenu();
            });
            s3FolderOptions.appendChild(item);
        });
    }

    async function loadS3Folders(force) {
        const bucket = jobBucketInput.value.trim();
        const profile = jobAwsProfileInput.value.trim();

        if (!bucket) {
            jobFormError.textContent = 'Сначала укажи Bucket.';
            return;
        }

        const cacheKey = bucket + '|' + profile;
        if (!force && s3FoldersLoadedFor === cacheKey && s3FolderOptions.children.length > 0) {
            s3FolderMenu.hidden = false;
            return;
        }

        jobFormError.textContent = '';
        loadS3FoldersButton.disabled = true;
        loadS3FoldersButton.textContent = '…';

        try {
            const query = new URLSearchParams({
                bucket: bucket,
                profile: profile
            });

            const response = await fetch('/api/s3-folders?' + query.toString(), {
                method: 'GET',
                cache: 'no-store'
            });

            if (!response.ok) {
                let detail = await response.text();
                try {
                    const parsed = JSON.parse(detail);
                    detail = parsed.error || detail;
                } catch (_) {}
                throw new Error(detail);
            }

            const data = await response.json();
            renderS3Folders(data.folders || []);
            s3FoldersLoadedFor = cacheKey;
            s3FolderMenu.hidden = false;
        }
        catch (e) {
            jobFormError.textContent = 'Не удалось получить папки S3: ' + e.message;
            hideS3FolderMenu();
        }
        finally {
            loadS3FoldersButton.disabled = false;
            loadS3FoldersButton.textContent = '⌄';
        }
    }

    loadS3FoldersButton.addEventListener('click', function (event) {
        event.stopPropagation();
        loadS3Folders(true);
    });

    jobS3PathInput.addEventListener('focus', function () {
        loadS3Folders(false);
    });

    document.querySelector('.s3-folder-picker').addEventListener('mouseenter', function () {
        if (s3FoldersLoadedFor) {
            s3FolderMenu.hidden = false;
        }
    });

    jobBucketInput.addEventListener('change', function () {
        s3FoldersLoadedFor = '';
        s3FolderOptions.innerHTML = '';
        hideS3FolderMenu();
    });

    jobAwsProfileInput.addEventListener('change', function () {
        s3FoldersLoadedFor = '';
        s3FolderOptions.innerHTML = '';
        hideS3FolderMenu();
    });

    document.addEventListener('click', function (event) {
        const picker = document.querySelector('.s3-folder-picker');
        if (!picker.contains(event.target)) {
            hideS3FolderMenu();
        }
    });

    // v10: добавление и удаление баз через локальный API.
    const addJobButton = document.getElementById('addJobButton');
    const jobModal = document.getElementById('jobModal');
    const closeJobModal = document.getElementById('closeJobModal');
    const cancelJobModal = document.getElementById('cancelJobModal');
    const addJobForm = document.getElementById('addJobForm');
    const jobName = document.getElementById('jobName');
    const jobFilePrefix = document.getElementById('jobFilePrefix');
    const jobFormError = document.getElementById('jobFormError');

    function openJobModal() {
        jobModal.hidden = false;
        document.body.classList.add('modal-open');
        jobName.focus();
    }

    function closeModal() {
        jobModal.hidden = true;
        document.body.classList.remove('modal-open');
        jobFormError.textContent = '';
    }

    addJobButton.addEventListener('click', openJobModal);
    closeJobModal.addEventListener('click', closeModal);
    cancelJobModal.addEventListener('click', closeModal);

    jobModal.addEventListener('click', function (event) {
        if (event.target === jobModal) closeModal();
    });

    jobName.addEventListener('input', function () {
        if (!jobFilePrefix.dataset.userEdited) {
            jobFilePrefix.value = jobName.value.trim() ? jobName.value.trim() + '_backup_' : '';
        }
    });

    jobFilePrefix.addEventListener('input', function () {
        jobFilePrefix.dataset.userEdited = '1';
    });

    addJobForm.addEventListener('submit', async function (event) {
        event.preventDefault();
        jobFormError.textContent = '';

        const submitButton=document.getElementById('submitAddJob');
        submitButton.disabled=true;
        submitButton.textContent='Добавляю...';

        const payload = {
            Name: document.getElementById('jobName').value.trim(),
            LocalPath: document.getElementById('jobLocalPath').value.trim(),
            Bucket: document.getElementById('jobBucket').value.trim(),
            S3Path: document.getElementById('jobS3Path').value.trim(),
            FilePrefix: document.getElementById('jobFilePrefix').value.trim(),
            AwsProfile: document.getElementById('jobAwsProfile').value.trim(),
            Keep: Number(document.getElementById('jobKeep').value || 2),
            MaxAgeHours: Number(document.getElementById('jobMaxAge').value || 26),
            ExpectedBackupTime: document.getElementById('jobExpectedTime').value || '01:00',
            ExpectedDays: document.getElementById('jobExpectedDays').value || 'Daily',
            GraceMinutes: Number(document.getElementById('jobGraceMinutes').value || 180),
            SizeAnomalyPercent: Number(document.getElementById('jobSizeAnomaly').value || 35)
        };

        try {
            if(!payload.Name)throw new Error('Укажи имя базы.');
            if(!payload.LocalPath)throw new Error('Укажи локальную папку.');
            if(!payload.Bucket)throw new Error('Выбери Bucket.');
            if(!payload.FilePrefix)throw new Error('Укажи префикс файлов.');

            const response = await fetchWithTimeout('/api/jobs/add', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json; charset=utf-8' },
                body: JSON.stringify(payload)
            },8000);

            if (!response.ok) {
                let detail = await response.text();
                try {
                    const parsed = JSON.parse(detail);
                    detail = parsed.error || detail;
                } catch (_) {}
                throw new Error(detail);
            }

            let addResult={};
            try{addResult=await response.json();}catch(_){}

            if(addResult.status==='restored'){
                submitButton.textContent='Восстановлено';
            }

            // Проверяем только что добавленную/восстановленную базу,
            // чтобы её актуальное состояние сразу попало в state.json.
            submitButton.textContent='Проверяю...';

            const check = await fetchWithTimeout('/api/jobs/check', {
                method:'POST',
                headers:{'Content-Type':'application/json; charset=utf-8'},
                body:JSON.stringify({Name:payload.Name})
            },8000);

            if(!check.ok){
                let detail=await check.text();
                try{detail=JSON.parse(detail).error||detail}catch(_){}
                throw new Error('База сохранена, но не удалось запустить первичную проверку: '+detail);
            }

            closeModal();
            // AddJobAsync уже сформировал новый dashboard. Перезагрузка сразу
            // показывает новую строку и событие, а инициализация страницы
            // подхватит продолжающуюся фоновую проверку через /api/progress.
            location.reload();
            return;
        }
        catch (e) {
            jobFormError.textContent = e.message;
        }
        finally{
            submitButton.disabled=false;
            submitButton.textContent='Добавить';
        }
    });





    // v19.1: сворачиваемые секции в редакторе.
    document.querySelectorAll('#editJobModal .section-toggle').forEach(toggle=>{
        toggle.addEventListener('click',function(){
            const section=toggle.closest('.collapsible-section');
            const content=section.querySelector(':scope > .section-content');
            const collapsed=section.classList.toggle('collapsed');

            content.hidden=collapsed;
            toggle.setAttribute('aria-expanded',collapsed?'false':'true');

            const chevron=toggle.querySelector('.section-chevron');
            if(chevron)chevron.textContent=collapsed?'⌄':'⌃';
        });
    });

    // v19.1: автоматический вертикальный скролл окна редактирования.
    // Чем ближе курсор к верхнему/нижнему краю окна — тем быстрее прокрутка.
    const editModalCard=document.querySelector('#editJobModal .modal-card');

    if(editModalCard){
        let modalScrollSpeed=0;
        let modalScrollFrame=null;

        const modalEdgeZone=95;
        const modalMaxSpeed=16;

        function runModalAutoScroll(){
            if(modalScrollSpeed!==0){
                editModalCard.scrollTop+=modalScrollSpeed;
            }
            modalScrollFrame=requestAnimationFrame(runModalAutoScroll);
        }

        editModalCard.addEventListener('mousemove',function(event){
            const rect=editModalCard.getBoundingClientRect();
            const y=event.clientY-rect.top;

            if(y<modalEdgeZone){
                const intensity=Math.max(0,Math.min(1,(modalEdgeZone-y)/modalEdgeZone));
                modalScrollSpeed=-(modalMaxSpeed*intensity);
            }
            else if(y>rect.height-modalEdgeZone){
                const intensity=Math.max(0,Math.min(1,(y-(rect.height-modalEdgeZone))/modalEdgeZone));
                modalScrollSpeed=modalMaxSpeed*intensity;
            }
            else{
                modalScrollSpeed=0;
            }
        });

        editModalCard.addEventListener('mouseenter',function(){
            if(!modalScrollFrame){
                modalScrollFrame=requestAnimationFrame(runModalAutoScroll);
            }
        });

        editModalCard.addEventListener('mouseleave',function(){
            modalScrollSpeed=0;
            if(modalScrollFrame){
                cancelAnimationFrame(modalScrollFrame);
                modalScrollFrame=null;
            }
        });
    }


    // v19.1: локальные backup-файлы и ручная отправка выбранного файла на S3.
    function normalizeLocalFiles(value){
        if(!value)return [];
        return Array.isArray(value)?value:[value];
    }

    function renderEditLocalFiles(databaseName,value){
        const list=document.getElementById('editLocalObjects');
        const files=normalizeLocalFiles(value);
        list.innerHTML='';
        document.getElementById('editLocalCount').textContent=files.length+' файл(ов)';

        if(!files.length){
            list.innerHTML='<div class="muted">Локальные файлы резервных копий не найдены.</div>';
            return;
        }

        files.forEach(file=>{
            const row=document.createElement('div');
            row.className='edit-local-row';

            const info=document.createElement('div');
            info.className='edit-s3-info';

            const name=String(file.Name||'');
            const safeName=name.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');

            info.innerHTML=
                '<strong>'+safeName+'</strong>'+
                '<span>'+fmtBytesClient(file.SizeBytes)+' · '+fmtDateClient(file.LastWriteTime)+'</span>';

            const controls=document.createElement('div');
            controls.className='local-file-actions';

            const state=document.createElement('span');
            state.className=file.OnS3?'local-s3-badge on-s3':'local-s3-badge missing-s3';
            state.textContent=file.OnS3?'На S3':'Нет на S3';

            const upload=document.createElement('button');
            upload.type='button';
            upload.className='manual-upload-button';
            upload.textContent=file.OnS3?'Загрузить снова':'Загрузить на S3';

            upload.addEventListener('click',async function(){
                if(!await appConfirm(
                    'Загрузить эту локальную резервную копию на S3?\n\n'+
                    name+'\n'+fmtBytesClient(file.SizeBytes),
                    {title:'Загрузка на S3',confirmText:'Загрузить'}
                ))return;

                upload.disabled=true;
                upload.textContent='Запускаю...';
                editJobError.textContent='';

                try{
                    const rr=await fetch('/api/jobs/local-upload',{
                        method:'POST',
                        headers:{'Content-Type':'application/json'},
                        body:JSON.stringify({
                            Name:databaseName,
                            FilePath:file.FullName
                        })
                    });

                    if(!rr.ok){
                        let t=await rr.text();
                        try{t=JSON.parse(t).error||t}catch(_){}
                        throw new Error(t);
                    }

                    const started=await rr.json();
                    const operationId=started.operationId || started.id;

                    if(started.safeMode === true || started.enableUpload === false){
                        throw new Error(
                            'Загрузка не разрешена: безопасный режим='+started.safeMode+
                            ', загрузка включена='+started.enableUpload
                        );
                    }
                    if(!operationId){
                        throw new Error('Приложение не вернуло идентификатор операции загрузки');
                    }

                    upload.textContent='0%';

                    const timer=setInterval(async()=>{
                        try{
                            const sr=await fetch(
                                '/api/jobs/local-upload-status?id='+encodeURIComponent(operationId)+'&t='+Date.now(),
                                {cache:'no-store'}
                            );
                            if(!sr.ok)return;

                            const st=await sr.json();
                            const uploaded=Number(st.uploadedBytes||0);
                            const remaining=Number(st.remainingBytes||Math.max(0,Number(st.sizeBytes||0)-uploaded));
                            const speed=st.speedText||'';

                            upload.textContent=
                                (st.percent||0)+'% · '+
                                fmtBytesClient(uploaded)+' / '+fmtBytesClient(Number(st.sizeBytes||0));

                            state.textContent=
                                'Загружено '+fmtBytesClient(uploaded)+
                                ' · осталось '+fmtBytesClient(remaining)+
                                (speed?' · '+speed:'');

                            if(st.status==='FINISHED'){
                                clearInterval(timer);
                                upload.textContent='Готово';
                                state.textContent='На S3';
                                state.className='local-s3-badge on-s3';

                                setTimeout(async()=>{
                                    await refreshEditLocal(databaseName);
                                    await refreshEditS3(databaseName);
                                },700);
                            }
                            else if(st.status==='ERROR'){
                                clearInterval(timer);
                                upload.disabled=false;
                                upload.textContent='Повторить';
                                const detail=st.message||st.error||'Неизвестная ошибка';
                                const log=st.logFile?' · Лог: '+st.logFile:'';
                                editJobError.textContent='Ошибка загрузки: '+detail+log;
                            }
                        }catch(_){}
                    },1000);
                }
                catch(e){
                    upload.disabled=false;
                    upload.textContent='Загрузить на S3';
                    editJobError.textContent=e.message;
                }
            });

            controls.appendChild(state);
            controls.appendChild(upload);
            row.appendChild(info);
            row.appendChild(controls);
            list.appendChild(row);
        });
    }

    async function refreshEditLocal(databaseName){
        const button=document.getElementById('editRefreshLocal');
        const checked=document.getElementById('editLocalCheckedAt');
        const old=button.textContent;

        button.disabled=true;
        button.textContent='Проверяю...';
        editJobError.textContent='';

        try{
            const r=await fetch(
                '/api/jobs/local-files?name='+encodeURIComponent(databaseName)+'&t='+Date.now(),
                {cache:'no-store'}
            );
            if(!r.ok){
                let t=await r.text();
                try{t=JSON.parse(t).error||t}catch(_){}
                throw new Error(t);
            }

            const data=await r.json();
            renderEditLocalFiles(databaseName,data.files);
            const newestLocal=(data.files||[])[0];
            document.getElementById('editLocalFile').textContent=newestLocal?newestLocal.Name:'-';
            document.getElementById('editLastChecked').textContent=fmtDateClient(data.checkedAt);

            checked.textContent=
                'Проверено локально: '+fmtDateClient(data.checkedAt)+
                ' · '+data.localPath+
                ' · назначение: s3://'+data.bucket+'/'+data.s3Path;
        }
        catch(e){
            editJobError.textContent='Ошибка локальной проверки: '+e.message;
            throw e;
        }
        finally{
            button.disabled=false;
            button.textContent=old;
        }
    }

    // v18: редактирование базы и ручное управление S3-объектами.
    const editJobModal=document.getElementById('editJobModal');
    const editJobForm=document.getElementById('editJobForm');
    const editJobError=document.getElementById('editJobError');

    function fmtDateClient(value){
        if(!value)return '-';
        try{return new Date(value).toLocaleString('ru-RU');}catch(_){return value;}
    }

    function fmtBytesClient(bytes){
        const n=Number(bytes||0);
        if(n>=1099511627776)return (n/1099511627776).toFixed(2)+' TB';
        if(n>=1073741824)return (n/1073741824).toFixed(2)+' GB';
        if(n>=1048576)return (n/1048576).toFixed(2)+' MB';
        if(n>=1024)return (n/1024).toFixed(2)+' KB';
        return n+' B';
    }


    let editLastS3Data=null;

    function normalizeS3Objects(value){
        if(!value)return [];
        return Array.isArray(value)?value:[value];
    }

    function renderEditS3Objects(databaseName, value){
        const list=document.getElementById('editS3Objects');
        const objects=normalizeS3Objects(value);

        list.innerHTML='';
        document.getElementById('editS3Count').textContent=objects.length+' объект(ов)';

        if(!objects.length){
            list.innerHTML='<div class="muted">Объекты S3 не найдены.</div>';
            return;
        }

        objects.forEach(obj=>{
            const row=document.createElement('div');
            row.className='edit-s3-row';

            const info=document.createElement('div');
            info.className='edit-s3-info';

            const safeKey=String(obj.Key||'')
                .replace(/&/g,'&amp;')
                .replace(/</g,'&lt;')
                .replace(/>/g,'&gt;');

            info.innerHTML=
                '<strong>'+safeKey+'</strong>'+
                '<span>'+fmtBytesClient(obj.SizeBytes)+' · '+fmtDateClient(obj.LastModified)+'</span>';

            const del=document.createElement('button');
            del.type='button';
            del.className='s3-delete-object';
            del.textContent='Удалить';

            del.addEventListener('click',async function(){
                if(!await appConfirm(
                    'Удалить объект S3?\n\n'+String(obj.Key||'')+
                    '\n\nОперация необратима.',
                    {title:'Удаление объекта S3',confirmText:'Удалить',kind:'danger'}
                ))return;

                del.disabled=true;

                try{
                    const rr=await fetch('/api/s3/object/delete',{
                        method:'POST',
                        headers:{'Content-Type':'application/json'},
                        body:JSON.stringify({
                            Name:databaseName,
                            Key:obj.Key
                        })
                    });

                    if(!rr.ok){
                        let t=await rr.text();
                        try{t=JSON.parse(t).error||t}catch(_){}
                        throw new Error(t);
                    }

                    await refreshEditS3(databaseName);
                }
                catch(e){
                    del.disabled=false;
                    editJobError.textContent=e.message;
                }
            });

            row.appendChild(info);
            row.appendChild(del);
            list.appendChild(row);
        });
    }

    async function refreshEditS3(databaseName){
        const button=document.getElementById('editRefreshS3');
        const checked=document.getElementById('editS3CheckedAt');
        const oldText=button.textContent;

        button.disabled=true;
        button.textContent='Проверяю...';
        editJobError.textContent='';

        try{
            const r=await fetch(
                '/api/jobs/s3-objects?name='+encodeURIComponent(databaseName)+'&t='+Date.now(),
                {cache:'no-store'}
            );

            if(!r.ok){
                let t=await r.text();
                try{t=JSON.parse(t).error||t}catch(_){}
                throw new Error(t);
            }

            const data=await r.json();
            editLastS3Data=data;

            renderEditS3Objects(databaseName, data.objects);
            const newestS3=normalizeS3Objects(data.objects)[0];
            document.getElementById('editS3Latest').textContent=newestS3?newestS3.Key:'-';
            document.getElementById('editLastChecked').textContent=fmtDateClient(data.checkedAt);

            // Update the main table and global metric immediately. The API has
            // already persisted the same live values into state.json.
            const dbRow=Array.from(document.querySelectorAll('.db-row')).find(row=>row.dataset.db===databaseName);
            if(dbRow){
                const nameCell=dbRow.querySelector('.db-name');
                const oldCount=Number(nameCell&&nameCell.dataset.s3Count||0);
                const newCount=Number(data.count||0);
                if(nameCell)nameCell.dataset.s3Count=String(newCount);
                const summary=dbRow.querySelector('.row-s3-summary');
                if(summary)summary.textContent=newCount+' объект(ов)';
                const totalBytes=normalizeS3Objects(data.objects).reduce((sum,item)=>sum+Number(item.SizeBytes||0),0);
                const bytesCell=dbRow.querySelector('.row-s3-bytes');if(bytesCell)bytesCell.textContent=fmtBytesClient(totalBytes);
                const latestCell=dbRow.querySelector('.row-s3-latest');if(latestCell)latestCell.textContent=newestS3?fmtDateClient(newestS3.LastModified):'-';
                const total=document.getElementById('dashboardS3ObjectCount');if(total)total.textContent=String(Math.max(0,Number(total.textContent||0)-oldCount+newCount));
            }

            const keep=Number(document.getElementById('editKeep').value||0);
            const excess=Math.max(0,Number(data.count||0)-keep);

            checked.textContent=
                'Проверено напрямую в S3: '+fmtDateClient(data.checkedAt)+
                ' · s3://'+data.bucket+'/'+data.s3Path+
                ' · префикс: '+data.prefix+
                (excess>0?' · лишних: '+excess:'');

            const cleanupButton=document.getElementById('editDeleteExtras');
            if(cleanupButton){
                cleanupButton.disabled=excess<=0;
                cleanupButton.textContent=excess>0
                    ? 'Удалить лишние ('+excess+')'
                    : 'Лишних нет';
            }

            return data;
        }
        catch(e){
            editJobError.textContent='Ошибка проверки S3: '+e.message;
            throw e;
        }
        finally{
            button.disabled=false;
            button.textContent=oldText;
        }
    }


    document.getElementById('editDeleteExtras').addEventListener('click',async function(){
        const name=document.getElementById('editJobName').value;
        const keep=Number(document.getElementById('editKeep').value||0);
        const currentCount=editLastS3Data?Number(editLastS3Data.count||0):0;
        const excess=Math.max(0,currentCount-keep);

        if(excess<=0){
            editJobError.textContent='Лишних файлов на S3 нет.';
            return;
        }

        if(!await appConfirm(
            'Удалить '+excess+' старых резервных копий на S3?\n\n'+
            'Будут сохранены '+keep+' самых новых объектов по этому префиксу.\n'+
            'Последняя резервная копия защищена от удаления.',
            {title:'Очистка S3',confirmText:'Удалить старые',kind:'danger'}
        ))return;

        const button=this;
        const oldText=button.textContent;
        button.disabled=true;
        button.textContent='Удаляю...';
        editJobError.textContent='';

        try{
            // First refresh the state for this single DB so RetentionCandidates
            // exactly match the current S3 inventory and current Keep.
            const check=await fetch('/api/jobs/check',{
                method:'POST',
                headers:{'Content-Type':'application/json'},
                body:JSON.stringify({Name:name})
            });

            if(!check.ok){
                let t=await check.text();
                try{t=JSON.parse(t).error||t}catch(_){}
                throw new Error(t);
            }

            // Controller is asynchronous. Wait briefly for the single-db run
            // to finish before applying retention.
            const started=Date.now();
            while(Date.now()-started<15000){
                await new Promise(resolve=>setTimeout(resolve,350));
                const pr=await fetch('/api/progress?t='+Date.now(),{cache:'no-store'});
                if(pr.ok){
                    const pd=await pr.json();
                    if(!pd.running)break;
                }
            }

            const rr=await fetch('/api/retention/apply',{
                method:'POST',
                headers:{'Content-Type':'application/json'},
                body:JSON.stringify({Name:name})
            });

            if(!rr.ok){
                let t=await rr.text();
                try{t=JSON.parse(t).error||t}catch(_){}
                throw new Error(t);
            }

            const result=await rr.json();
            editJobError.textContent=
                'Удалено старых резервных копий: '+((result.deleted||[]).length);

            await refreshEditS3(name);
        }catch(e){
            editJobError.textContent='Ошибка удаления лишних: '+e.message;
        }finally{
            button.disabled=false;
            if(button.textContent==='Удаляю...')button.textContent=oldText;
        }
    });


    function setAccentPalette(value){
        const accent=value||'default';
        const input=document.getElementById('editAccent');
        if(input)input.value=accent;

        document.querySelectorAll('#accentPalette .accent-swatch').forEach(btn=>{
            const selected=btn.dataset.accent===accent;
            btn.classList.toggle('selected',selected);
            btn.setAttribute('aria-checked',selected?'true':'false');
        });
    }

    document.querySelectorAll('#accentPalette .accent-swatch').forEach(btn=>{
        btn.addEventListener('click',()=>{
            setAccentPalette(btn.dataset.accent);
        });
    });

    async function openEditJob(name){
        editJobError.textContent='';
        const r=await fetch('/api/jobs/detail?name='+encodeURIComponent(name)+'&t='+Date.now(),{cache:'no-store'});
        if(!r.ok)throw new Error(await r.text());
        const d=await r.json();

        document.getElementById('editJobTitle').textContent=d.Name;
        document.getElementById('editJobName').value=d.Name;
        document.getElementById('editLocalPath').value=d.LocalPath||'';
        document.getElementById('editBucket').value=d.Bucket||'pw1';
        document.getElementById('editS3Path').value=d.S3Path||'';
        document.getElementById('editFilePrefix').value=d.FilePrefix||'';
        document.getElementById('editAwsProfile').value=d.AwsProfile||'';
        document.getElementById('editKeep').value=d.Keep||2;
        document.getElementById('editExpectedTime').value=d.ExpectedBackupTime||'';
        document.getElementById('editExpectedDays').value=d.ExpectedDays||'Daily';
        document.getElementById('editGraceMinutes').value=d.GraceMinutes||180;
        document.getElementById('editMaxAgeHours').value=d.MaxAgeHours||30;
        document.getElementById('editSizeAnomaly').value=d.SizeAnomalyPercent||35;
        document.getElementById('editEnabled').checked=!!d.Enabled;

        // UI customization is stored separately from backup settings.
        try{
            const ur=await fetch('/api/ui-settings?t='+Date.now(),{cache:'no-store'});
            const ui=ur.ok?await ur.json():{Jobs:{}};
            const item=(ui.Jobs&&ui.Jobs[d.Name])||{};
            document.getElementById('editAlias').value=item.Alias||'';
            document.getElementById('editGroup').value=item.Group||'';
            document.getElementById('editPriority').value=item.Priority||'Normal';
            setAccentPalette(item.Accent||'default');
            document.getElementById('editPinned').checked=!!item.Pinned;
            document.getElementById('editNote').value=item.Note||'';
        }catch(_){
            document.getElementById('editPriority').value='Normal';
            setAccentPalette('default');
        }

        document.getElementById('editLocalFile').textContent=d.LocalFile||'-';
        document.getElementById('editS3Latest').textContent=((normalizeS3Objects(d.S3Objects)[0]||{}).Key)||'-';
        document.getElementById('editSyncStatus').textContent=syncStatusLabel(d.SyncStatus||'');
        document.getElementById('editLastChecked').textContent=fmtDateClient(d.LastChecked);

        renderEditS3Objects(d.Name, d.S3Objects);


        document.getElementById('editS3CheckedAt').textContent=
            'Показаны данные последней общей проверки. Выполняю прямую проверку S3...';

        editJobModal.hidden=false;
        document.body.classList.add('modal-open');

        // Обновляем данные непосредственно из Local и S3.
        refreshEditLocal(d.Name).catch(()=>{});
        refreshEditS3(d.Name).catch(()=>{});
    }

    function closeEditJob(){
        editJobModal.hidden=true;
        document.body.classList.remove('modal-open');
        editJobError.textContent='';
    }

    document.getElementById('closeEditJobModal').addEventListener('click',closeEditJob);
    document.getElementById('cancelEditJob').addEventListener('click',closeEditJob);

    document.querySelectorAll('.edit-job').forEach(button=>{
        button.addEventListener('click',async function(e){
            e.stopPropagation();
            try{await openEditJob(button.dataset.job);}
            catch(err){alert('Не удалось открыть редактирование: '+err.message);}
        });
    });


    document.getElementById('editRefreshLocal').addEventListener('click',async function(){
        const name=document.getElementById('editJobName').value;
        if(name)refreshEditLocal(name).catch(()=>{});
    });

    document.getElementById('editRefreshS3').addEventListener('click',async function(){
        const name=document.getElementById('editJobName').value;
        if(name)refreshEditS3(name).catch(()=>{});
    });

    document.getElementById('editBrowseFolder').addEventListener('click',async function(){
        const input=document.getElementById('editLocalPath');
        const r=await fetch('/api/browse-folder?initialPath='+encodeURIComponent(input.value.trim()),{cache:'no-store'});
        if(!r.ok){editJobError.textContent=await r.text();return;}
        const d=await r.json();
        if(!d.cancelled && d.path)input.value=d.path;
    });

    document.getElementById('editBucket').addEventListener('change',function(){
        const profile=document.getElementById('editAwsProfile');
        if(this.value==='kom1')profile.value='kom';
        else if(profile.value==='kom')profile.value='';
    });

    editJobForm.addEventListener('submit',async function(e){
        e.preventDefault();
        editJobError.textContent='';

        const payload={
            Name:document.getElementById('editJobName').value,
            LocalPath:document.getElementById('editLocalPath').value.trim(),
            Bucket:document.getElementById('editBucket').value,
            S3Path:document.getElementById('editS3Path').value.trim(),
            FilePrefix:document.getElementById('editFilePrefix').value.trim(),
            AwsProfile:document.getElementById('editAwsProfile').value.trim(),
            Keep:Number(document.getElementById('editKeep').value),
            ExpectedBackupTime:document.getElementById('editExpectedTime').value,
            ExpectedDays:document.getElementById('editExpectedDays').value,
            GraceMinutes:Number(document.getElementById('editGraceMinutes').value),
            MaxAgeHours:Number(document.getElementById('editMaxAgeHours').value),
            SizeAnomalyPercent:Number(document.getElementById('editSizeAnomaly').value),
            Enabled:document.getElementById('editEnabled').checked
        };

        const r=await fetch('/api/jobs/update',{
            method:'POST',
            headers:{'Content-Type':'application/json'},
            body:JSON.stringify(payload)
        });

        if(!r.ok){
            let t=await r.text();
            try{t=JSON.parse(t).error||t}catch(_){}
            editJobError.textContent=t;
            return;
        }

        const uiPayload={
            Name:payload.Name,
            Alias:document.getElementById('editAlias').value.trim(),
            Group:document.getElementById('editGroup').value.trim(),
            Priority:document.getElementById('editPriority').value,
            Accent:document.getElementById('editAccent').value,
            Pinned:document.getElementById('editPinned').checked,
            Note:document.getElementById('editNote').value.trim()
        };

        const ur=await fetch('/api/ui-settings/job',{
            method:'POST',
            headers:{'Content-Type':'application/json'},
            body:JSON.stringify(uiPayload)
        });

        if(!ur.ok){
            let t=await ur.text();
            try{t=JSON.parse(t).error||t}catch(_){}
            editJobError.textContent='Backup-настройки сохранены, но кастомизация не сохранена: '+t;
            return;
        }

        closeEditJob();
        await fetch('/api/jobs/check',{
            method:'POST',
            headers:{'Content-Type':'application/json'},
            body:JSON.stringify({Name:payload.Name})
        });
        setTimeout(()=>location.reload(),1800);
    });

    // v16: maintenance mode.
    document.querySelectorAll('.maintenance-job').forEach(button => {
        button.addEventListener('click', async function(e){
            e.stopPropagation();
            const name=button.dataset.job;
            const active=button.dataset.active==='1';
            const url=active?'/api/maintenance/clear':'/api/maintenance/set';
            const payload=active?{Name:name}:{Name:name,Hours:2,Reason:'Maintenance from dashboard'};
            const r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
            if(!r.ok){alert(await r.text());return;}
            await fetch('/api/jobs/check',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:name})});
            setTimeout(()=>location.reload(),1800);
        });
    });

    // v16: safe retention preview.
    const retentionModal=document.getElementById('retentionModal');
    const retentionBody=document.getElementById('retentionBody');
    const retentionSubtitle=document.getElementById('retentionSubtitle');
    const applyRetention=document.getElementById('applyRetention');
    let retentionJob='';
    function closeRetention(){retentionModal.hidden=true;retentionJob='';}
    document.getElementById('closeRetentionModal').addEventListener('click',closeRetention);
    document.getElementById('cancelRetentionModal').addEventListener('click',closeRetention);

    document.querySelectorAll('.retention-job').forEach(button=>{
        button.addEventListener('click',async function(e){
            e.stopPropagation();retentionJob=button.dataset.job;
            const r=await fetch('/api/retention/preview',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:retentionJob})});
            if(!r.ok){alert(await r.text());return;}
            const d=await r.json();retentionSubtitle.textContent=retentionJob+' — оставить '+d.keep+' файла';
            retentionBody.innerHTML='';
            if(!d.candidates.length){retentionBody.innerHTML='<div class="good-line">Удалять нечего.</div>';}
            else{
                const ul=document.createElement('div');ul.className='retention-list';
                d.candidates.forEach(c=>{const row=document.createElement('div');row.textContent=c.Key;ul.appendChild(row);});
                retentionBody.appendChild(ul);
            }
            applyRetention.disabled=!d.enabled || !d.candidates.length;
            applyRetention.textContent=d.enabled?'Удалить лишние вручную':'SafeMode блокирует удаление';
            retentionModal.hidden=false;
        });
    });
    applyRetention.addEventListener('click',async function(){
        if(!retentionJob || !await appConfirm('Удалить показанные старые объекты S3?',{title:'Применить retention',confirmText:'Удалить',kind:'danger'}))return;
        const r=await fetch('/api/retention/apply',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:retentionJob})});
        if(!r.ok){alert(await r.text());return;}
        closeRetention();await fetch('/api/jobs/check',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({Name:retentionJob})});setTimeout(()=>location.reload(),1800);
    });

    // v15: проверка только выбранной базы.
    document.querySelectorAll('.check-job').forEach(button => {
        button.addEventListener('click', async function (event) {
            event.stopPropagation();

            const name = button.dataset.job;
            const oldText = button.textContent;

            button.disabled = true;
            button.textContent = '...';

            try {
                const response = await fetch('/api/jobs/check', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ Name: name })
                });

                if (!response.ok) {
                    throw new Error(await response.text());
                }

                refreshButton.disabled = true;
                lastWasRunning = true;

                progressTitle.textContent = 'Проверка базы';
                progressDatabase.textContent = '· ' + name;
                progressPercent.textContent = '0%';
                progressBar.style.width = '0%';
                progressMessage.textContent = 'Проверяется только ' + name;
                progressCounter.textContent = '0 / 1';
                progressPanel.classList.add('running');
                progressPanel.classList.remove('finished');

                if (progressTimer) clearInterval(progressTimer);
                progressTimer = setInterval(pollProgress, 700);
                await pollProgress();
            }
            catch (e) {
                button.disabled = false;
                button.textContent = oldText;
                alert('Ошибка проверки ' + name + ': ' + e.message);
            }
        });
    });

    document.querySelectorAll('.delete-job').forEach(button => {
        button.addEventListener('click', async function (event) {
            event.stopPropagation();
            const name = button.dataset.job;

            if (!await appConfirm('Удалить базу "' + name + '" из BackupS3?\n\nЛокальные файлы и объекты S3 удалены НЕ будут.',{title:'Удаление базы из списка',confirmText:'Удалить',kind:'danger'})) {
                return;
            }

            button.disabled = true;

            try {
                const response = await fetch('/api/jobs/delete', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ Name: name })
                });

                if (!response.ok) {
                    throw new Error(await response.text());
                }

                location.reload();
            }
            catch (e) {
                button.disabled = false;
                alert('Ошибка удаления: ' + e.message);
            }
        });
    });


    // v15: фиксированная верхняя строка таблицы при прокрутке страницы.
    // Используем отдельную копию thead, потому что overflow-x у основной
    // таблицы мешает обычному CSS position: sticky во многих браузерах.
    const jobsTable = document.getElementById('jobs');
    const tableViewport = document.querySelector('.table-wrap');
    const floatingHeader = document.getElementById('floatingHeader');
    const floatingHeaderInner = document.getElementById('floatingHeaderInner');

    let floatingTable = null;

    const backToTopButton=document.getElementById('backToTopButton');
    function updateBackToTop(){backToTopButton.hidden=window.scrollY<500;}
    backToTopButton.addEventListener('click',function(){window.scrollTo({top:0,behavior:'smooth'});});
    window.addEventListener('scroll',updateBackToTop,{passive:true});
    updateBackToTop();

    function buildFloatingHeader() {
        if (!jobsTable || !jobsTable.tHead) return;

        floatingHeaderInner.innerHTML = '';

        floatingTable = document.createElement('table');
        floatingTable.className = 'floating-header-table';

        const clonedHead = jobsTable.tHead.cloneNode(true);
        floatingTable.appendChild(clonedHead);
        floatingHeaderInner.appendChild(floatingTable);

        syncFloatingHeader();
    }

    function syncFloatingHeader() {
        if (!jobsTable || !tableViewport || !floatingTable) return;

        const sourceHeaders = Array.from(jobsTable.tHead.rows[0].cells);
        const cloneHeaders = Array.from(floatingTable.tHead.rows[0].cells);

        const tableRect = jobsTable.getBoundingClientRect();
        const wrapRect = tableViewport.getBoundingClientRect();
        const headerHeight = jobsTable.tHead.getBoundingClientRect().height;

        // Показываем копию только когда настоящий заголовок уже ушёл вверх,
        // а сама таблица ещё остаётся на экране.
        const shouldShow =
            tableRect.top < 0 &&
            tableRect.bottom > headerHeight;

        floatingHeader.hidden = !shouldShow;

        if (!shouldShow) return;

        floatingHeader.style.left = wrapRect.left + 'px';
        floatingHeader.style.width = wrapRect.width + 'px';
        floatingHeader.style.top = '0px';
        floatingHeader.style.height = headerHeight + 'px';

        floatingTable.style.width = jobsTable.scrollWidth + 'px';
        floatingTable.style.transform =
            'translateX(' + (-tableViewport.scrollLeft) + 'px)';

        sourceHeaders.forEach((cell, index) => {
            if (!cloneHeaders[index]) return;
            const width = cell.getBoundingClientRect().width;
            cloneHeaders[index].style.width = width + 'px';
            cloneHeaders[index].style.minWidth = width + 'px';
            cloneHeaders[index].style.maxWidth = width + 'px';
        });

        // Компенсируем горизонтальную прокрутку первой колонки "База",
        // чтобы она оставалась слева и в плавающем заголовке.
        if (cloneHeaders[0]) {
            cloneHeaders[0].style.transform =
                'translateX(' + tableViewport.scrollLeft + 'px)';
        }
    }

    buildFloatingHeader();
    window.addEventListener('scroll', syncFloatingHeader, { passive: true });
    window.addEventListener('resize', function () {
        buildFloatingHeader();
        syncFloatingHeader();
    });

    if (tableViewport) {
        tableViewport.addEventListener('scroll', syncFloatingHeader, { passive: true });
    }

    // v7: автоматическая горизонтальная прокрутка у краёв таблицы.
    const tableWrap = document.querySelector('.table-wrap');

    if (tableWrap) {
        let horizontalSpeed = 0;
        let horizontalAnimation = null;
        const edgeZone = 150;
        const maxSpeed = 20;

        function autoHorizontalScroll() {
            if (horizontalSpeed !== 0) {
                tableWrap.scrollLeft += horizontalSpeed;
            }
            horizontalAnimation = requestAnimationFrame(autoHorizontalScroll);
        }

        tableWrap.addEventListener('mousemove', function (event) {
            const rect = tableWrap.getBoundingClientRect();
            const x = event.clientX - rect.left;

            if (x < edgeZone) {
                const intensity = Math.max(0, Math.min(1, (edgeZone - x) / edgeZone));
                horizontalSpeed = -(maxSpeed * intensity);
            }
            else if (x > rect.width - edgeZone) {
                const intensity = Math.max(0, Math.min(1, (x - (rect.width - edgeZone)) / edgeZone));
                horizontalSpeed = maxSpeed * intensity;
            }
            else {
                horizontalSpeed = 0;
            }
        });

        tableWrap.addEventListener('mouseenter', function () {
            if (!horizontalAnimation) {
                horizontalAnimation = requestAnimationFrame(autoHorizontalScroll);
            }
        });

        tableWrap.addEventListener('mouseleave', function () {
            horizontalSpeed = 0;
            if (horizontalAnimation) {
                cancelAnimationFrame(horizontalAnimation);
                horizontalAnimation = null;
            }
        });
    }

})();
</script>
</body>
</html>
"@

$outputDir = Split-Path $outputFile -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

Set-Content -Path $outputFile -Value $html -Encoding UTF8
