param(
    [string]$RootPath = $PSScriptRoot,
    [int]$LookbackMinutes = 240
)

$ErrorActionPreference="Stop"

$ConfigPath=Join-Path $RootPath "BackupJobs.psd1"
$ManagedPath=Join-Path $RootPath "State\managed-jobs.json"
$SettingsPath=Join-Path $RootPath "State\settings.json"
$StatePath=Join-Path $RootPath "State\state.json"
$ControllerPath=Join-Path $RootPath "State\controller.json"
$LogPath=Join-Path $RootPath "Logs\auto-scheduler.log"
$BackupScript=Join-Path $RootPath "BackupS3.ps1"
$HealthPath=Join-Path $RootPath "State\auto-scheduler-health.json"
$SchedulerStatePath=Join-Path $RootPath "State\scheduler-state.json"

function Write-AutoLog {
    param([string]$Level,[string]$Message)

    $dir=Split-Path $LogPath -Parent
    if(-not(Test-Path $dir)){
        New-Item -ItemType Directory -Path $dir -Force|Out-Null
    }

    # Prevent unattended installations from growing the scheduler log forever.
    if((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 5MB){
        $archive="$LogPath.1"
        if(Test-Path $archive){Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue}
        Move-Item -LiteralPath $LogPath -Destination $archive -Force
    }

    Add-Content `
        -Path $LogPath `
        -Value ("{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$Level,$Message) `
        -Encoding UTF8
}

function Write-SchedulerHealth {
    param([string]$Status,[string]$Message,[string[]]$Databases=@())
    $payload=[ordered]@{
        checkedAt=(Get-Date).ToString("o")
        status=$Status
        message=$Message
        databases=@($Databases)
        computer=$env:COMPUTERNAME
    }
    $tmp="$HealthPath.tmp"
    $payload|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $HealthPath -Force
}

function Get-Managed {
    if(-not(Test-Path $ManagedPath)){
        return [PSCustomObject]@{
            AddedJobs=@()
            DeletedNames=@()
            Overrides=[PSCustomObject]@{}
        }
    }

    try{
        $x=Get-Content $ManagedPath -Raw -Encoding UTF8|ConvertFrom-Json

        return [PSCustomObject]@{
            AddedJobs=@($x.AddedJobs)
            DeletedNames=@($x.DeletedNames)
            Overrides=if($null-ne$x.Overrides){$x.Overrides}else{[PSCustomObject]@{}}
        }
    }catch{
        Write-AutoLog WARN "managed-jobs.json: $($_.Exception.Message)"
        return [PSCustomObject]@{
            AddedJobs=@()
            DeletedNames=@()
            Overrides=[PSCustomObject]@{}
        }
    }
}

function Merge-Job {
    param($Base,$Override)

    $h=[ordered]@{}

    foreach($p in $Base.PSObject.Properties){
        $h[$p.Name]=$p.Value
    }

    if($Base -is [hashtable]){
        foreach($k in $Base.Keys){
            $h[$k]=$Base[$k]
        }
    }

    if($null-ne$Override){
        foreach($p in $Override.PSObject.Properties){
            $h[$p.Name]=$p.Value
        }
    }

    return [PSCustomObject]$h
}

function Get-EffectiveJobs {
    $base=Import-PowerShellDataFile $ConfigPath
    $managed=Get-Managed
    $deleted=@($managed.DeletedNames|ForEach-Object{[string]$_})
    $byName=@{}

    foreach($j in @($base.Jobs)){
        if($deleted -contains [string]$j.Name){continue}

        $override=$null
        if($null-ne$managed.Overrides){
            $prop=$managed.Overrides.PSObject.Properties[[string]$j.Name]
            if($null-ne$prop){$override=$prop.Value}
        }

        $byName[[string]$j.Name]=(Merge-Job ([PSCustomObject]$j) $override)
    }

    foreach($j in @($managed.AddedJobs)){
        if($deleted -contains [string]$j.Name){continue}

        $override=$null
        if($null-ne$managed.Overrides){
            $prop=$managed.Overrides.PSObject.Properties[[string]$j.Name]
            if($null-ne$prop){$override=$prop.Value}
        }

        $byName[[string]$j.Name]=(Merge-Job $j $override)
    }

    return @($byName.Values)
}

function Test-ExpectedDay {
    param($Job,[datetime]$Date)

    if([string]$Job.ExpectedDays -eq "Weekdays"){
        return $Date.DayOfWeek -notin @(
            [DayOfWeek]::Saturday,
            [DayOfWeek]::Sunday
        )
    }

    return $true
}

function Get-TodayExpectedTime {
    param($Job)

    $value=[string]$Job.ExpectedBackupTime
    if([string]::IsNullOrWhiteSpace($value)){return $null}

    try{
        if(-not(Test-ExpectedDay -Job $Job -Date (Get-Date))){return $null}

        $parts=$value.Split(":")
        if($parts.Count -lt 2){return $null}

        return (Get-Date).Date.
            AddHours([int]$parts[0]).
            AddMinutes([int]$parts[1])
    }catch{
        return $null
    }
}

$createdNew=$false
$mutex=New-Object System.Threading.Mutex(
    $false,
    "Global\BackupS3_AutoScheduler_Stable",
    [ref]$createdNew
)

$owned=$false

try{
    try{
        $owned=$mutex.WaitOne(0,$false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $owned=$true
    }

    if(-not$owned){
        Write-AutoLog INFO "Skip: another AutoScheduler instance is running"
        Write-SchedulerHealth -Status "BUSY" -Message "Предыдущий запуск планировщика ещё работает"
        exit 0
    }

    foreach($required in @($ConfigPath,$BackupScript)){
        if(-not(Test-Path $required -PathType Leaf)){throw "Required file not found: $required"}
    }

    if(Test-Path $ControllerPath -PathType Leaf){
        try{
            $ctl=Get-Content $ControllerPath -Raw -Encoding UTF8|ConvertFrom-Json
            $controllerPid=[int]$ctl.pid

            if(
                $controllerPid -gt 0 -and
                $null-ne(Get-Process -Id $controllerPid -ErrorAction SilentlyContinue)
            ){
                Write-AutoLog INFO "Skip: BackupS3 already running PID=$controllerPid"
                Write-SchedulerHealth -Status "BUSY" -Message "Проверка BackupS3 уже выполняется"
                exit 0
            }
        }catch{}

        Remove-Item $ControllerPath -Force -ErrorAction SilentlyContinue
    }

    $settings=$null
    if(Test-Path $SettingsPath -PathType Leaf){
        try{
            $settings=Get-Content $SettingsPath -Raw -Encoding UTF8|ConvertFrom-Json
        }catch{}
    }

    # The task should normally be disabled when this is false.
    # This second guard protects against stale/manual Task Scheduler launches.
    if($null-ne$settings -and $null-ne$settings.AutoSchedulerEnabled){
        if(-not[bool]$settings.AutoSchedulerEnabled){
            Write-AutoLog INFO "Skip: AutoScheduler disabled in settings"
            Write-SchedulerHealth -Status "DISABLED" -Message "Автоматическая проверка выключена в настройках"
            exit 0
        }
    }

    $interval=[Math]::Max(1,[int]$settings.AutoSchedulerIntervalMinutes)
    [ordered]@{
        nextRunAt=(Get-Date).AddMinutes($interval).ToString("o")
        lastStartedAt=(Get-Date).ToString("o")
        intervalMinutes=$interval
        status="STARTED"
    }|ConvertTo-Json|Set-Content -LiteralPath $SchedulerStatePath -Encoding UTF8

    # Each Task Scheduler trigger performs the same full refresh as the
    # Dashboard button "Проверить сейчас". BackupS3.ps1 receives ScheduledRun
    # and independently permits uploads only inside each job's day/time window.
    $due=@(
        Get-EffectiveJobs |
        Where-Object {$null -eq $_.Enabled -or [bool]$_.Enabled} |
        ForEach-Object {[string]$_.Name}
    )

    if($due.Count -eq 0){
        Write-AutoLog INFO "No enabled databases"
        Write-SchedulerHealth -Status "IDLE" -Message "Нет включённых баз для автоматической проверки"
        exit 0
    }

    $names=$due -join ","
    Write-AutoLog INFO "Starting BackupS3 for: $names"

    $powershellExe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    $arguments=@(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy","Bypass",
        "-File",('"' + $BackupScript + '"'),
        "-JobNamesCsv",('"' + $names + '"'),
        "-ScheduledRun"
    ) -join " "

    $proc=Start-Process `
        -FilePath $powershellExe `
        -ArgumentList $arguments `
        -WorkingDirectory $RootPath `
        -WindowStyle Hidden `
        -PassThru

    Write-AutoLog INFO "BackupS3 started PID=$($proc.Id)"
    Start-Sleep -Milliseconds 800
    if($proc.HasExited -and $proc.ExitCode -ne 0){
        throw "BackupS3 завершился сразу после запуска с кодом $($proc.ExitCode)"
    }
    Write-SchedulerHealth -Status "STARTED" -Message "Полная автоматическая проверка баз запущена" -Databases @($due)
}
catch{
    Write-AutoLog ERROR $_.Exception.Message
    try{Write-SchedulerHealth -Status "ERROR" -Message $_.Exception.Message}catch{}
    exit 1
}
finally{
    if($owned){
        try{$mutex.ReleaseMutex()}catch{}
    }

    try{$mutex.Dispose()}catch{}
}
