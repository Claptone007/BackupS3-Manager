param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "BackupJobs.psd1"),
    [string]$JobName = "",
    [string]$JobNamesCsv = "",
    [switch]$ScheduledRun
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""


function Get-RuntimeSettings {
    param($Config)

    $defaults = [ordered]@{
        SafeMode                  = $true
        EnableUpload              = [bool]$Config.Global.EnableUpload
        EnableCleanup             = [bool]$Config.Global.EnableCleanup
        EnableGraylog             = [bool]$Config.Global.EnableGraylog
        MinFileIdleMinutes        = [int]$Config.Global.MinFileIdleMinutes
        RetryCount                = [int]$Config.Global.RetryCount
        RetryDelaySeconds         = [int]$Config.Global.RetryDelaySeconds
        HistoryDays               = if($Config.Global.HistoryDays){[int]$Config.Global.HistoryDays}else{30}
        DefaultSizeAnomalyPercent = if($Config.Global.DefaultSizeAnomalyPercent){[int]$Config.Global.DefaultSizeAnomalyPercent}else{[double]$script:RuntimeSettings.DefaultSizeAnomalyPercent}
        AutoRefreshSeconds        = 60
    }

    if(Test-Path $script:SettingsFile){
        try{
            $saved=Get-Content $script:SettingsFile -Raw -Encoding UTF8|ConvertFrom-Json
            foreach($p in $saved.PSObject.Properties){
                if($defaults.Contains($p.Name)){$defaults[$p.Name]=$p.Value}
            }
        }catch{
            Write-Log WARN "settings.json cannot be read: $($_.Exception.Message)"
        }
    }

    # SafeMode имеет приоритет над опасными переключателями.
    if([bool]$defaults.SafeMode){
        $defaults.EnableUpload=$false
        $defaults.EnableCleanup=$false
        $defaults.EnableGraylog=$false
    }

    return [PSCustomObject]$defaults
}

function Resolve-LocalConfigPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $PSScriptRoot $Path)
}

function Write-Log {
    param([ValidateSet("INFO","WARN","ERROR")][string]$Level="INFO",[string]$Message)
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$Level,$Message
    Write-Host $line
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
}

function Test-CancelRequested {
    return (Test-Path $script:CancelFile -PathType Leaf)
}


function Convert-TransferUnitToBytes {
    param([double]$Value,[string]$Unit)

    switch($Unit){
        "Bytes" { return [Int64][math]::Round($Value) }
        "B"     { return [Int64][math]::Round($Value) }
        "KiB"   { return [Int64][math]::Round($Value*1KB) }
        "MiB"   { return [Int64][math]::Round($Value*1MB) }
        "GiB"   { return [Int64][math]::Round($Value*1GB) }
        "TiB"   { return [Int64][math]::Round($Value*1TB) }
        default { return 0 }
    }
}

function Get-UploadProgressPath {
    param([string]$Database)

    $safe=($Database -replace '[^A-Za-z0-9_.-]','_')
    if([string]::IsNullOrWhiteSpace($safe)){$safe="unknown"}
    return (Join-Path $script:UploadProgressDir ($safe+".json"))
}

function Write-DatabaseUploadProgress {
    param(
        [string]$Database,
        [string]$FileName,
        [Int64]$TotalBytes,
        [Int64]$UploadedBytes,
        [string]$Status,
        [string]$Destination="",
        [string]$SpeedText="",
        [string]$Message=""
    )

    if([string]::IsNullOrWhiteSpace($Database)){return}

    $UploadedBytes=[Math]::Max([Int64]0,[Math]::Min($TotalBytes,$UploadedBytes))
    $remaining=[Math]::Max([Int64]0,$TotalBytes-$UploadedBytes)
    $percent=if($TotalBytes -gt 0){
        [math]::Round(($UploadedBytes/[double]$TotalBytes)*100,1)
    }else{0}

    if($Status -eq "FINISHED"){
        $UploadedBytes=$TotalBytes
        $remaining=0
        $percent=100
    }

    $obj=[ordered]@{
        database=$Database
        file=$FileName
        status=$Status
        percent=$percent
        totalBytes=$TotalBytes
        uploadedBytes=$UploadedBytes
        remainingBytes=$remaining
        destination=$Destination
        speedText=$SpeedText
        message=$Message
        updatedAt=(Get-Date).ToString("o")
    }

    try{
        $path=Get-UploadProgressPath $Database
        $tmp="$path.tmp"
        $obj|ConvertTo-Json -Depth 5|Set-Content $tmp -Encoding UTF8
        Move-Item $tmp $path -Force
    }catch{}
}

function Get-AwsTransferProgressFromText {
    param([string]$Text,[Int64]$ExpectedTotalBytes)

    if([string]::IsNullOrWhiteSpace($Text)){return $null}

    # AWS CLI v2 high-level s3 progress:
    # Completed 12.5 MiB/433.2 MiB (8.1 MiB/s) with 1 file(s) remaining
    $matches=[regex]::Matches(
        $Text,
        'Completed\s+([0-9]+(?:[\.,][0-9]+)?)\s*(Bytes|B|KiB|MiB|GiB|TiB)\s*/\s*([0-9]+(?:[\.,][0-9]+)?)\s*(Bytes|B|KiB|MiB|GiB|TiB)\s*\(([^)]*)\)',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if($matches.Count -eq 0){return $null}

    $m=$matches[$matches.Count-1]
    $current=[double](($m.Groups[1].Value -replace ',','.'))
    $currentUnit=$m.Groups[2].Value
    $reportedTotal=[double](($m.Groups[3].Value -replace ',','.'))
    $totalUnit=$m.Groups[4].Value
    $speed=$m.Groups[5].Value

    $uploaded=Convert-TransferUnitToBytes $current $currentUnit
    $reportedTotalBytes=Convert-TransferUnitToBytes $reportedTotal $totalUnit
    $total=if($ExpectedTotalBytes -gt 0){$ExpectedTotalBytes}else{$reportedTotalBytes}

    return [PSCustomObject]@{
        UploadedBytes=[Int64][Math]::Min($total,$uploaded)
        TotalBytes=[Int64]$total
        SpeedText=[string]$speed
    }
}

function Invoke-AwsCli {
    param([string[]]$Arguments,[AllowNull()][string]$Profile)

    if(Test-CancelRequested){ throw "Проверка отменена пользователем" }

    $awsCommand=Get-Command aws -ErrorAction SilentlyContinue
    if($null -eq $awsCommand){
        return [PSCustomObject]@{ExitCode=9009;Output="AWS CLI not found"}
    }

    # Metadata operations should never hang for minutes.
    # Large s3 cp uploads get a much longer timeout.
    $isUpload=($Arguments.Count -ge 2 -and $Arguments[0] -eq "s3" -and $Arguments[1] -eq "cp")

    $effectiveArguments=@($Arguments)
    if($isUpload){
        # --only-show-errors suppresses AWS CLI progress, so remove it.
        # AWS CLI documents --progress-frequency/--progress-multiline for s3 cp.
        $effectiveArguments=@($effectiveArguments|Where-Object{$_ -ne "--only-show-errors"})
        if($effectiveArguments -notcontains "--progress-frequency"){
            $effectiveArguments+=@("--progress-frequency","1")
        }
        if($effectiveArguments -notcontains "--progress-multiline"){
            $effectiveArguments+=@("--progress-multiline")
        }
    }

    $a=@("--endpoint-url",$script:EndpointUrl)
    if(-not[string]::IsNullOrWhiteSpace($Profile)){$a+=@("--profile",$Profile)}
    $a+=$effectiveArguments

    $timeoutSeconds=if($isUpload){7200}else{180}

    $tmpBase=Join-Path ([IO.Path]::GetTempPath()) ("backups3-aws-"+[Guid]::NewGuid().ToString("N"))
    $stdoutFile="$tmpBase.out"
    $stderrFile="$tmpBase.err"

    function Quote-Native([string]$v){
        if($null -eq $v){return '""'}
        if($v -notmatch '[\s"]'){return $v}
        return '"' + ($v.Replace('"','\"')) + '"'
    }

    $argString=(($a|ForEach-Object{Quote-Native ([string]$_)}) -join " ")

    try{
        $p=Start-Process -FilePath $awsCommand.Source -ArgumentList $argString `
            -WorkingDirectory $PSScriptRoot -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

        $sw=[Diagnostics.Stopwatch]::StartNew()
        $lastProgressWrite=[datetime]::MinValue

        if($isUpload -and $null-ne$script:UploadProgressContext){
            Write-DatabaseUploadProgress `
                -Database ([string]$script:UploadProgressContext.Database) `
                -FileName ([string]$script:UploadProgressContext.FileName) `
                -TotalBytes ([Int64]$script:UploadProgressContext.TotalBytes) `
                -UploadedBytes 0 `
                -Status "UPLOADING" `
                -Destination ([string]$script:UploadProgressContext.Destination) `
                -Message "Загрузка началась"
        }

        while(-not $p.HasExited){
            if(Test-CancelRequested){
                try{Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}catch{}
                throw "Проверка отменена пользователем"
            }

            if($sw.Elapsed.TotalSeconds -ge $timeoutSeconds){
                try{Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}catch{}
                return [PSCustomObject]@{
                    ExitCode=408
                    Output="AWS command timeout after $timeoutSeconds sec: aws $($Arguments -join ' ')"
                }
            }

            if(
                $isUpload -and
                $null-ne$script:UploadProgressContext -and
                ((Get-Date)-$lastProgressWrite).TotalMilliseconds -ge 350
            ){
                try{
                    $progressText=""
                    if(Test-Path $stdoutFile){
                        $progressText+=(Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue)
                    }
                    if(Test-Path $stderrFile){
                        $progressText+="`n"+(Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue)
                    }

                    $parsed=Get-AwsTransferProgressFromText `
                        -Text $progressText `
                        -ExpectedTotalBytes ([Int64]$script:UploadProgressContext.TotalBytes)

                    if($null-ne$parsed){
                        Write-DatabaseUploadProgress `
                            -Database ([string]$script:UploadProgressContext.Database) `
                            -FileName ([string]$script:UploadProgressContext.FileName) `
                            -TotalBytes ([Int64]$parsed.TotalBytes) `
                            -UploadedBytes ([Int64]$parsed.UploadedBytes) `
                            -Status "UPLOADING" `
                            -Destination ([string]$script:UploadProgressContext.Destination) `
                            -SpeedText ([string]$parsed.SpeedText) `
                            -Message "Передача на S3"
                    }

                    $lastProgressWrite=Get-Date
                }catch{}
            }

            Start-Sleep -Milliseconds 250
            try{$p.Refresh()}catch{}
        }

        $exit=[int]$p.ExitCode
        $stdout=if(Test-Path $stdoutFile){Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue}else{""}
        $stderr=if(Test-Path $stderrFile){Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue}else{""}
        $parts=@()
        if(-not[string]::IsNullOrWhiteSpace($stdout)){$parts+=$stdout.Trim()}
        if(-not[string]::IsNullOrWhiteSpace($stderr)){$parts+=$stderr.Trim()}

        if($isUpload -and $null-ne$script:UploadProgressContext){
            if($exit -eq 0){
                Write-DatabaseUploadProgress `
                    -Database ([string]$script:UploadProgressContext.Database) `
                    -FileName ([string]$script:UploadProgressContext.FileName) `
                    -TotalBytes ([Int64]$script:UploadProgressContext.TotalBytes) `
                    -UploadedBytes ([Int64]$script:UploadProgressContext.TotalBytes) `
                    -Status "FINISHED" `
                    -Destination ([string]$script:UploadProgressContext.Destination) `
                    -Message "Загрузка завершена"
            }else{
                Write-DatabaseUploadProgress `
                    -Database ([string]$script:UploadProgressContext.Database) `
                    -FileName ([string]$script:UploadProgressContext.FileName) `
                    -TotalBytes ([Int64]$script:UploadProgressContext.TotalBytes) `
                    -UploadedBytes 0 `
                    -Status "ERROR" `
                    -Destination ([string]$script:UploadProgressContext.Destination) `
                    -Message ("AWS exit "+$exit)
            }
        }

        return [PSCustomObject]@{ExitCode=$exit;Output=($parts -join [Environment]::NewLine)}
    }catch{
        if($_.Exception.Message -eq "Проверка отменена пользователем"){throw}
        return [PSCustomObject]@{ExitCode=999;Output=$_.Exception.Message}
    }finally{
        Remove-Item $stdoutFile,$stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-S3Key {
    param([string]$S3Path,[string]$FileName)
    $p=$S3Path.Trim("/")
    if ($p) { return "$p/$FileName" }
    return $FileName
}

# Кэшируем list-objects: ANI и acc читаются только по одному разу за цикл.
$script:S3InventoryCache = @{}
function Get-S3Inventory {
    param($Job)
    $root=$Job.S3Path.Trim("/")
    $cacheKey="{0}|{1}|{2}" -f $Job.Bucket,$root,$Job.AwsProfile
    if ($script:S3InventoryCache.ContainsKey($cacheKey)) { return @($script:S3InventoryCache[$cacheKey]) }

    $prefix = if ($root) { "$root/" } else { "" }
    $r=Invoke-AwsCli -Profile $Job.AwsProfile -Arguments @(
        "s3api","list-objects-v2","--bucket",$Job.Bucket,"--prefix",$prefix,"--output","json"
    )
    if ($r.ExitCode -ne 0) { throw "S3 list failed: $($r.Output)" }

    $objects=@()
    if ($r.Output) {
        $j=$r.Output|ConvertFrom-Json
        if ($null -ne $j.Contents) { $objects=@($j.Contents) }
    }
    $script:S3InventoryCache[$cacheKey]=$objects
    return @($objects)
}

function Get-S3ObjectsForJob {
    param($Job)
    $root=$Job.S3Path.Trim("/")
    $wanted=if($root){"$root/$($Job.FilePrefix)"}else{$Job.FilePrefix}
    return @(
        Get-S3Inventory -Job $Job |
        Where-Object { ([string]$_.Key).StartsWith($wanted,[System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object { [datetime]$_.LastModified } -Descending
    )
}

function Test-S3ObjectExists {
    param($Job,[string]$Key)
    $r=Invoke-AwsCli -Profile $Job.AwsProfile -Arguments @(
        "s3api","head-object","--bucket",$Job.Bucket,"--key",$Key,"--output","json"
    )
    return ($r.ExitCode -eq 0)
}

function Test-FileUnlocked {
    param([string]$Path)
    try {
        $s=[System.IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        $s.Close();$s.Dispose();return $true
    } catch { return $false }
}

function Get-Median {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return 0 }
    $s=@($Values|Sort-Object)
    $n=$s.Count
    if($n%2){ return [double]$s[[int][math]::Floor($n/2)] }
    return ([double]$s[$n/2-1]+[double]$s[$n/2])/2
}

function Test-ExpectedDay {
    param($Job,[datetime]$Date)
    $mode=[string]$Job.ExpectedDays
    if([string]::IsNullOrWhiteSpace($mode) -or $mode -eq "Daily"){return $true}
    if($mode -eq "Weekdays"){return $Date.DayOfWeek -notin @("Saturday","Sunday")}
    if($mode -eq "Weekends"){return $Date.DayOfWeek -in @("Saturday","Sunday")}
    return @($mode.Split(",")|ForEach-Object{$_.Trim()}) -contains [string]$Date.DayOfWeek
}

function Get-LatestExpectedOccurrence {
    param($Job,[datetime]$Now=(Get-Date))
    if ([string]::IsNullOrWhiteSpace([string]$Job.ExpectedBackupTime)) { return $null }
    $parts=([string]$Job.ExpectedBackupTime).Split(":")
    $h=[int]$parts[0];$m=[int]$parts[1]
    for($d=0;$d -le 8;$d++){
        $date=$Now.Date.AddDays(-$d)
        if(-not(Test-ExpectedDay -Job $Job -Date $date)){continue}
        $occ=$date.AddHours($h).AddMinutes($m)
        $deadline=$occ.AddMinutes([int]$Job.GraceMinutes)
        if($deadline -le $Now){ return $occ }
    }
    return $null
}

function Test-ScheduledUploadWindow {
    param($Job,[datetime]$Now=(Get-Date))
    if(-not(Test-ExpectedDay -Job $Job -Date $Now)){return $false}
    if([string]::IsNullOrWhiteSpace([string]$Job.ExpectedBackupTime)){return $false}
    try{
        $parts=([string]$Job.ExpectedBackupTime).Split(":")
        $start=$Now.Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
        $schedulerInterval=if($script:RuntimeSettings.AutoSchedulerIntervalMinutes){[int]$script:RuntimeSettings.AutoSchedulerIntervalMinutes}else{1}
        $grace=[Math]::Max($schedulerInterval,[Math]::Max(1,[int]$Job.GraceMinutes))
        return $Now -ge $start -and $Now -le $start.AddMinutes($grace)
    }catch{return $false}
}

function Read-Maintenance {
    if (-not(Test-Path $script:MaintenanceFile)){return @{}}
    try{
        $j=Get-Content $script:MaintenanceFile -Raw -Encoding UTF8|ConvertFrom-Json
        $h=@{}
        foreach($p in $j.PSObject.Properties){$h[$p.Name]=$p.Value}
        return $h
    }catch{return @{}}
}

function Send-Graylog {
    param([string]$Database,[string]$Status,[string]$Message,[string]$BackupFile="")
    if(-not $script:EnableGraylog){return}
    try{
        $payload=@{
            version="1.1";host=$env:COMPUTERNAME
            short_message="BackupS3: $Database - $Status"
            database=$Database;status=$Status;backup_file=$BackupFile;detail=$Message
        }|ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri $script:GraylogUrl -Method Post -Body $payload -ContentType "application/json" -TimeoutSec 10|Out-Null
    }catch{Write-Log WARN "Graylog error for ${Database}: $($_.Exception.Message)"}
}

function Add-HistoryEvent {
    param([string]$Database,[string]$Event,[string]$Message,[string]$FileName="",[Int64]$SizeBytes=0,[double]$DurationSec=0,[double]$SpeedMBps=0)
    $r=[ordered]@{
        timestamp=(Get-Date).ToString("o");host=$env:COMPUTERNAME;database=$Database
        event=$Event;message=$Message;file=$FileName;sizeBytes=$SizeBytes
        durationSec=$DurationSec;speedMBps=$SpeedMBps
    }
    try{Add-Content -Path $script:HistoryFile -Value ($r|ConvertTo-Json -Compress -Depth 5) -Encoding UTF8}catch{}
}

function Get-PreviousJobState {
    param($OldState,[string]$Name)
    if($null -eq $OldState){return $null}
    return @($OldState.Jobs|Where-Object{$_.Name -eq $Name}|Select-Object -First 1)[0]
}

function Get-EffectiveJobs {
    param($BaseJobs,[string]$ManagedJobsPath)

    $added=@()
    $deleted=@()
    $overrides=@{}

    if(Test-Path $ManagedJobsPath){
        try{
            $m=Get-Content $ManagedJobsPath -Raw -Encoding UTF8|ConvertFrom-Json
            $added=@($m.AddedJobs)
            $deleted=@($m.DeletedNames)

            if($null -ne $m.Overrides){
                foreach($p in $m.Overrides.PSObject.Properties){
                    $overrides[$p.Name]=$p.Value
                }
            }
        }catch{}
    }

    $byName=@{}
    foreach($j in @($BaseJobs)){ if($deleted -notcontains [string]$j.Name){ $byName[[string]$j.Name]=$j } }
    foreach($j in $added){ if($deleted -notcontains [string]$j.Name){ $byName[[string]$j.Name]=$j } }

    $effective=@()

    foreach($job in @($byName.Values)){
        $copy=[ordered]@{}
        if($job -is [System.Collections.IDictionary]){
            foreach($key in $job.Keys){ $copy[$key]=$job[$key] }
        }else{
            foreach($p in $job.PSObject.Properties){$copy[$p.Name]=$p.Value}
        }

        $name=[string]$job.Name
        if($overrides.ContainsKey($name)){
            $ov=$overrides[$name]
            foreach($p in $ov.PSObject.Properties){
                if($p.Name -ne "Name"){ $copy[$p.Name]=$p.Value }
            }
        }

        $effective += [PSCustomObject]$copy
    }

    return @($effective)
}

function Write-ProgressState {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Database="",
        [string]$Phase="CHECKING",
        [string]$Message=""
    )

    $pct=if($Total -gt 0){
        [math]::Min(100,[math]::Round(($Current/$Total)*100))
    }else{0}

    $checked=@()
    if($null-ne$script:ProgressChecked){
        $checked=@($script:ProgressChecked)
    }

    $o=[ordered]@{
        running=($Phase -notin @("FINISHED","CANCELLED","ERROR"))
        current=$Current
        total=$Total
        percent=$pct
        database=$Database
        phase=$Phase
        message=$Message
        checked=$checked
        updatedAt=(Get-Date).ToString("o")
    }

    try{
        $tmp="$($script:ProgressFile).tmp"
        $o|ConvertTo-Json -Depth 6|Set-Content $tmp -Encoding UTF8
        Move-Item $tmp $script:ProgressFile -Force
    }catch{}
}

function New-JobState {
    param($Job)
    [ordered]@{
        Name=$Job.Name;Status="UNKNOWN";StatusText="";ReasonCodes=@();HealthScore=100
        LocalPath=$Job.LocalPath;LocalFile=$null;LocalSizeBytes=0;LocalFileCount=0;LocalTotalBytes=0;LocalObjects=@();LocalLastWrite=$null;AgeHours=$null
        ExpectedBackupTime=$Job.ExpectedBackupTime;ExpectedDays=$Job.ExpectedDays;ExpectedOccurrence=$null;ScheduleDelayMinutes=$null
        Bucket=$Job.Bucket;S3Path=$Job.S3Path;S3Key=$null;S3ObjectCount=0;S3TotalBytes=0;S3Latest=$null;S3Objects=@()
        SyncStatus="UNKNOWN";SizeMatch=$null;SizeAnomalyPercent=$null
        Keep=[int]$Job.Keep;RetentionCandidates=@()
        UploadDurationSec=$null;UploadSpeedMBps=$null
        MaintenanceUntil=$null;RestoreVerifyStatus="DISABLED";RestoreVerifyAt=$null
        LastChecked=(Get-Date).ToString("o")
    }
}

function Invoke-RestoreVerify {
    param($Job,$Latest)
    if(-not [bool]$script:SqlVerify.Enabled -or -not [bool]$Job.VerifyRestore){return [PSCustomObject]@{Status="DISABLED";Message=""}}
    if(-not(Get-Command $script:SqlVerify.SqlcmdPath -ErrorAction SilentlyContinue)){return [PSCustomObject]@{Status="ERROR";Message="sqlcmd not found"}}
    $escaped=$Latest.FullName.Replace("'","''")
    $query="RESTORE VERIFYONLY FROM DISK = N'$escaped'"
    $o=& $script:SqlVerify.SqlcmdPath -S $script:SqlVerify.Server -Q $query -b 2>&1
    if($LASTEXITCODE -eq 0){return [PSCustomObject]@{Status="VERIFIED";Message=($o-join" ")}}
    return [PSCustomObject]@{Status="FAILED";Message=($o-join" ")}
}

if(-not(Test-Path $ConfigPath)){throw "Config not found: $ConfigPath"}
$config=Import-PowerShellDataFile $ConfigPath
$script:EndpointUrl=$config.Global.EndpointUrl
$script:GraylogUrl=$config.Global.GraylogUrl
$script:SqlVerify=$config.Global.SqlVerify
$script:StateFile=Resolve-LocalConfigPath $config.Global.StateFile
$script:ProgressFile=Resolve-LocalConfigPath $config.Global.ProgressFile
$script:HistoryFile=Resolve-LocalConfigPath $config.Global.HistoryFile
$script:LogFile=Resolve-LocalConfigPath $config.Global.LogFile
$script:ManagedJobsFile=Resolve-LocalConfigPath $config.Global.ManagedJobsFile
$script:MaintenanceFile=Resolve-LocalConfigPath $config.Global.MaintenanceFile
$script:SettingsFile=Resolve-LocalConfigPath $config.Global.SettingsFile
$script:ControllerFile=Join-Path $PSScriptRoot "State\controller.json"
$script:CancelFile=Join-Path $PSScriptRoot "State\cancel.flag"
$script:UploadProgressDir=Join-Path $PSScriptRoot "State\UploadProgress"
if(-not(Test-Path $script:UploadProgressDir)){New-Item -ItemType Directory -Path $script:UploadProgressDir -Force|Out-Null}
$script:UploadProgressContext=$null
$script:RuntimeSettings=Get-RuntimeSettings $config
$script:EnableUpload=[bool]$script:RuntimeSettings.EnableUpload
$script:EnableCleanup=[bool]$script:RuntimeSettings.EnableCleanup
$script:EnableGraylog=[bool]$script:RuntimeSettings.EnableGraylog
$dashboard=Resolve-LocalConfigPath $config.Global.Dashboard
$dashboardScript=Join-Path $PSScriptRoot "Generate-Dashboard.ps1"

@($script:StateFile,$script:ProgressFile,$script:HistoryFile,$script:LogFile,$script:ManagedJobsFile,$script:MaintenanceFile,$dashboard)|ForEach-Object{
    $d=Split-Path $_ -Parent;if($d -and -not(Test-Path $d)){New-Item -ItemType Directory -Path $d -Force|Out-Null}
}

Remove-Item $script:CancelFile -Force -ErrorAction SilentlyContinue
$mutex=New-Object Threading.Mutex($false,"Global\BackupS3Controller")
$owned=$false
try{
    try {
        $owned = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $owned = $true
    }
    if(-not $owned){
        Write-Log WARN "Controller launch rejected by mutex: another BackupS3 instance is active."
        exit 75
    }
    if(-not(Get-Command aws -ErrorAction SilentlyContinue)){throw "AWS CLI not found"}

    $requestedNames=@()
    if(-not[string]::IsNullOrWhiteSpace($JobNamesCsv)){
        $requestedNames=@($JobNamesCsv.Split(",")|ForEach-Object{$_.Trim()}|Where-Object{$_})
    }elseif(-not[string]::IsNullOrWhiteSpace($JobName)){
        $requestedNames=@($JobName)
    }

    [ordered]@{
        pid=$PID
        startedAt=(Get-Date).ToString("o")
        requested=@($requestedNames)
    }|ConvertTo-Json -Depth 4|Set-Content $script:ControllerFile -Encoding UTF8

    Write-Log INFO "========== BackupS3 controller started =========="
    $old=$null
    if(Test-Path $script:StateFile){try{$old=Get-Content $script:StateFile -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}

    $effective=Get-EffectiveJobs $config.Jobs $script:ManagedJobsFile
    if($requestedNames.Count){
        $effective=@($effective|Where-Object{$requestedNames -contains [string]$_.Name})
        if($effective.Count -eq 0){throw "Выбранные базы не найдены"}
    }
    # Compatibility: jobs created by older v23.12 builds did not persist
    # Enabled. Missing means enabled; only an explicit false disables a job.
    $enabled=@($effective|Where-Object{$null -eq $_.Enabled -or [bool]$_.Enabled})
    $total=$enabled.Count
    $index=0
    $script:ProgressChecked=New-Object System.Collections.Generic.List[string]
    Write-ProgressState 0 $total "" "STARTING" "Запуск проверки"

    $maintenance=Read-Maintenance
    $newStates=New-Object Collections.Generic.List[object]

    foreach($job in $enabled){
        if(Test-CancelRequested){
            Write-ProgressState $index $total "" "CANCELLED" "Проверка остановлена пользователем"
            Write-Log WARN "Controller cancelled by user"
            break
        }
        $index++
        Write-ProgressState ($index-1) $total $job.Name "CHECKING" "Проверка $($job.Name) ($index из $total)"
        Write-Log INFO "[$($job.Name)] Checking"
        $state=New-JobState $job
        $prev=Get-PreviousJobState $old $job.Name
        try{
            # v23.10: S3 and Local are independent health sources.
            # Always inspect S3 first. Previously a missing local directory threw
            # before S3 was queried, so the main table incorrectly showed
            # "0 objects" even though the Edit dialog's live S3 check could see them.
            $s3=@(Get-S3ObjectsForJob $job)
            $state.S3ObjectCount=$s3.Count
            $state.S3TotalBytes=[Int64](($s3|Measure-Object Size -Sum).Sum)

            if($s3.Count){
                $state.S3Latest=([datetime]$s3[0].LastModified).ToString("o")
                $state.S3Objects=@(
                    $s3|ForEach-Object{
                        [PSCustomObject]@{
                            Key=$_.Key
                            SizeBytes=[Int64]$_.Size
                            LastModified=([datetime]$_.LastModified).ToString("o")
                        }
                    }
                )
            }

            if($s3.Count -gt [int]$job.Keep){
                $state.ReasonCodes+="RETENTION_PENDING"
                $state.RetentionCandidates=@(
                    $s3 |
                    Select-Object -Skip ([int]$job.Keep) |
                    ForEach-Object{
                        [PSCustomObject]@{
                            Key=[string]$_.Key
                            SizeBytes=[Int64]$_.Size
                            LastModified=([datetime]$_.LastModified).ToString("o")
                        }
                    }
                )
            }

            if(-not(Test-Path $job.LocalPath -PathType Container)){
                throw "Локальный каталог недоступен"
            }

            $local=@(Get-ChildItem $job.LocalPath -File|Where-Object{$_.Name.StartsWith([string]$job.FilePrefix,[StringComparison]::OrdinalIgnoreCase)}|Sort-Object LastWriteTime -Descending)
            $state.LocalFileCount=$local.Count
            $state.LocalTotalBytes=[Int64](($local|Measure-Object Length -Sum).Sum)
            $state.LocalObjects=@($local|ForEach-Object{[PSCustomObject]@{Name=$_.Name;FullName=$_.FullName;SizeBytes=[Int64]$_.Length;LastWriteTime=$_.LastWriteTime.ToString("o")}})
            $latest=$local|Select-Object -First 1
            if($null -eq $latest){throw "Backup-файл с prefix '$($job.FilePrefix)' не найден"}

            $age=(Get-Date)-$latest.LastWriteTime
            $state.LocalFile=$latest.Name;$state.LocalSizeBytes=[Int64]$latest.Length;$state.LocalLastWrite=$latest.LastWriteTime.ToString("o");$state.AgeHours=[math]::Round($age.TotalHours,2)

            if([int]$job.MaxAgeHours -gt 0 -and $age.TotalHours -gt [int]$job.MaxAgeHours){
                $state.ReasonCodes+="MAX_AGE_EXCEEDED"
                $state.HealthScore-=35
            }

            # ExpectedBackupTime now means scheduled S3 upload time. It is not
            # used to judge when the external database backup was created.
            $occ=Get-LatestExpectedOccurrence $job
            if($occ){
                $state.ExpectedOccurrence=$occ.ToString("o")
            }

            # size anomaly vs previous local files
            $histCount=if($config.Global.SizeHistoryCount){[int]$config.Global.SizeHistoryCount}else{7}
            $previousSizes=@($local|Select-Object -Skip 1 -First $histCount|ForEach-Object{[double]$_.Length})
            if($previousSizes.Count -ge 2){
                $median=Get-Median $previousSizes
                if($median -gt 0){
                    $dev=[math]::Round((([double]$latest.Length-$median)/$median)*100,1)
                    $state.SizeAnomalyPercent=$dev
                    $threshold=if($job.SizeAnomalyPercent){[double]$job.SizeAnomalyPercent}else{35}
                    if([math]::Abs($dev)-gt $threshold){$state.ReasonCodes+="SIZE_ANOMALY";$state.HealthScore-=20}
                }
            }

            # S3 inventory was already loaded before Local validation.
            $key=Get-S3Key $job.S3Path $latest.Name
            $state.S3Key=$key
            $match=@($s3|Where-Object{$_.Key -ceq $key}|Select-Object -First 1)
            if($match.Count){
                $state.SyncStatus="SYNCED"
                $state.SizeMatch=([Int64]$match[0].Size -eq [Int64]$latest.Length)
                if(-not $state.SizeMatch){
                    $state.ReasonCodes+="SIZE_MISMATCH"
                    $state.HealthScore-=40
                }
            }else{
                $state.SyncStatus="S3_MISSING"
                $state.ReasonCodes+="S3_MISSING"
                $state.HealthScore-=30
            }

            # maintenance
            if($maintenance.ContainsKey([string]$job.Name)){
                try{
                    $until=[datetime]$maintenance[[string]$job.Name].until
                    if($until -gt (Get-Date)){
                        $state.MaintenanceUntil=$until.ToString("o");$state.Status="MAINTENANCE";$state.StatusText="Мониторинг на паузе до $($until.ToString('dd.MM HH:mm'))"
                    }
                }catch{}
            }

            # upload
            if($state.Status -ne "MAINTENANCE" -and $state.SyncStatus -eq "S3_MISSING"){
                if(-not(Test-ScheduledUploadWindow -Job $job)){
                    $state.Status="READY";$state.StatusText="Новый backup найден; ожидается заданное время загрузки на S3"
                }elseif($age.TotalMinutes -lt [double]$script:RuntimeSettings.MinFileIdleMinutes -or -not(Test-FileUnlocked $latest.FullName)){
                    $state.Status="WAITING";$state.StatusText="Backup ещё формируется";$state.ReasonCodes+="WAITING_FILE"
                }elseif(-not $script:EnableUpload){
                    $state.Status="READY";$state.StatusText="Новый backup найден; загрузка отключена (Dry Run)"
                }else{
                    $dest="s3://$($job.Bucket)/$key";$ok=$false;$err=""
                    $script:UploadProgressContext=[PSCustomObject]@{
                        Database=[string]$job.Name
                        FileName=[string]$latest.Name
                        TotalBytes=[Int64]$latest.Length
                        Destination=$dest
                    }
                    $sw=[Diagnostics.Stopwatch]::StartNew()
                    for($attempt=1;$attempt -le [int]$script:RuntimeSettings.RetryCount;$attempt++){
                        if(Test-CancelRequested){throw "Проверка отменена пользователем"}
                        $r=Invoke-AwsCli -Profile $job.AwsProfile -Arguments @("s3","cp",$latest.FullName,$dest)
                        if($r.ExitCode -eq 0 -and (Test-S3ObjectExists $job $key)){$ok=$true;break}
                        $err="AWS exit $($r.ExitCode): $($r.Output)"
                        if($attempt -lt [int]$script:RuntimeSettings.RetryCount){Start-Sleep -Seconds ([int]$script:RuntimeSettings.RetryDelaySeconds*$attempt)}
                    }
                    $sw.Stop()
                    $script:UploadProgressContext=$null
                    $state.UploadDurationSec=[math]::Round($sw.Elapsed.TotalSeconds,1)
                    if($state.UploadDurationSec -gt 0){$state.UploadSpeedMBps=[math]::Round(($latest.Length/1MB)/$state.UploadDurationSec,2)}
                    if(-not $ok){throw "Upload failed: $err"}
                    $state.Status="UPLOADED";$state.StatusText="Backup успешно загружен"
                    $state.SyncStatus="SYNCED";$state.SizeMatch=$true
                    Add-HistoryEvent $job.Name "UPLOAD_SUCCESS" $dest $latest.Name $latest.Length $state.UploadDurationSec $state.UploadSpeedMBps
                    $script:S3InventoryCache.Clear()
                }
            }

            # retention / cleanup
            # Always recalculate from S3 after possible upload. The newest Keep
            # objects are protected; only older matching-prefix objects can be removed.
            if($state.SyncStatus -eq "SYNCED"){
                if($script:S3InventoryCache.Count -gt 0 -and $state.Status -eq "UPLOADED"){
                    $script:S3InventoryCache.Clear()
                }

                $retentionS3=@(Get-S3ObjectsForJob $job)
                $state.S3ObjectCount=$retentionS3.Count
                $state.S3TotalBytes=[Int64](($retentionS3|Measure-Object Size -Sum).Sum)

                if($retentionS3.Count){
                    $state.S3Latest=([datetime]$retentionS3[0].LastModified).ToString("o")
                    $state.S3Objects=@(
                        $retentionS3 |
                        ForEach-Object{
                            [PSCustomObject]@{
                                Key=[string]$_.Key
                                SizeBytes=[Int64]$_.Size
                                LastModified=([datetime]$_.LastModified).ToString("o")
                            }
                        }
                    )
                }

                $retentionCandidates=@(
                    $retentionS3 |
                    Select-Object -Skip ([int]$job.Keep)
                )

                $state.RetentionCandidates=@(
                    $retentionCandidates |
                    ForEach-Object{
                        [PSCustomObject]@{
                            Key=[string]$_.Key
                            SizeBytes=[Int64]$_.Size
                            LastModified=([datetime]$_.LastModified).ToString("o")
                        }
                    }
                )

                if($retentionCandidates.Count -gt 0){
                    if($state.ReasonCodes -notcontains "RETENTION_PENDING"){
                        $state.ReasonCodes+="RETENTION_PENDING"
                    }

                    $autoCleanupAllowed=
                        (-not [bool]$script:RuntimeSettings.SafeMode) -and
                        [bool]$script:EnableCleanup

                    if($autoCleanupAllowed){
                        $deletedCount=0

                        foreach($candidate in $retentionCandidates){
                            $candidateKey=[string]$candidate.Key

                            # Current local->S3 object is never deleted, even if
                            # an unexpected sort/order issue occurs.
                            if($candidateKey -ceq [string]$state.S3Key){
                                continue
                            }

                            if(Test-CancelRequested){
                                throw "Проверка отменена пользователем"
                            }

                            $deleteResult=Invoke-AwsCli `
                                -Profile $job.AwsProfile `
                                -Arguments @(
                                    "s3api",
                                    "delete-object",
                                    "--bucket",[string]$job.Bucket,
                                    "--key",$candidateKey
                                )

                            if($deleteResult.ExitCode -ne 0){
                                throw "Не удалось удалить старый backup S3 '$candidateKey': $($deleteResult.Output)"
                            }

                            $deletedCount++
                            Write-Log INFO "[$($job.Name)] Retention deleted: $candidateKey"
                            Add-HistoryEvent `
                                $job.Name `
                                "RETENTION_DELETE" `
                                "Удалён старый backup по политике хранения" `
                                $candidateKey `
                                ([Int64]$candidate.Size)
                        }

                        $script:S3InventoryCache.Clear()
                        $retentionS3=@(Get-S3ObjectsForJob $job)

                        $state.S3ObjectCount=$retentionS3.Count
                        $state.S3TotalBytes=[Int64](($retentionS3|Measure-Object Size -Sum).Sum)
                        $state.S3Objects=@(
                            $retentionS3 |
                            ForEach-Object{
                                [PSCustomObject]@{
                                    Key=[string]$_.Key
                                    SizeBytes=[Int64]$_.Size
                                    LastModified=([datetime]$_.LastModified).ToString("o")
                                }
                            }
                        )
                        $state.RetentionCandidates=@()

                        $state.ReasonCodes=@(
                            $state.ReasonCodes |
                            Where-Object {$_ -ne "RETENTION_PENDING"}
                        )

                        if($deletedCount -gt 0){
                            Add-HistoryEvent `
                                $job.Name `
                                "RETENTION_CLEANUP" `
                                ("Автоматически удалено старых backup: "+$deletedCount) `
                                $state.LocalFile `
                                $state.LocalSizeBytes
                        }
                    }
                    else{
                        # Retention overflow is an actionable WAITING state.
                        # It must not be hidden behind the previous OK status.
                        $excess=$retentionCandidates.Count

                        if($state.Status -notin @("ERROR","STALE","WARNING","MAINTENANCE")){
                            $state.Status="WAITING"
                            $state.StatusText=
                                "На S3 файлов больше лимита: $($retentionS3.Count), хранить $($job.Keep). " +
                                "Ожидается удаление $excess старых backup"
                        }
                    }
                }
                else{
                    $state.RetentionCandidates=@()
                    $state.ReasonCodes=@(
                        $state.ReasonCodes |
                        Where-Object {$_ -ne "RETENTION_PENDING"}
                    )
                }
            }

            # verify
            $verify=Invoke-RestoreVerify $job $latest
            $state.RestoreVerifyStatus=$verify.Status
            if($verify.Status -in @("VERIFIED","FAILED")){$state.RestoreVerifyAt=(Get-Date).ToString("o")}
            if($verify.Status -eq "FAILED"){$state.ReasonCodes+="VERIFY_FAILED";$state.HealthScore-=40}

            if($state.Status -eq "UNKNOWN"){
                if($state.ReasonCodes -contains "MAX_AGE_EXCEEDED"){$state.Status="STALE";$state.StatusText="Последняя локальная резервная копия старше допустимого возраста"}
                elseif($state.ReasonCodes -contains "SIZE_MISMATCH"){$state.Status="ERROR";$state.StatusText="Размер Local и S3 не совпадает"}
                elseif($state.ReasonCodes -contains "SIZE_ANOMALY"){$state.Status="WARNING";$state.StatusText="Аномальное изменение размера backup"}
                else{$state.Status="OK";$state.StatusText="Local и S3 синхронизированы"}
            }
            $state.HealthScore=[math]::Max(0,[math]::Min(100,$state.HealthScore))

            # History only when new local file first seen
            if($null -eq $prev -or $prev.LocalFile -ne $state.LocalFile){
                Add-HistoryEvent $job.Name "BACKUP_SEEN" "Новый локальный backup" $latest.Name $latest.Length
            }

            # Deduplicated ALERT / RECOVERY
            $problem=@("ERROR","STALE","WARNING","WAITING")
            $prevStatus=if($prev){[string]$prev.Status}else{""}
            if($state.Status -in $problem -and $prevStatus -ne $state.Status){
                Send-Graylog $job.Name "ALERT" "$($state.Status): $($state.StatusText)" $latest.Name
                Add-HistoryEvent $job.Name "ALERT" $state.StatusText $latest.Name $latest.Length
            }elseif($prevStatus -in $problem -and $state.Status -notin $problem){
                Send-Graylog $job.Name "RECOVERY" "Восстановлено: $($state.StatusText)" $latest.Name
                Add-HistoryEvent $job.Name "RECOVERY" $state.StatusText $latest.Name $latest.Length
            }

            $newStates.Add([PSCustomObject]$state)
            Write-Log INFO "[$($job.Name)] $($state.Status), health=$($state.HealthScore), sync=$($state.SyncStatus)"
        }catch{
            $state.Status="ERROR";$state.StatusText=$_.Exception.Message;$state.ReasonCodes+= "ERROR";$state.HealthScore=0
            $newStates.Add([PSCustomObject]$state)
            Write-Log ERROR "[$($job.Name)] $($state.StatusText)"
            if($null -eq $prev -or $prev.Status -ne "ERROR"){
                Send-Graylog $job.Name "ALERT" $state.StatusText $state.LocalFile
                Add-HistoryEvent $job.Name "ERROR" $state.StatusText $state.LocalFile $state.LocalSizeBytes
            }
        }

        if(-not $script:ProgressChecked.Contains([string]$job.Name)){
            $script:ProgressChecked.Add([string]$job.Name)
        }

        Write-ProgressState `
            -Current $index `
            -Total $total `
            -Database ([string]$job.Name) `
            -Phase "CHECKED" `
            -Message ("Проверена "+[string]$job.Name+" ("+$index+" из "+$total+")")
    }

    $wasCancelled=Test-CancelRequested
    $lastChecked=""
    if($script:ProgressChecked.Count -gt 0){
        $lastChecked=[string]$script:ProgressChecked[$script:ProgressChecked.Count-1]
    }

    if($wasCancelled){
        Write-ProgressState `
            -Current $newStates.Count `
            -Total $total `
            -Database $lastChecked `
            -Phase "CANCELLED" `
            -Message ("Проверка остановлена. Проверено "+$newStates.Count+" из "+$total)
    }else{
        Write-ProgressState `
            -Current $total `
            -Total $total `
            -Database $lastChecked `
            -Phase "FINISHED" `
            -Message ("Проверка завершена. Проверено "+$total+" из "+$total)
    }

    # Partial checks preserve all rows not selected.
    $allStates=@()
    if($requestedNames.Count -and $old){
        $allStates=@($old.Jobs|Where-Object{$requestedNames -notcontains [string]$_.Name})
        $allStates+=@($newStates.ToArray())
    }else{$allStates=@($newStates.ToArray())}

    $final=[ordered]@{
        GeneratedAt=(Get-Date).ToString("o");Host=$env:COMPUTERNAME;Endpoint=$script:EndpointUrl
        Mode=[ordered]@{
            SafeMode=[bool]$script:RuntimeSettings.SafeMode
            EnableUpload=[bool]$script:EnableUpload
            EnableCleanup=[bool]$script:EnableCleanup
            EnableGraylog=[bool]$script:EnableGraylog
        }
        Jobs=@($allStates|Sort-Object Name)
    }
    $tmp="$($script:StateFile).tmp";$final|ConvertTo-Json -Depth 12|Set-Content $tmp -Encoding UTF8;Move-Item $tmp $script:StateFile -Force

    if(Test-Path $dashboardScript){& $dashboardScript -ConfigPath $ConfigPath}
    Write-Log INFO "State saved: $($script:StateFile)"
    Write-Log INFO "========== BackupS3 controller finished =========="
}finally{
    if($owned){try{$mutex.ReleaseMutex()}catch{}}
    if($mutex){$mutex.Dispose()}
}
