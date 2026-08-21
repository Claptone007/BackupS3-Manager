param(
    [string]$RootPath = $PSScriptRoot,
    [int]$Port = 8765
)

$ErrorActionPreference = "Stop"

$script:AppRoot = [System.IO.Path]::GetFullPath($RootPath)

if (-not (Test-Path $script:AppRoot -PathType Container)) {
    throw "BackupS3 root directory not found: $script:AppRoot"
}

$webRoot = Join-Path $script:AppRoot "Web"
$controller = Join-Path $script:AppRoot "BackupS3.ps1"
$configFile = Join-Path $script:AppRoot "BackupJobs.psd1"
$managedJobsFile = Join-Path $script:AppRoot "State\managed-jobs.json"
$maintenanceFile = Join-Path $script:AppRoot "State\maintenance.json"
$settingsFile = Join-Path $script:AppRoot "State\settings.json"
$autoSchedulerTaskName = "BackupS3 Auto Scheduler"
$autoSchedulerScript = Join-Path $script:AppRoot "AutoScheduler.ps1"
$uiSettingsFile = Join-Path $script:AppRoot "State\ui-settings.json"
$stateFile = Join-Path $script:AppRoot "State\state.json"
$progressFile = Join-Path $script:AppRoot "State\progress.json"
$controllerStateFile = Join-Path $script:AppRoot "State\controller.json"
$cancelFile = Join-Path $script:AppRoot "State\cancel.flag"
$baseConfigForPaths = Import-PowerShellDataFile $configFile
$controllerLogFile = if ([System.IO.Path]::IsPathRooted([string]$baseConfigForPaths.Global.LogFile)) { [string]$baseConfigForPaths.Global.LogFile } else { Join-Path $script:AppRoot ([string]$baseConfigForPaths.Global.LogFile) }
$serverLogFile = Join-Path $script:AppRoot "Logs\dashboard-server.log"
$auditLogFile = Join-Path $script:AppRoot "Logs\audit.log"
$manualUploadScript = Join-Path $script:AppRoot "Manual-Upload.ps1"
$manualUploadDir = Join-Path $script:AppRoot "State\ManualUploads"
$uploadProgressDir = Join-Path $script:AppRoot "State\UploadProgress"
if(-not(Test-Path $uploadProgressDir)){New-Item -ItemType Directory -Path $uploadProgressDir -Force|Out-Null}

if (-not (Test-Path $webRoot)) {
    throw "Web directory not found: $webRoot"
}

if (-not (Test-Path $manualUploadDir)) {
    New-Item -ItemType Directory -Path $manualUploadDir -Force | Out-Null
}

$listener = New-Object System.Net.HttpListener

# ВАЖНО: только localhost. Страница не доступна с других компьютеров.
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)


function Get-SafeLogTail {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$Lines = 250,
        [int]$MaxLineChars = 3000,
        [int]$MaxTotalChars = 180000
    )

    if(-not(Test-Path $Path -PathType Leaf)){
        return @()
    }

    $Lines = [Math]::Max(20,[Math]::Min(1000,$Lines))
    $raw = @(Get-Content -Path $Path -Tail $Lines -Encoding UTF8 -ErrorAction Stop)

    $result = New-Object System.Collections.Generic.List[string]
    $used = 0

    foreach($line in $raw){
        $value = [string]$line

        if($value.Length -gt $MaxLineChars){
            $value = $value.Substring(0,$MaxLineChars) + " … [строка обрезана]"
        }

        $cost = $value.Length + 1
        if(($used + $cost) -gt $MaxTotalChars){
            $result.Add("… [лог обрезан: превышен лимит ответа]")
            break
        }

        $result.Add($value)
        $used += $cost
    }

    return @($result)
}

function Write-ServerLog {
    param([string]$Level="INFO",[string]$Message)
    try{
        $dir=Split-Path $serverLogFile -Parent
        if(-not(Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
        Add-Content -Path $serverLogFile -Value ("{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$Level,$Message) -Encoding UTF8
    }catch{}
}


function Write-AuditLog {
    param(
        [string]$Action,
        [string]$Database = "",
        [string]$Message = "",
        [string]$Level = "INFO"
    )

    try{
        $dir=Split-Path $auditLogFile -Parent
        if(-not(Test-Path $dir)){
            New-Item -ItemType Directory -Path $dir -Force|Out-Null
        }

        $parts=New-Object System.Collections.Generic.List[string]
        $parts.Add("[AUDIT]")
        $parts.Add("action=$Action")

        if(-not[string]::IsNullOrWhiteSpace($Database)){
            $parts.Add("database=$Database")
        }

        if(-not[string]::IsNullOrWhiteSpace($Message)){
            $clean=($Message -replace "(\r|\n)+"," ").Trim()
            if($clean.Length -gt 1200){
                $clean=$clean.Substring(0,1200)+" ..."
            }
            $parts.Add($clean)
        }

        $line="{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$Level,($parts -join " ")
        Add-Content -Path $auditLogFile -Value $line -Encoding UTF8

        # Important administrative events are also duplicated in dashboard-server.log,
        # so they are visible without switching log source.
        Write-ServerLog $Level ($parts -join " ")
    }catch{}
}

function Write-Response {
    param(
        $Context,
        [int]$StatusCode,
        [string]$ContentType,
        [byte[]]$Body
    )

    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $Body.Length
    $Context.Response.OutputStream.Write($Body, 0, $Body.Length)
    $Context.Response.OutputStream.Close()
}

function Write-Text {
    param($Context, [int]$StatusCode, [string]$Text, [string]$ContentType = "text/plain; charset=utf-8")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    Write-Response -Context $Context -StatusCode $StatusCode -ContentType $ContentType -Body $bytes
}


function Read-JsonBody {
    param($Request)

    # Browser JSON is UTF-8. Do not rely on HttpListener.ContentEncoding:
    # on Windows PowerShell 5.1 it may produce mojibake for Cyrillic text.
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $reader = New-Object System.IO.StreamReader(
        $Request.InputStream,
        $utf8,
        $true
    )

    try {
        $body = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        return $null
    }

    return ($body | ConvertFrom-Json)
}

function Repair-Utf8Mojibake {
    param([AllowNull()][string]$Text)

    if([string]::IsNullOrEmpty($Text)){ return $Text }

    # Typical broken UTF-8 Cyrillic looks like:
    # РџСЂРёРјРµСЂ...
    # Only attempt a conversion when these marker sequences are present.
    if($Text -notmatch 'Р.|С.'){
        return $Text
    }

    try{
        $cp1251=[System.Text.Encoding]::GetEncoding(1251)
        $utf8=[System.Text.Encoding]::UTF8
        $candidate=$utf8.GetString($cp1251.GetBytes($Text))

        # Accept the repaired value only when it no longer contains
        # the common mojibake pattern and contains readable Cyrillic.
        if($candidate -match '[А-Яа-яЁё]' -and $candidate -notmatch 'Р.|С.'){
            return $candidate
        }
    }catch{}

    return $Text
}

function Get-ManagedJobsConfig {
    if (-not (Test-Path $managedJobsFile)) {
        return [PSCustomObject]@{
            AddedJobs = @()
            DeletedNames = @()
            Overrides = [PSCustomObject]@{}
        }
    }

    try {
        $cfg = Get-Content $managedJobsFile -Raw -Encoding UTF8 | ConvertFrom-Json

        return [PSCustomObject]@{
            AddedJobs = @($cfg.AddedJobs)
            DeletedNames = @($cfg.DeletedNames)
            Overrides = if($null -ne $cfg.Overrides){$cfg.Overrides}else{[PSCustomObject]@{}}
        }
    }
    catch {
        return [PSCustomObject]@{
            AddedJobs = @()
            DeletedNames = @()
            Overrides = [PSCustomObject]@{}
        }
    }
}

function Save-ManagedJobsConfig {
    param($Config)

    $dir = Split-Path $managedJobsFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $tmp = "$managedJobsFile.tmp"
    $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $managedJobsFile -Force
}


function Get-EffectiveJobConfig {
    param([string]$Name)

    $base=Import-PowerShellDataFile $configFile
    $managed=Get-ManagedJobsConfig

    $job=$null

    $baseJob=@($base.Jobs|Where-Object{[string]$_.Name -ieq $Name}|Select-Object -First 1)
    if($baseJob.Count){ $job=$baseJob[0] }

    if($null -eq $job){
        $added=@($managed.AddedJobs|Where-Object{[string]$_.Name -ieq $Name}|Select-Object -First 1)
        if($added.Count){ $job=$added[0] }
    }

    if($null -eq $job){ return $null }

    $copy=[ordered]@{}
    if($job -is [System.Collections.IDictionary]){
        foreach($k in $job.Keys){$copy[$k]=$job[$k]}
    }else{
        foreach($p in $job.PSObject.Properties){$copy[$p.Name]=$p.Value}
    }

    if($null -ne $managed.Overrides){
        $prop=$managed.Overrides.PSObject.Properties[$Name]
        if($null -ne $prop){
            foreach($p in $prop.Value.PSObject.Properties){
                if($p.Name -ne "Name"){$copy[$p.Name]=$p.Value}
            }
        }
    }

    return [PSCustomObject]$copy
}

function Set-JobOverride {
    param([string]$Name,$Override)

    $managed=Get-ManagedJobsConfig
    $ovHash=[ordered]@{}

    if($null -ne $managed.Overrides){
        foreach($p in $managed.Overrides.PSObject.Properties){
            $ovHash[$p.Name]=$p.Value
        }
    }

    $ovHash[$Name]=$Override

    Save-ManagedJobsConfig -Config ([PSCustomObject]@{
        AddedJobs=@($managed.AddedJobs)
        DeletedNames=@($managed.DeletedNames)
        Overrides=[PSCustomObject]$ovHash
    })
}

function Get-AllConfiguredJobNames {
    $base = Import-PowerShellDataFile $configFile
    $managed = Get-ManagedJobsConfig

    $names = @($base.Jobs | ForEach-Object { [string]$_.Name })
    $names += @($managed.AddedJobs | ForEach-Object { [string]$_.Name })

    return @($names | Select-Object -Unique)
}



function Invoke-AwsForDashboard {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [AllowNull()]
        [string]$Profile
    )

    $cfg = Import-PowerShellDataFile $configFile
    $endpoint = [string]$cfg.Global.EndpointUrl

    $argsList = @("--endpoint-url", $endpoint)

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $argsList += @("--profile", $Profile)
    }

    $argsList += $Arguments

    $output = & aws @argsList 2>&1
    $exitCode = $LASTEXITCODE

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = ($output -join [Environment]::NewLine)
    }
}

function Show-FolderBrowser {
    param(
        [string]$InitialPath = ""
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Выберите папку с backup-файлами"
        $dialog.ShowNewFolderButton = $false

        if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path $InitialPath -PathType Container)) {
            $dialog.SelectedPath = $InitialPath
        }

        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $owner.ShowInTaskbar = $false
        $owner.StartPosition = "CenterScreen"
        $owner.Size = New-Object System.Drawing.Size(1, 1)
        $owner.Opacity = 0
        $owner.Show()
        $owner.Activate()

        try {
            $result = $dialog.ShowDialog($owner)
            if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
                return [PSCustomObject]@{
                    Cancelled = $false
                    Path      = $dialog.SelectedPath
                }
            }

            return [PSCustomObject]@{
                Cancelled = $true
                Path      = ""
            }
        }
        finally {
            $dialog.Dispose()
            $owner.Close()
            $owner.Dispose()
        }
    }
    catch {
        throw "Не удалось открыть проводник выбора папки: $($_.Exception.Message)"
    }
}


function Get-MaintenanceConfig {
    if(-not(Test-Path $maintenanceFile)){return [PSCustomObject]@{}}
    try{return (Get-Content $maintenanceFile -Raw -Encoding UTF8|ConvertFrom-Json)}catch{return [PSCustomObject]@{}}
}
function Save-MaintenanceConfig {
    param($Object)
    $Object|ConvertTo-Json -Depth 8|Set-Content $maintenanceFile -Encoding UTF8
}

function Reset-ProgressBeforeRun {
    param(
        [string]$Database = "",
        [int]$Total = 19
    )

    $progress = [ordered]@{
        running   = $true
        current   = 0
        total     = $Total
        percent   = 0
        database  = $Database
        phase     = "STARTING"
        message   = if ($Database) { "Запуск проверки $Database" } else { "Запуск проверки всех баз" }
        updatedAt = (Get-Date).ToString("o")
    }

    $dir = Split-Path $progressFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $tmp = "$progressFile.tmp"
    $progress | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $progressFile -Force
}


function Get-RuntimeSettingsForServer {
    $base = Import-PowerShellDataFile $configFile

    $settings = [ordered]@{
        SafeMode                  = $true
        EnableUpload              = [bool]$base.Global.EnableUpload
        EnableCleanup             = [bool]$base.Global.EnableCleanup
        EnableGraylog             = [bool]$base.Global.EnableGraylog
        MinFileIdleMinutes        = [int]$base.Global.MinFileIdleMinutes
        RetryCount                = [int]$base.Global.RetryCount
        RetryDelaySeconds         = [int]$base.Global.RetryDelaySeconds
        HistoryDays               = if($base.Global.HistoryDays){[int]$base.Global.HistoryDays}else{30}
        DefaultSizeAnomalyPercent = if($base.Global.DefaultSizeAnomalyPercent){[int]$base.Global.DefaultSizeAnomalyPercent}else{35}
        AutoRefreshSeconds        = 60
        AutoSchedulerEnabled      = $false
        AutoSchedulerIntervalMinutes = 2
    }

    if(Test-Path $settingsFile){
        try{
            $saved=Get-Content $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json
            foreach($p in $saved.PSObject.Properties){
                if($settings.Contains($p.Name)){$settings[$p.Name]=$p.Value}
            }
        }catch{}
    }

    return [PSCustomObject]$settings
}

function Save-RuntimeSettingsForServer {
    param($Settings)

    $safe = [ordered]@{
        SafeMode                  = [bool]$Settings.SafeMode
        EnableUpload              = [bool]$Settings.EnableUpload
        EnableCleanup             = [bool]$Settings.EnableCleanup
        EnableGraylog             = [bool]$Settings.EnableGraylog
        MinFileIdleMinutes        = [int]$Settings.MinFileIdleMinutes
        RetryCount                = [int]$Settings.RetryCount
        RetryDelaySeconds         = [int]$Settings.RetryDelaySeconds
        HistoryDays               = [int]$Settings.HistoryDays
        DefaultSizeAnomalyPercent = [int]$Settings.DefaultSizeAnomalyPercent
        AutoRefreshSeconds        = [int]$Settings.AutoRefreshSeconds
        AutoSchedulerEnabled      = [bool]$Settings.AutoSchedulerEnabled
        AutoSchedulerIntervalMinutes = [int]$Settings.AutoSchedulerIntervalMinutes
    }

    $tmp="$settingsFile.tmp"
    $safe|ConvertTo-Json -Depth 5|Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $settingsFile -Force
}



function Apply-AutoSchedulerSetting {
    param(
        [bool]$Enabled,
        [int]$IntervalMinutes
    )

    if($IntervalMinutes -lt 1 -or $IntervalMinutes -gt 60){
        throw "Интервал автоматической проверки должен быть от 1 до 60 минут."
    }

    if(-not(Test-Path $autoSchedulerScript -PathType Leaf)){
        throw "AutoScheduler.ps1 не найден: $autoSchedulerScript"
    }

    try{
        Import-Module ScheduledTasks -ErrorAction Stop

        $existing=Get-ScheduledTask -TaskName $autoSchedulerTaskName -ErrorAction SilentlyContinue

        if($Enabled){
            $powershellExe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

            $action=New-ScheduledTaskAction `
                -Execute $powershellExe `
                -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$autoSchedulerScript`""

            $trigger=New-ScheduledTaskTrigger `
                -Once `
                -At (Get-Date).AddMinutes(1) `
                -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

            $taskSettings=New-ScheduledTaskSettingsSet `
                -MultipleInstances IgnoreNew `
                -StartWhenAvailable `
                -ExecutionTimeLimit (New-TimeSpan -Hours 3)

            Register-ScheduledTask `
                -TaskName $autoSchedulerTaskName `
                -Action $action `
                -Trigger $trigger `
                -Settings $taskSettings `
                -Description "Automatic BackupS3 due-check and S3 upload orchestration" `
                -Force | Out-Null

            Enable-ScheduledTask -TaskName $autoSchedulerTaskName -ErrorAction Stop | Out-Null

            Write-AuditLog `
                -Action "AUTO_SCHEDULER_ENABLE" `
                -Message "Автоматическая проверка включена; интервал=$IntervalMinutes мин."

            return
        }

        if($null -ne $existing){
            Disable-ScheduledTask -TaskName $autoSchedulerTaskName -ErrorAction Stop | Out-Null
            Stop-ScheduledTask -TaskName $autoSchedulerTaskName -ErrorAction SilentlyContinue

            Write-AuditLog `
                -Action "AUTO_SCHEDULER_DISABLE" `
                -Message "Автоматическая проверка выключена."
        }
    }
    catch{
        Write-ServerLog ERROR "AutoScheduler setting failed: $($_.Exception.Message)"
        throw "Не удалось применить автоматическую проверку: $($_.Exception.Message)"
    }
}

function Get-UiSettings {
    if(-not(Test-Path $uiSettingsFile)){
        return [PSCustomObject]@{
            Jobs=[PSCustomObject]@{}
            DefaultSort="priority"
            ShowFavorites=$true
        }
    }

    try{
        $u=Get-Content $uiSettingsFile -Raw -Encoding UTF8|ConvertFrom-Json
        if($null -eq $u.Jobs){$u|Add-Member -NotePropertyName Jobs -NotePropertyValue ([PSCustomObject]@{})}
        if($null -eq $u.DefaultSort){$u|Add-Member -NotePropertyName DefaultSort -NotePropertyValue "priority"}
        if($null -eq $u.ShowFavorites){$u|Add-Member -NotePropertyName ShowFavorites -NotePropertyValue $true}

        $changed=$false
        foreach($p in @($u.Jobs.PSObject.Properties)){
            $j=$p.Value
            if($null -eq $j){continue}

            foreach($field in @("Alias","Group","Note")){
                $prop=$j.PSObject.Properties[$field]
                if($null -eq $prop){continue}

                $before=[string]$prop.Value
                $after=Repair-Utf8Mojibake $before

                if($after -ne $before){
                    $prop.Value=$after
                    $changed=$true
                }
            }
        }

        # Migrate repaired legacy text to UTF-8 immediately.
        if($changed){
            try{ Save-UiSettings $u }catch{}
        }

        return $u
    }catch{
        return [PSCustomObject]@{
            Jobs=[PSCustomObject]@{}
            DefaultSort="priority"
            ShowFavorites=$true
        }
    }
}

function Save-UiSettings {
    param($Object)
    $tmp="$uiSettingsFile.tmp"
    $Object|ConvertTo-Json -Depth 10|Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $uiSettingsFile -Force
}



function Get-ActiveController {
    if(-not(Test-Path $controllerStateFile -PathType Leaf)){
        return $null
    }

    try{
        $state=Get-Content $controllerStateFile -Raw -Encoding UTF8|ConvertFrom-Json
        $pidValue=[int]$state.pid
        if($pidValue -le 0){
            Remove-Item $controllerStateFile -Force -ErrorAction SilentlyContinue
            return $null
        }

        $proc=Get-CimInstance Win32_Process -Filter "ProcessId = $pidValue" -ErrorAction SilentlyContinue
        if($null-eq$proc){
            Remove-Item $controllerStateFile -Force -ErrorAction SilentlyContinue
            return $null
        }

        $cmd=[string]$proc.CommandLine

        # PID may have been reused by Windows. Only BackupS3.ps1 is a valid
        # active controller.
        if(
            $proc.Name -notmatch '^(powershell|pwsh)(\.exe)?$' -or
            $cmd -notlike '*BackupS3.ps1*'
        ){
            Write-ServerLog WARN "Removing stale controller state. PID=$pidValue now belongs to '$($proc.Name)' cmd='$cmd'"
            Remove-Item $controllerStateFile -Force -ErrorAction SilentlyContinue
            return $null
        }

        return [PSCustomObject]@{
            Pid=$pidValue
            StartedAt=[string]$state.startedAt
            Requested=@($state.requested)
            CommandLine=$cmd
        }
    }catch{
        Write-ServerLog WARN "Invalid controller state removed: $($_.Exception.Message)"
        Remove-Item $controllerStateFile -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Assert-NoActiveController {
    $active=Get-ActiveController
    if($null -ne $active){
        $requested=if(@($active.Requested).Count){@($active.Requested)-join ", "}else{"все базы"}
        throw "Проверка уже выполняется. PID=$($active.Pid); базы: $requested. Сначала дождись завершения или нажми «Остановить»."
    }
}

function Start-BackupController {
    param(
        [string]$Database = "",
        [string[]]$Databases = @()
    )

    Assert-NoActiveController

    if (-not (Test-Path $script:AppRoot -PathType Container)) {
        throw "Рабочая папка BackupS3 не существует: $script:AppRoot"
    }
    if (-not (Test-Path $controller -PathType Leaf)) {
        throw "Контроллер BackupS3.ps1 не найден: $controller"
    }

    $powershellExe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if(-not(Test-Path $powershellExe -PathType Leaf)){
        $candidate=(Get-Command powershell.exe -ErrorAction SilentlyContinue)
        if($null-eq$candidate){throw "powershell.exe не найден"}
        $powershellExe=$candidate.Source
    }

    $selected=@()
    if($Databases.Count){
        $selected=@($Databases|Where-Object{$_}|Select-Object -Unique)
    }elseif(-not[string]::IsNullOrWhiteSpace($Database)){
        $selected=@($Database)
    }

    $arguments=@(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy","Bypass",
        "-File",('"' + $controller + '"')
    )

    if($selected.Count){
        $csv=(($selected -join ",") -replace '"','')
        $arguments+=@("-JobNamesCsv",('"' + $csv + '"'))
    }

    $stdoutFile=Join-Path $script:AppRoot "Logs\controller-launch.stdout.log"
    $stderrFile=Join-Path $script:AppRoot "Logs\controller-launch.stderr.log"

    Remove-Item $stdoutFile,$stderrFile -Force -ErrorAction SilentlyContinue

    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$powershellExe
    $psi.Arguments=($arguments -join " ")
    $psi.WorkingDirectory=$script:AppRoot
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$false
    $psi.RedirectStandardError=$false

    Write-ServerLog INFO "Controller start requested. exe='$powershellExe'; Databases='$($selected -join ',')'"

    $proc=New-Object System.Diagnostics.Process
    $proc.StartInfo=$psi

    if(-not $proc.Start()){
        $proc.Dispose()
        throw "Не удалось запустить BackupS3.ps1"
    }

    $controllerProcessId=[int]$proc.Id

    [ordered]@{
        pid=$controllerProcessId
        startedAt=(Get-Date).ToString("o")
        requested=@($selected)
        source="dashboard"
    }|ConvertTo-Json -Depth 5|Set-Content $controllerStateFile -Encoding UTF8

    Write-ServerLog INFO "Controller process started. PID=$controllerProcessId Databases='$($selected -join ',')'"

    # Give PowerShell enough time to parse the script/acquire mutex.
    Start-Sleep -Milliseconds 650

    if($proc.HasExited){
        $exitCode=[int]$proc.ExitCode
        Remove-Item $controllerStateFile -Force -ErrorAction SilentlyContinue
        $proc.Dispose()

        $detail="BackupS3.ps1 завершился сразу после запуска, exit=$exitCode. Открой Log -> BackupS3."

        if($exitCode -eq 75){
            throw "BackupS3.ps1 не запущен: mutex занят другим экземпляром. Проверь Log и активные процессы."
        }

        throw "BackupS3.ps1 не запущен. Exit=$exitCode. $detail"
    }

    $proc.Dispose()

    return $controllerProcessId
}

function Get-ValidatedLocalBackupFile {
    param(
        [Parameter(Mandatory=$true)]$Job,
        [Parameter(Mandatory=$true)][string]$FilePath
    )

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        throw "FilePath is required"
    }

    $jobRoot = [System.IO.Path]::GetFullPath([string]$Job.LocalPath)
    $candidate = [System.IO.Path]::GetFullPath($FilePath)

    $rootWithSeparator = $jobRoot.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar

    if (-not $candidate.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Файл находится вне локальной папки базы."
    }

    if (-not (Test-Path $candidate -PathType Leaf)) {
        throw "Локальный файл не найден: $candidate"
    }

    $leaf = [System.IO.Path]::GetFileName($candidate)
    if (-not $leaf.StartsWith([string]$Job.FilePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Имя файла не соответствует FilePrefix '$($Job.FilePrefix)'."
    }

    return (Get-Item $candidate)
}

function Get-ManualUploadStatusPath {
    param([string]$OperationId)
    if ($OperationId -notmatch '^[a-fA-F0-9-]{20,80}$') {
        throw "Invalid operation id"
    }
    return (Join-Path $manualUploadDir "$OperationId.json")
}


function ConvertTo-CsvField {
    param($Value)
    $v=[string]$Value
    return '"' + ($v.Replace('"','""')) + '"'
}

function New-StandaloneJobScript {
    param($Job,$Endpoint)

    $profile=[string]$Job.AwsProfile
    $profileLine=if([string]::IsNullOrWhiteSpace($profile)){
        '$profileArgs=@()'
    }else{
        '$profileArgs=@("--profile","'+$profile.Replace('"','')+'")'
    }

    @"
param(
    [switch]`$Upload
)

`$ErrorActionPreference="Stop"
`$endpoint="$Endpoint"
`$bucket="$($Job.Bucket)"
`$s3Path="$($Job.S3Path)"
`$localPath="$($Job.LocalPath)"
`$filePrefix="$($Job.FilePrefix)"
$profileLine

if(-not(Get-Command aws -ErrorAction SilentlyContinue)){
    throw "AWS CLI not found"
}
if(-not(Test-Path `$localPath -PathType Container)){
    throw "Local path not found: `$localPath"
}

`$latest=Get-ChildItem `$localPath -File |
    Where-Object { `$_.Name.StartsWith(`$filePrefix,[StringComparison]::OrdinalIgnoreCase) } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if(`$null -eq `$latest){throw "Backup file not found"}

`$key=if([string]::IsNullOrWhiteSpace(`$s3Path)){`$latest.Name}else{"`$s3Path/`$(`$latest.Name)"}
`$destination="s3://`$bucket/`$key"

Write-Host "Database: $($Job.Name)"
Write-Host "Local:    `$(`$latest.FullName)"
Write-Host "Size:     `$([math]::Round(`$latest.Length/1GB,2)) GB"
Write-Host "S3:       `$destination"

if(-not `$Upload){
    Write-Host "DRY RUN. Для загрузки запусти: .\$(Split-Path -Leaf $Job.Name).ps1 -Upload"
    exit 0
}

& aws --endpoint-url `$endpoint @profileArgs s3 cp `$latest.FullName `$destination --only-show-errors
if(`$LASTEXITCODE -ne 0){throw "AWS upload failed: exit `$LASTEXITCODE"}

Write-Host "Upload completed."
"@
}

function Get-ContentType {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".html" { "text/html; charset=utf-8" }
        ".css"  { "text/css; charset=utf-8" }
        ".js"   { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".png"  { "image/png" }
        ".svg"  { "image/svg+xml" }
        default { "application/octet-stream" }
    }
}

$listener.Start()
Write-ServerLog INFO "Dashboard server started on $prefix; AppRoot=$script:AppRoot"
Write-Host "BackupS3 Dashboard: $prefix"
Write-Host "Доступ разрешён только с этого сервера (127.0.0.1)."
Write-Host "Для остановки нажмите Ctrl+C."

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()

        try {
            $path = $context.Request.Url.AbsolutePath.ToLowerInvariant()

            if ($path -eq "/api/health" -and $context.Request.HttpMethod -eq "GET") {
                $payload=[ordered]@{
                    ok=$true
                    serverTime=(Get-Date).ToString("o")
                    appRoot=$script:AppRoot
                    controllerExists=(Test-Path $controller -PathType Leaf)
                    controllerLogExists=(Test-Path $controllerLogFile -PathType Leaf)
                    serverLog=$serverLogFile
                }
                Write-Text $context 200 ($payload|ConvertTo-Json -Depth 5) "application/json; charset=utf-8"
                continue
            }

            if ($path -eq "/api/version") {
                Write-Text -Context $context -StatusCode 200 -Text '{"version":"21.37","name":"BackupS3 Dashboard Server"}' -ContentType "application/json; charset=utf-8"
                continue
            }

            if ($path -eq "/api/server/restart" -and $context.Request.HttpMethod -eq "POST") {
                try{
                    $powershellExe=(Get-Process -Id $PID).Path
                    if([string]::IsNullOrWhiteSpace($powershellExe)){
                        $powershellExe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                    }

                    $serverScript=$MyInvocation.MyCommand.Path
                    if([string]::IsNullOrWhiteSpace($serverScript) -or -not(Test-Path $serverScript -PathType Leaf)){
                        throw "Не удалось определить путь Start-DashboardServer.ps1"
                    }

                    # Use a tiny helper file instead of a heavily quoted -Command string.
                    # This is much more reliable on Windows PowerShell 5.1.
                    $restartHelper=Join-Path $script:AppRoot "State\restart-dashboard.ps1"
                    $helperText=@"
param()
Start-Sleep -Milliseconds 1500
& '$($serverScript.Replace("'","''"))' -Port $Port
"@
                    $helperText|Set-Content $restartHelper -Encoding UTF8

                    $psi=New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName=$powershellExe
                    $psi.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$restartHelper+'"'
                    $psi.WorkingDirectory=$script:AppRoot
                    $psi.UseShellExecute=$false
                    $psi.CreateNoWindow=$true

                    $proc=[System.Diagnostics.Process]::Start($psi)
                    if($null -eq $proc){
                        throw "Не удалось запустить helper перезапуска"
                    }
                    $newLauncherPid=$proc.Id
                    $proc.Dispose()

                    Write-AuditLog -Action "SERVER_RESTART" -Message "Перезапуск Dashboard Server запрошен из web-интерфейса; launcherPid=$newLauncherPid"

                    # IMPORTANT: finish HTTP response first. In v21.10 listener.Stop()
                    # happened immediately after Write-Text and Edge/Chrome could see
                    # the connection as aborted and report 'Failed to fetch'.
                    Write-Text $context 202 (@{
                        status="restarting"
                        launcherPid=$newLauncherPid
                        waitMs=1500
                    }|ConvertTo-Json -Compress) "application/json; charset=utf-8"

                    Start-Sleep -Milliseconds 650

                    # Now it is safe to release the port for the helper.
                    try{$listener.Stop()}catch{}
                    break
                }catch{
                    Write-ServerLog ERROR "Dashboard restart failed: $($_.Exception.Message)"
                    try{
                        Write-Text $context 500 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                    }catch{}
                }
                continue
            }





            if ($path -eq "/api/upload-progress" -and $context.Request.HttpMethod -eq "GET") {
                try{
                    $items=New-Object System.Collections.Generic.List[object]

                    foreach($f in @(Get-ChildItem $uploadProgressDir -Filter "*.json" -File -ErrorAction SilentlyContinue)){
                        try{
                            $o=Get-Content $f.FullName -Raw -Encoding UTF8|ConvertFrom-Json
                            $items.Add($o)
                        }catch{}
                    }

                    Write-Text $context 200 (@{
                        items=@($items)
                        serverTime=(Get-Date).ToString("o")
                    }|ConvertTo-Json -Depth 8) "application/json; charset=utf-8"
                }catch{
                    Write-Text $context 500 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }


            if ($path -eq "/api/controller-status" -and $context.Request.HttpMethod -eq "GET") {
                $active=Get-ActiveController
                if($null -eq $active){
                    Write-Text $context 200 '{"running":false}' "application/json; charset=utf-8"
                }else{
                    Write-Text $context 200 ([ordered]@{
                        running=$true
                        pid=$active.Pid
                        startedAt=$active.StartedAt
                        requested=@($active.Requested)
                    }|ConvertTo-Json -Compress -Depth 5) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/cancel" -and $context.Request.HttpMethod -eq "POST") {
                try{
                    "cancel requested $(Get-Date -Format o)"|Set-Content $cancelFile -Encoding UTF8

                    $stoppedPid=$null
                    $active=Get-ActiveController
                    if($null -ne $active){
                        try{
                            $pidToStop=[int]$active.Pid
                            # /T also terminates a child aws.exe if the controller is waiting on AWS.
                            & "$env:SystemRoot\System32\taskkill.exe" /PID $pidToStop /T /F 2>&1 | Out-Null
                            $stoppedPid=$pidToStop
                        }catch{
                            Write-ServerLog WARN "Cancel process tree: $($_.Exception.Message)"
                        }
                    }

                    $p=[ordered]@{
                        running=$false;current=0;total=0;percent=0;database="";
                        phase="CANCELLED";message="Проверка остановлена пользователем";
                        updatedAt=(Get-Date).ToString("o")
                    }
                    $tmp="$progressFile.tmp";$p|ConvertTo-Json|Set-Content $tmp -Encoding UTF8;Move-Item $tmp $progressFile -Force
                    Remove-Item $controllerStateFile -Force -ErrorAction SilentlyContinue
                    Write-ServerLog WARN "Controller cancel requested. PID=$stoppedPid"
                    Write-Text $context 200 (@{status="cancelled";pid=$stoppedPid}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }catch{
                    Write-Text $context 500 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/jobs/check-selected" -and $context.Request.HttpMethod -eq "POST") {
                try{
                    Assert-NoActiveController

                    $body=Read-JsonBody -Request $context.Request
                    $names=@($body.Names|ForEach-Object{([string]$_).Trim()}|Where-Object{$_}|Select-Object -Unique)
                    if($names.Count -eq 0){throw "Не выбраны базы"}
                    if($names.Count -gt 100){throw "Слишком много баз"}

                    $known=Get-AllConfiguredJobNames
                    $bad=@($names|Where-Object{$known -notcontains $_})
                    if($bad.Count){throw "Неизвестные базы: $($bad -join ', ')"}

                    # Reset only after we know there is no active controller.
                    Reset-ProgressBeforeRun -Total $names.Count

                    $controllerPid=Start-BackupController -Databases $names
                    Write-Text $context 202 (@{
                        status="started"
                        pid=$controllerPid
                        count=$names.Count
                        names=@($names)
                    }|ConvertTo-Json -Compress -Depth 5) "application/json; charset=utf-8"
                }catch{
                    $code=if($_.Exception.Message -like "Проверка уже выполняется*"){409}else{400}
                    Write-Text $context $code (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/jobs/export-ps1" -and $context.Request.HttpMethod -eq "GET") {
                try{
                    $name=([string]$context.Request.QueryString["name"]).Trim()
                    $job=Get-EffectiveJobConfig $name
                    if($null -eq $job){
                        Write-Text $context 404 "job not found";continue
                    }

                    $cfg=Import-PowerShellDataFile $configFile
                    $content=New-StandaloneJobScript -Job $job -Endpoint ([string]$cfg.Global.EndpointUrl)
                    $safeName=($name -replace '[^a-zA-Z0-9_.-]','_')
                    $context.Response.Headers["Content-Disposition"]="attachment; filename=""Backup-$safeName.ps1"""
                    Write-Text $context 200 $content "text/plain; charset=utf-8"
                }catch{
                    Write-Text $context 500 $_.Exception.Message
                }
                continue
            }

            if ($path -eq "/api/report" -and $context.Request.HttpMethod -eq "GET") {
                try{
                    $format=([string]$context.Request.QueryString["format"]).Trim().ToLowerInvariant()
                    if($format -notin @("html","csv","json")){$format="html"}

                    $unit=([string]$context.Request.QueryString["unit"]).Trim().ToLowerInvariant()
                    if($unit -notin @("hours","days")){$unit="days"}

                    [int]$value=1
                    $parsedValue=0
                    if([int]::TryParse([string]$context.Request.QueryString["value"],[ref]$parsedValue)){
                        $value=$parsedValue
                    }
                    $value=[Math]::Max(1,[Math]::Min(365,$value))
                    $since=if($unit -eq "hours"){(Get-Date).AddHours(-$value)}else{(Get-Date).AddDays(-$value)}

                    # State is optional; report should still return a valid file if state.json is absent/corrupt.
                    $stateJobs=@()
                    if(Test-Path $stateFile -PathType Leaf){
                        try{
                            $stateObj=Get-Content $stateFile -Raw -Encoding UTF8|ConvertFrom-Json
                            if($null -ne $stateObj -and $null -ne $stateObj.Jobs){
                                $stateJobs=@($stateObj.Jobs)
                            }
                        }catch{
                            Write-ServerLog WARN "Report: state.json read failed: $($_.Exception.Message)"
                        }
                    }

                    # Read history manually. Do not use Measure-Object / Sort-Object /
                    # PSObject.Properties indexers here: Windows PowerShell 5.1 can emit
                    # 'argument Property is invalid' on malformed/heterogeneous JSONL rows.
                    $history=New-Object System.Collections.Generic.List[object]
                    $historyFile=Join-Path $script:AppRoot "State\history.jsonl"

                    if(Test-Path $historyFile -PathType Leaf){
                        foreach($line in Get-Content $historyFile -Encoding UTF8){
                            if([string]::IsNullOrWhiteSpace([string]$line)){continue}

                            try{
                                $ev=$line|ConvertFrom-Json
                                if($null -eq $ev){continue}

                                $ts=$null
                                try{$ts=[datetime]$ev.timestamp}catch{$ts=$null}
                                if($null -eq $ts -or $ts -lt $since){continue}

                                $history.Add($ev)
                            }catch{
                                # Bad legacy JSON line is skipped instead of breaking the report.
                            }
                        }
                    }

                    $rows=New-Object System.Collections.Generic.List[object]

                    foreach($job in $stateJobs){
                        $dbName=[string]$job.Name
                        $uploadCount=0
                        [Int64]$uploadedBytes=0
                        $lastEventTime=[datetime]::MinValue
                        $lastEventText=""

                        foreach($eventItem in $history){
                            if([string]$eventItem.database -ne $dbName){continue}

                            $eventTime=[datetime]::MinValue
                            try{$eventTime=[datetime]$eventItem.timestamp}catch{}

                            if($eventTime -gt $lastEventTime){
                                $lastEventTime=$eventTime
                                $eventName=[string]$eventItem.event
                                $eventMessage=[string]$eventItem.message
                                $lastEventText=if([string]::IsNullOrWhiteSpace($eventMessage)){
                                    $eventName
                                }else{
                                    "$eventName`: $eventMessage"
                                }
                            }

                            if([string]$eventItem.event -eq "UPLOAD_SUCCESS"){
                                $uploadCount++
                                try{
                                    if($null -ne $eventItem.sizeBytes){
                                        $uploadedBytes += [Int64]$eventItem.sizeBytes
                                    }
                                }catch{}
                            }
                        }

                        [Int64]$localSize=0
                        try{$localSize=[Int64]$job.LocalSizeBytes}catch{}

                        [int]$s3Count=0
                        try{$s3Count=[int]$job.S3ObjectCount}catch{}

                        [int]$health=0
                        try{$health=[int]$job.HealthScore}catch{}

                        $rows.Add([PSCustomObject]@{
                            Database=$dbName
                            Status=[string]$job.Status
                            Health=$health
                            LocalFile=[string]$job.LocalFile
                            LocalSizeBytes=$localSize
                            S3Objects=$s3Count
                            Sync=[string]$job.SyncStatus
                            Uploads=$uploadCount
                            UploadedBytes=[Int64]$uploadedBytes
                            LastEvent=$lastEventText
                            LastChecked=[string]$job.LastChecked
                        })
                    }

                    $stamp=Get-Date -Format "yyyyMMdd-HHmmss"

                    if($format -eq "json"){
                        $obj=[ordered]@{
                            generatedAt=(Get-Date).ToString("o")
                            since=$since.ToString("o")
                            period="$value $unit"
                            jobs=@($rows)
                            events=@($history)
                        }
                        $content=$obj|ConvertTo-Json -Depth 12
                        $ctype="application/json; charset=utf-8"
                        $ext="json"
                    }
                    elseif($format -eq "csv"){
                        $head='"Database","Status","Health","LocalFile","LocalSizeBytes","S3Objects","Sync","Uploads","UploadedBytes","LastEvent","LastChecked"'
                        $csvLines=New-Object System.Collections.Generic.List[string]

                        foreach($row in $rows){
                            $fields=@(
                                $row.Database,
                                $row.Status,
                                $row.Health,
                                $row.LocalFile,
                                $row.LocalSizeBytes,
                                $row.S3Objects,
                                $row.Sync,
                                $row.Uploads,
                                $row.UploadedBytes,
                                $row.LastEvent,
                                $row.LastChecked
                            )

                            $encoded=New-Object System.Collections.Generic.List[string]
                            foreach($field in $fields){
                                $encoded.Add((ConvertTo-CsvField $field))
                            }

                            $csvLines.Add(($encoded -join ","))
                        }

                        $content=$head+[Environment]::NewLine+($csvLines -join [Environment]::NewLine)
                        $ctype="text/csv; charset=utf-8"
                        $ext="csv"
                    }
                    else{
                        $htmlRows=New-Object System.Text.StringBuilder

                        foreach($row in $rows){
                            $db=[Net.WebUtility]::HtmlEncode([string]$row.Database)
                            $status=[Net.WebUtility]::HtmlEncode([string]$row.Status)
                            $file=[Net.WebUtility]::HtmlEncode([string]$row.LocalFile)
                            $sync=[Net.WebUtility]::HtmlEncode([string]$row.Sync)
                            $last=[Net.WebUtility]::HtmlEncode([string]$row.LastEvent)

                            $localGb=[math]::Round(([double]$row.LocalSizeBytes/1GB),2)
                            $uploadedGb=[math]::Round(([double]$row.UploadedBytes/1GB),2)

                            [void]$htmlRows.Append(
                                "<tr><td>$db</td><td>$status</td><td>$($row.Health)%</td><td>$file</td><td>$localGb GB</td><td>$($row.S3Objects)</td><td>$sync</td><td>$($row.Uploads)</td><td>$uploadedGb GB</td><td>$last</td></tr>"
                            )
                        }

                        $content=@"
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>BackupS3 Report</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;padding:24px;color:#202830}
h1{margin:0 0 8px}
.meta{margin:0 0 18px;color:#66717c}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{border:1px solid #ccd3da;padding:7px;text-align:left;vertical-align:top}
th{background:#eef2f5}
tr:nth-child(even){background:#fafbfc}
</style>
</head>
<body>
<h1>BackupS3 Report</h1>
<p class="meta">Период: с $($since.ToString("dd.MM.yyyy HH:mm")) по $((Get-Date).ToString("dd.MM.yyyy HH:mm"))</p>
<table>
<thead><tr><th>База</th><th>Статус</th><th>Health</th><th>Последний backup</th><th>Размер</th><th>S3 объектов</th><th>Sync</th><th>Загрузок</th><th>Передано</th><th>Последнее событие</th></tr></thead>
<tbody>$($htmlRows.ToString())</tbody>
</table>
</body>
</html>
"@
                        $ctype="text/html; charset=utf-8"
                        $ext="html"
                    }

                    $context.Response.Headers["Content-Disposition"]="attachment; filename=""BackupS3-report-$stamp.$ext"""
                    Write-Text $context 200 $content $ctype
                }
                catch{
                    $detail=$_.Exception.Message
                    if($_.InvocationInfo -and $_.InvocationInfo.PositionMessage){
                        $detail += " | " + ($_.InvocationInfo.PositionMessage -replace "(\r|\n)+"," ")
                    }
                    Write-ServerLog ERROR "Report generation failed: $detail"
                    Write-Text $context 500 ("Ошибка формирования отчёта: "+$detail)
                }
                continue
            }

            if ($path -eq "/api/refresh" -and $context.Request.HttpMethod -eq "POST") {
                try{
                    Assert-NoActiveController

                    $baseConfig = Import-PowerShellDataFile $configFile
                    $managedConfig = Get-ManagedJobsConfig
                    $deletedNames = @($managedConfig.DeletedNames)
                    $baseCount = @($baseConfig.Jobs | Where-Object { [bool]$_.Enabled -and $deletedNames -notcontains [string]$_.Name }).Count
                    $addedCount = @($managedConfig.AddedJobs | Where-Object { [bool]$_.Enabled -and $deletedNames -notcontains [string]$_.Name }).Count

                    Reset-ProgressBeforeRun -Total ($baseCount + $addedCount)
                    Write-ServerLog INFO "API /api/refresh requested"
                    $startedPid = Start-BackupController

                    Write-Text -Context $context -StatusCode 202 -Text (@{status="started";pid=$startedPid}|ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8"
                }catch{
                    $code=if($_.Exception.Message -like "Проверка уже выполняется*"){409}else{500}
                    Write-Text $context $code (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/browse-folder") {
                try {
                    $initialPath = [string]$context.Request.QueryString["initialPath"]

                    $result = Show-FolderBrowser -InitialPath $initialPath

                    $payload = @{
                        cancelled = [bool]$result.Cancelled
                        path      = [string]$result.Path
                    } | ConvertTo-Json -Compress

                    Write-Text -Context $context -StatusCode 200 -Text $payload -ContentType "application/json; charset=utf-8"
                }
                catch {
                    $payload = @{
                        error = $_.Exception.Message
                    } | ConvertTo-Json -Compress

                    Write-Text -Context $context -StatusCode 500 -Text $payload -ContentType "application/json; charset=utf-8"
                }

                continue
            }


            if ($path -eq "/api/s3-folders") {
                try {
                    $bucket = ([string]$context.Request.QueryString["bucket"]).Trim()
                    $profile = ([string]$context.Request.QueryString["profile"]).Trim()

                    if ([string]::IsNullOrWhiteSpace($bucket)) {
                        Write-Text -Context $context -StatusCode 400 -Text '{"error":"Bucket is required"}' -ContentType "application/json; charset=utf-8"
                        continue
                    }

                    $awsResult = Invoke-AwsForDashboard `
                        -Profile $profile `
                        -Arguments @(
                            "s3api",
                            "list-objects-v2",
                            "--bucket", $bucket,
                            "--delimiter", "/",
                            "--max-keys", "1000",
                            "--output", "json"
                        )

                    if ($awsResult.ExitCode -ne 0) {
                        $payload = @{
                            error = "AWS CLI exit $($awsResult.ExitCode): $($awsResult.Output)"
                        } | ConvertTo-Json -Compress

                        Write-Text -Context $context -StatusCode 500 -Text $payload -ContentType "application/json; charset=utf-8"
                        continue
                    }

                    $folders = @()

                    if (-not [string]::IsNullOrWhiteSpace($awsResult.Output)) {
                        $data = $awsResult.Output | ConvertFrom-Json

                        if ($null -ne $data.CommonPrefixes) {
                            $folders = @(
                                $data.CommonPrefixes |
                                    ForEach-Object { ([string]$_.Prefix).Trim("/") } |
                                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                                    Sort-Object -Unique
                            )
                        }
                    }

                    $payload = @{
                        bucket  = $bucket
                        folders = $folders
                    } | ConvertTo-Json -Compress -Depth 5

                    Write-Text -Context $context -StatusCode 200 -Text $payload -ContentType "application/json; charset=utf-8"
                }
                catch {
                    $payload = @{
                        error = $_.Exception.Message
                    } | ConvertTo-Json -Compress

                    Write-Text -Context $context -StatusCode 500 -Text $payload -ContentType "application/json; charset=utf-8"
                }

                continue
            }

            if ($path -eq "/api/jobs/add" -and $context.Request.HttpMethod -eq "POST") {
                $body = Read-JsonBody -Request $context.Request

                if ($null -eq $body) {
                    Write-Text -Context $context -StatusCode 400 -Text '{"error":"empty request"}' -ContentType "application/json; charset=utf-8"
                    continue
                }

                $name = ([string]$body.Name).Trim()
                $localPath = ([string]$body.LocalPath).Trim()
                $bucket = ([string]$body.Bucket).Trim()
                $s3Path = ([string]$body.S3Path).Trim().Trim("/")
                $filePrefix = ([string]$body.FilePrefix).Trim()
                $awsProfile = ([string]$body.AwsProfile).Trim()

                if ([string]::IsNullOrWhiteSpace($name) -or
                    [string]::IsNullOrWhiteSpace($localPath) -or
                    [string]::IsNullOrWhiteSpace($bucket) -or
                    [string]::IsNullOrWhiteSpace($filePrefix)) {
                    Write-Text -Context $context -StatusCode 400 -Text '{"error":"Name, LocalPath, Bucket and FilePrefix are required"}' -ContentType "application/json; charset=utf-8"
                    continue
                }

                if (-not (Test-Path $localPath -PathType Container)) {
                    Write-Text -Context $context -StatusCode 400 -Text '{"error":"LocalPath does not exist or is not a directory"}' -ContentType "application/json; charset=utf-8"
                    continue
                }

                $managed = Get-ManagedJobsConfig
                $baseConfig = Import-PowerShellDataFile $configFile

                $baseJob = @(
                    $baseConfig.Jobs |
                    Where-Object { [string]$_.Name -ieq $name } |
                    Select-Object -First 1
                )

                $addedJob = @(
                    $managed.AddedJobs |
                    Where-Object { [string]$_.Name -ieq $name } |
                    Select-Object -First 1
                )

                $isDeleted = @(
                    $managed.DeletedNames |
                    Where-Object { [string]$_ -ieq $name }
                ).Count -gt 0

                $job = [ordered]@{
                    Name        = $name
                    LocalPath   = $localPath
                    Bucket      = $bucket
                    S3Path      = $s3Path
                    FilePrefix  = $filePrefix
                    AwsProfile  = if ([string]::IsNullOrWhiteSpace($awsProfile)) { $null } else { $awsProfile }
                    MaxAgeHours = if ($null -ne $body.MaxAgeHours) { [int]$body.MaxAgeHours } else { 26 }
                    Keep        = if ($null -ne $body.Keep) { [int]$body.Keep } else { 2 }
                    Enabled     = $true
                }

                if ($baseJob.Count -gt 0 -and $isDeleted) {
                    # The database still exists in BackupJobs.psd1 and was only hidden
                    # through DeletedNames. Re-adding it means RESTORE, not duplicate.
                    $deleted = @(
                        $managed.DeletedNames |
                        Where-Object { [string]$_ -ine $name }
                    )

                    $override = [PSCustomObject]@{
                        LocalPath          = $localPath
                        Bucket             = $bucket
                        S3Path             = $s3Path
                        FilePrefix         = $filePrefix
                        AwsProfile         = if ([string]::IsNullOrWhiteSpace($awsProfile)) { $null } else { $awsProfile }
                        Keep               = [int]$job.Keep
                        MaxAgeHours        = [int]$job.MaxAgeHours
                        ExpectedBackupTime = if($null -ne $baseJob[0].ExpectedBackupTime){[string]$baseJob[0].ExpectedBackupTime}else{""}
                        ExpectedDays       = if($null -ne $baseJob[0].ExpectedDays){[string]$baseJob[0].ExpectedDays}else{"Daily"}
                        GraceMinutes       = if($null -ne $baseJob[0].GraceMinutes){[int]$baseJob[0].GraceMinutes}else{180}
                        SizeAnomalyPercent = if($null -ne $baseJob[0].SizeAnomalyPercent){[int]$baseJob[0].SizeAnomalyPercent}else{35}
                        Enabled            = $true
                    }

                    $ovHash = [ordered]@{}
                    if($null -ne $managed.Overrides){
                        foreach($p in $managed.Overrides.PSObject.Properties){
                            $ovHash[$p.Name] = $p.Value
                        }
                    }
                    $ovHash[$name] = $override

                    Save-ManagedJobsConfig -Config ([PSCustomObject]@{
                        AddedJobs   = @($managed.AddedJobs)
                        DeletedNames = $deleted
                        Overrides   = [PSCustomObject]$ovHash
                    })

                    Write-AuditLog -Action "DB_RESTORE" -Database $name -Message "База восстановлена; LocalPath='$localPath'; Bucket='$bucket'; S3Path='$s3Path'; Prefix='$filePrefix'; Keep=$($job.Keep)"

                    $payload=[ordered]@{
                        status="restored"
                        name=$name
                        localPath=$localPath
                        bucket=$bucket
                        s3Path=$s3Path
                    }|ConvertTo-Json -Compress

                    Write-Text -Context $context -StatusCode 200 -Text $payload -ContentType "application/json; charset=utf-8"
                    continue
                }

                if ($baseJob.Count -gt 0 -or $addedJob.Count -gt 0) {
                    Write-Text -Context $context -StatusCode 409 -Text '{"error":"Database with this name already exists"}' -ContentType "application/json; charset=utf-8"
                    continue
                }

                $added = @($managed.AddedJobs) + @([PSCustomObject]$job)
                $deleted = @(
                    $managed.DeletedNames |
                    Where-Object { [string]$_ -ine $name }
                )

                Save-ManagedJobsConfig -Config ([PSCustomObject]@{
                    AddedJobs = $added
                    DeletedNames = $deleted
                    Overrides = $managed.Overrides
                })

                Write-AuditLog -Action "DB_ADD" -Database $name -Message "Добавлена база; LocalPath='$localPath'; Bucket='$bucket'; S3Path='$s3Path'; Prefix='$filePrefix'; Keep=$($job.Keep)"

                $payload=[ordered]@{
                    status="added"
                    name=$name
                    localPath=$localPath
                    bucket=$bucket
                    s3Path=$s3Path
                }|ConvertTo-Json -Compress

                Write-Text -Context $context -StatusCode 201 -Text $payload -ContentType "application/json; charset=utf-8"
                continue
            }


            if ($path -eq "/api/jobs/check" -and $context.Request.HttpMethod -eq "POST") {
                try {
                    Assert-NoActiveController

                    $body = Read-JsonBody -Request $context.Request
                    $name = if ($null -ne $body) { ([string]$body.Name).Trim() } else { "" }

                    if ([string]::IsNullOrWhiteSpace($name)) {
                        Write-Text -Context $context -StatusCode 400 -Text '{"error":"Name is required"}' -ContentType "application/json; charset=utf-8"
                        continue
                    }

                    if((Get-AllConfiguredJobNames) -notcontains $name){
                        Write-Text -Context $context -StatusCode 404 -Text '{"error":"Database not found"}' -ContentType "application/json; charset=utf-8"
                        continue
                    }

                    Reset-ProgressBeforeRun -Database $name -Total 1
                    $startedPid = Start-BackupController -Database $name

                    $payload = @{
                        status = "started"
                        database = $name
                        pid = $startedPid
                    } | ConvertTo-Json -Compress

                    Write-Text -Context $context -StatusCode 202 -Text $payload -ContentType "application/json; charset=utf-8"
                }
                catch {
                    $code=if($_.Exception.Message -like "Проверка уже выполняется*"){409}else{500}
                    $payload = @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
                    Write-Text -Context $context -StatusCode $code -Text $payload -ContentType "application/json; charset=utf-8"
                }

                continue
            }




            if ($path -eq "/api/jobs/local-files" -and $context.Request.HttpMethod -eq "GET") {
                try {
                    $name = ([string]$context.Request.QueryString["name"]).Trim()
                    if ([string]::IsNullOrWhiteSpace($name)) {
                        Write-Text $context 400 '{"error":"Name is required"}' "application/json; charset=utf-8"
                        continue
                    }

                    $job = Get-EffectiveJobConfig $name
                    if ($null -eq $job) {
                        Write-Text $context 404 '{"error":"job not found"}' "application/json; charset=utf-8"
                        continue
                    }

                    if (-not (Test-Path ([string]$job.LocalPath) -PathType Container)) {
                        throw "Локальная папка недоступна: $($job.LocalPath)"
                    }

                    $files = @(
                        Get-ChildItem -Path ([string]$job.LocalPath) -File |
                        Where-Object {
                            $_.Name.StartsWith(
                                [string]$job.FilePrefix,
                                [System.StringComparison]::OrdinalIgnoreCase
                            )
                        } |
                        Sort-Object LastWriteTime -Descending |
                        ForEach-Object {
                            [PSCustomObject]@{
                                Name          = $_.Name
                                FullName      = $_.FullName
                                SizeBytes     = [Int64]$_.Length
                                LastWriteTime = $_.LastWriteTime.ToString("o")
                            }
                        }
                    )

                    # LIVE S3 reconciliation.
                    # v21.11 used state.json here, therefore «Проверить Local» could say
                    # «Нет на S3» immediately after a successful upload until a full
                    # BackupS3 check refreshed state.json.
                    $root = ([string]$job.S3Path).Trim("/")
                    $prefix = if($root){"$root/$($job.FilePrefix)"}else{[string]$job.FilePrefix}
                    $s3Keys = @()
                    $s3LiveChecked = $false
                    $s3LiveError = ""

                    try{
                        $awsResult = Invoke-AwsForDashboard `
                            -Profile ([string]$job.AwsProfile) `
                            -Arguments @(
                                "s3api","list-objects-v2",
                                "--bucket",[string]$job.Bucket,
                                "--prefix",$prefix,
                                "--output","json"
                            )

                        if($awsResult.ExitCode -eq 0){
                            $s3LiveChecked=$true
                            if(-not[string]::IsNullOrWhiteSpace($awsResult.Output)){
                                $s3Data=$awsResult.Output|ConvertFrom-Json
                                if($null -ne $s3Data.Contents){
                                    $s3Keys=@($s3Data.Contents|ForEach-Object{[string]$_.Key})
                                }
                            }
                        }else{
                            $s3LiveError="AWS CLI exit $($awsResult.ExitCode): $($awsResult.Output)"
                        }
                    }catch{
                        $s3LiveError=$_.Exception.Message
                    }

                    # Fallback to state only when live AWS lookup failed.
                    if((-not $s3LiveChecked) -and (Test-Path $stateFile)){
                        try{
                            $st=Get-Content $stateFile -Raw -Encoding UTF8|ConvertFrom-Json
                            $sj=@($st.Jobs|Where-Object{[string]$_.Name -ieq $name}|Select-Object -First 1)
                            if($sj.Count){
                                $s3Keys=@($sj[0].S3Objects|ForEach-Object{[string]$_.Key})
                            }
                        }catch{}
                    }

                    $result = @(
                        $files | ForEach-Object {
                            $key = if ($root) { "$root/$($_.Name)" } else { $_.Name }
                            [PSCustomObject]@{
                                Name          = $_.Name
                                FullName      = $_.FullName
                                SizeBytes     = $_.SizeBytes
                                LastWriteTime = $_.LastWriteTime
                                S3Key         = $key
                                OnS3          = ($s3Keys -contains $key)
                            }
                        }
                    )

                    $payload = [ordered]@{
                        name       = [string]$job.Name
                        localPath  = [string]$job.LocalPath
                        bucket     = [string]$job.Bucket
                        s3Path     = [string]$job.S3Path
                        count      = $result.Count
                        files      = @($result)
                        s3LiveChecked = $s3LiveChecked
                        s3LiveError = $s3LiveError
                        checkedAt  = (Get-Date).ToString("o")
                    }

                    Write-Text $context 200 ($payload | ConvertTo-Json -Depth 10) "application/json; charset=utf-8"
                }
                catch {
                    Write-Text $context 500 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/jobs/local-upload" -and $context.Request.HttpMethod -eq "POST") {
                try {
                    $runtime = Get-RuntimeSettingsForServer

                    if ([bool]$runtime.SafeMode -or -not [bool]$runtime.EnableUpload) {
                        Write-Text $context 403 '{"error":"Для ручной загрузки выключи SafeMode и включи Upload в Настройках"}' "application/json; charset=utf-8"
                        continue
                    }

                    $body = Read-JsonBody -Request $context.Request
                    $name = ([string]$body.Name).Trim()
                    $filePath = ([string]$body.FilePath).Trim()

                    $job = Get-EffectiveJobConfig $name
                    if ($null -eq $job) { throw "job not found" }

                    $file = Get-ValidatedLocalBackupFile -Job $job -FilePath $filePath

                    if (-not (Test-Path $manualUploadScript -PathType Leaf)) {
                        throw "Manual-Upload.ps1 не найден: $manualUploadScript"
                    }

                    $operationId = [Guid]::NewGuid().ToString()
                    $statusPath = Get-ManualUploadStatusPath $operationId

                    $initial = [ordered]@{
                        id          = $operationId
                        database    = $name
                        file        = $file.Name
                        filePath    = $file.FullName
                        sizeBytes   = [Int64]$file.Length
                        status      = "STARTING"
                        percent     = 0
                        message     = "Запуск загрузки"
                        startedAt   = (Get-Date).ToString("o")
                        finishedAt  = $null
                        s3Key       = $null
                        speedMBps   = $null
                        durationSec = $null
                    }
                    $initial | ConvertTo-Json -Depth 6 | Set-Content $statusPath -Encoding UTF8

                    $powershellExe = (Get-Process -Id $PID).Path
                    $args = @(
                        "-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass",
                        "-File","`"$manualUploadScript`"",
                        "-RootPath","`"$script:AppRoot`"",
                        "-Database","`"$name`"",
                        "-FilePath","`"$($file.FullName)`"",
                        "-OperationId","`"$operationId`""
                    )

                    Start-Process -FilePath $powershellExe -ArgumentList $args `
                        -WorkingDirectory $script:AppRoot -WindowStyle Hidden | Out-Null

                    Write-AuditLog -Action "MANUAL_UPLOAD_START" -Database $name -Message "Запущена ручная загрузка; file='$($file.Name)'; size=$([Int64]$file.Length); operationId=$operationId"

                    Write-Text $context 202 (@{
                        status="started"
                        operationId=$operationId
                        safeMode=[bool]$runtime.SafeMode
                        enableUpload=[bool]$runtime.EnableUpload
                    } | ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                catch {
                    Write-Text $context 500 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/jobs/local-upload-status" -and $context.Request.HttpMethod -eq "GET") {
                try {
                    $id = ([string]$context.Request.QueryString["id"]).Trim()
                    $statusPath = Get-ManualUploadStatusPath $id

                    if (-not (Test-Path $statusPath -PathType Leaf)) {
                        Write-Text $context 404 '{"error":"operation not found"}' "application/json; charset=utf-8"
                        continue
                    }

                    $json = Get-Content $statusPath -Raw -Encoding UTF8
                    Write-Text $context 200 $json "application/json; charset=utf-8"
                }
                catch {
                    Write-Text $context 500 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/jobs/s3-objects" -and $context.Request.HttpMethod -eq "GET") {
                try {
                    $name = ([string]$context.Request.QueryString["name"]).Trim()

                    if ([string]::IsNullOrWhiteSpace($name)) {
                        Write-Text $context 400 '{"error":"Name is required"}' "application/json; charset=utf-8"
                        continue
                    }

                    $job = Get-EffectiveJobConfig $name
                    if ($null -eq $job) {
                        Write-Text $context 404 '{"error":"job not found"}' "application/json; charset=utf-8"
                        continue
                    }

                    $s3Root = ([string]$job.S3Path).Trim("/")
                    $prefix = if ($s3Root) {
                        "$s3Root/$($job.FilePrefix)"
                    }
                    else {
                        [string]$job.FilePrefix
                    }

                    $result = Invoke-AwsForDashboard `
                        -Profile ([string]$job.AwsProfile) `
                        -Arguments @(
                            "s3api",
                            "list-objects-v2",
                            "--bucket", [string]$job.Bucket,
                            "--prefix", $prefix,
                            "--output", "json"
                        )

                    if ($result.ExitCode -ne 0) {
                        throw "AWS CLI exit $($result.ExitCode): $($result.Output)"
                    }

                    $objects = @()

                    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
                        $data = $result.Output | ConvertFrom-Json

                        if ($null -ne $data.Contents) {
                            $objects = @(
                                $data.Contents |
                                    Sort-Object { [datetime]$_.LastModified } -Descending |
                                    ForEach-Object {
                                        [PSCustomObject]@{
                                            Key          = [string]$_.Key
                                            SizeBytes    = [Int64]$_.Size
                                            LastModified = ([datetime]$_.LastModified).ToString("o")
                                        }
                                    }
                            )
                        }
                    }

                    $payload = [ordered]@{
                        name    = [string]$job.Name
                        bucket  = [string]$job.Bucket
                        s3Path  = [string]$job.S3Path
                        prefix  = $prefix
                        count   = $objects.Count
                        objects = @($objects)
                        checkedAt = (Get-Date).ToString("o")
                    }

                    Write-Text $context 200 ($payload | ConvertTo-Json -Depth 10) "application/json; charset=utf-8"
                }
                catch {
                    Write-Text $context 500 (@{error=$_.Exception.Message} | ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }

                continue
            }

            if ($path -eq "/api/jobs/detail" -and $context.Request.HttpMethod -eq "GET") {
                try{
                    $name=([string]$context.Request.QueryString["name"]).Trim()
                    if([string]::IsNullOrWhiteSpace($name)){
                        Write-Text $context 400 '{"error":"Name is required"}' "application/json; charset=utf-8";continue
                    }

                    $job=Get-EffectiveJobConfig $name
                    if($null -eq $job){
                        Write-Text $context 404 '{"error":"job not found"}' "application/json; charset=utf-8";continue
                    }

                    $stateJob=$null
                    if(Test-Path $stateFile){
                        try{
                            $st=Get-Content $stateFile -Raw -Encoding UTF8|ConvertFrom-Json
                            $x=@($st.Jobs|Where-Object{[string]$_.Name -ieq $name}|Select-Object -First 1)
                            if($x.Count){$stateJob=$x[0]}
                        }catch{}
                    }

                    $payload=[ordered]@{
                        Name=$job.Name
                        LocalPath=$job.LocalPath
                        Bucket=$job.Bucket
                        S3Path=$job.S3Path
                        FilePrefix=$job.FilePrefix
                        AwsProfile=$job.AwsProfile
                        Keep=[int]$job.Keep
                        MaxAgeHours=[int]$job.MaxAgeHours
                        ExpectedBackupTime=$job.ExpectedBackupTime
                        ExpectedDays=$job.ExpectedDays
                        GraceMinutes=[int]$job.GraceMinutes
                        SizeAnomalyPercent=[int]$job.SizeAnomalyPercent
                        Enabled=[bool]$job.Enabled
                        S3Latest=if($stateJob){$stateJob.S3Latest}else{$null}
                        SyncStatus=if($stateJob){$stateJob.SyncStatus}else{$null}
                        S3Objects=if($stateJob){@($stateJob.S3Objects)}else{@()}
                        LocalFile=if($stateJob){$stateJob.LocalFile}else{$null}
                        LastChecked=if($stateJob){$stateJob.LastChecked}else{$null}
                    }

                    Write-Text $context 200 ($payload|ConvertTo-Json -Depth 10) "application/json; charset=utf-8"
                }catch{
                    Write-Text $context 500 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/jobs/update" -and $context.Request.HttpMethod -eq "POST") {
                try{
                    $body=Read-JsonBody -Request $context.Request
                    $name=([string]$body.Name).Trim()
                    if([string]::IsNullOrWhiteSpace($name)){throw "Name is required"}

                    if(-not(Test-Path ([string]$body.LocalPath) -PathType Container)){
                        throw "LocalPath does not exist or is not a directory"
                    }

                    if([int]$body.Keep -lt 1 -or [int]$body.Keep -gt 100){throw "Keep: 1..100"}
                    if([int]$body.GraceMinutes -lt 0 -or [int]$body.GraceMinutes -gt 1440){throw "GraceMinutes: 0..1440"}

                    $override=[PSCustomObject]@{
                        LocalPath=([string]$body.LocalPath).Trim()
                        Bucket=([string]$body.Bucket).Trim()
                        S3Path=([string]$body.S3Path).Trim().Trim("/")
                        FilePrefix=([string]$body.FilePrefix).Trim()
                        AwsProfile=if([string]::IsNullOrWhiteSpace([string]$body.AwsProfile)){$null}else{([string]$body.AwsProfile).Trim()}
                        Keep=[int]$body.Keep
                        MaxAgeHours=[int]$body.MaxAgeHours
                        ExpectedBackupTime=([string]$body.ExpectedBackupTime).Trim()
                        ExpectedDays=([string]$body.ExpectedDays).Trim()
                        GraceMinutes=[int]$body.GraceMinutes
                        SizeAnomalyPercent=[int]$body.SizeAnomalyPercent
                        Enabled=[bool]$body.Enabled
                    }

                    Set-JobOverride -Name $name -Override $override
                    Write-AuditLog -Action "DB_UPDATE" -Database $name -Message "Изменены параметры базы; LocalPath='$($override.LocalPath)'; Bucket='$($override.Bucket)'; S3Path='$($override.S3Path)'; Prefix='$($override.FilePrefix)'; Keep=$($override.Keep); MaxAgeHours=$($override.MaxAgeHours); ExpectedBackupTime='$($override.ExpectedBackupTime)'; Enabled=$($override.Enabled)"
                    Write-Text $context 200 '{"status":"updated"}' "application/json; charset=utf-8"
                }catch{
                    Write-Text $context 400 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/s3/object/delete" -and $context.Request.HttpMethod -eq "POST") {
                try{
                    $settings=Get-RuntimeSettingsForServer
                    if([bool]$settings.SafeMode -or -not [bool]$settings.EnableCleanup){
                        Write-Text $context 403 '{"error":"Для удаления выключи SafeMode и включи Cleanup в Настройках"}' "application/json; charset=utf-8"
                        continue
                    }

                    $body=Read-JsonBody -Request $context.Request
                    $name=([string]$body.Name).Trim()
                    $key=([string]$body.Key).Trim()
                    if(-not $name -or -not $key){throw "Name and Key are required"}

                    $job=Get-EffectiveJobConfig $name
                    if($null -eq $job){throw "job not found"}

                    # Никогда не позволяем удалить последний локально-синхронизированный объект текущего backup.
                    if(Test-Path $stateFile){
                        $st=Get-Content $stateFile -Raw -Encoding UTF8|ConvertFrom-Json
                        $sj=@($st.Jobs|Where-Object{[string]$_.Name -ieq $name}|Select-Object -First 1)[0]
                        if($sj -and [string]$sj.S3Key -ceq $key){
                            Write-Text $context 409 '{"error":"Нельзя удалить текущий последний backup"}' "application/json; charset=utf-8"
                            continue
                        }
                    }

                    $base=Import-PowerShellDataFile $configFile
                    $args=@("--endpoint-url",$base.Global.EndpointUrl)
                    if(-not [string]::IsNullOrWhiteSpace([string]$job.AwsProfile)){
                        $args+=@("--profile",[string]$job.AwsProfile)
                    }
                    $args+=@("s3api","delete-object","--bucket",[string]$job.Bucket,"--key",$key)

                    $out=& aws @args 2>&1
                    if($LASTEXITCODE -ne 0){throw ($out -join [Environment]::NewLine)}

                    Write-AuditLog -Action "S3_OBJECT_DELETE" -Database $name -Message "Удалён объект S3; key='$key'; bucket='$($job.Bucket)'"
                    Write-Text $context 200 '{"status":"deleted"}' "application/json; charset=utf-8"
                }catch{
                    Write-AuditLog -Action "S3_OBJECT_DELETE_FAILED" -Database $name -Message $_.Exception.Message -Level "ERROR"
                    Write-Text $context 500 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/jobs/delete" -and $context.Request.HttpMethod -eq "POST") {
                $body = Read-JsonBody -Request $context.Request
                $name = ([string]$body.Name).Trim()

                if ([string]::IsNullOrWhiteSpace($name)) {
                    Write-Text -Context $context -StatusCode 400 -Text '{"error":"Name is required"}' -ContentType "application/json; charset=utf-8"
                    continue
                }

                $base = Import-PowerShellDataFile $configFile
                $baseNames = @($base.Jobs | ForEach-Object { [string]$_.Name })

                $managed = Get-ManagedJobsConfig
                $added = @($managed.AddedJobs | Where-Object { [string]$_.Name -ne $name })
                $deleted = @($managed.DeletedNames)

                if ($baseNames -contains $name) {
                    if ($deleted -notcontains $name) {
                        $deleted += $name
                    }
                }
                else {
                    $deleted = @($deleted | Where-Object { $_ -ne $name })
                }

                Save-ManagedJobsConfig -Config ([PSCustomObject]@{
                    AddedJobs = $added
                    DeletedNames = $deleted
                    Overrides = $managed.Overrides
                })

                Write-AuditLog -Action "DB_DELETE" -Database $name -Message "База удалена из Dashboard-конфигурации"
                Write-Text -Context $context -StatusCode 200 -Text '{"status":"deleted"}' -ContentType "application/json; charset=utf-8"
                continue
            }


            if ($path -eq "/api/maintenance/set" -and $context.Request.HttpMethod -eq "POST") {
                $body=Read-JsonBody -Request $context.Request
                $name=([string]$body.Name).Trim()
                $hours=if($body.Hours){[double]$body.Hours}else{2}
                $reason=([string]$body.Reason).Trim()
                $cfg=Get-MaintenanceConfig
                $h=@{}
                foreach($p in $cfg.PSObject.Properties){$h[$p.Name]=$p.Value}
                $h[$name]=[PSCustomObject]@{until=(Get-Date).AddHours($hours).ToString("o");reason=$reason}
                Save-MaintenanceConfig ([PSCustomObject]$h)
                Write-AuditLog -Action "MAINTENANCE_SET" -Database $name -Message "Пауза включена на $hours ч.; причина='$reason'"
                Write-Text $context 200 '{"status":"maintenance_set"}' "application/json; charset=utf-8";continue
            }

            if ($path -eq "/api/maintenance/clear" -and $context.Request.HttpMethod -eq "POST") {
                $body=Read-JsonBody -Request $context.Request;$name=([string]$body.Name).Trim()
                $cfg=Get-MaintenanceConfig;$h=@{}
                foreach($p in $cfg.PSObject.Properties){if($p.Name -ne $name){$h[$p.Name]=$p.Value}}
                Save-MaintenanceConfig ([PSCustomObject]$h)
                Write-AuditLog -Action "MAINTENANCE_CLEAR" -Database $name -Message "Пауза снята"
                Write-Text $context 200 '{"status":"maintenance_cleared"}' "application/json; charset=utf-8";continue
            }

            if ($path -eq "/api/retention/preview" -and $context.Request.HttpMethod -eq "POST") {
                $body=Read-JsonBody -Request $context.Request;$name=([string]$body.Name).Trim()
                if(-not(Test-Path $stateFile)){Write-Text $context 404 '{"error":"state not found"}' "application/json; charset=utf-8";continue}
                $s=Get-Content $stateFile -Raw -Encoding UTF8|ConvertFrom-Json
                $j=@($s.Jobs|Where-Object{$_.Name -eq $name}|Select-Object -First 1)[0]
                if($null -eq $j){Write-Text $context 404 '{"error":"job not found"}' "application/json; charset=utf-8";continue}
                $runtime=Get-RuntimeSettingsForServer
                $payload=@{
                    name=$name
                    keep=$j.Keep
                    candidates=@($j.RetentionCandidates)
                    enabled=(-not [bool]$runtime.SafeMode)
                    autoCleanup=([bool]$runtime.EnableCleanup -and -not [bool]$runtime.SafeMode)
                    safeMode=[bool]$runtime.SafeMode
                }|ConvertTo-Json -Depth 8
                Write-Text $context 200 $payload "application/json; charset=utf-8";continue
            }

            if ($path -eq "/api/retention/apply" -and $context.Request.HttpMethod -eq "POST") {
                $cfg=Import-PowerShellDataFile $configFile
                $runtimeSettings=Get-RuntimeSettingsForServer
                if([bool]$runtimeSettings.SafeMode){
                    Write-Text $context 403 '{"error":"Ручное удаление старых backup заблокировано безопасным режимом"}' "application/json; charset=utf-8";continue
                }
                $body=Read-JsonBody -Request $context.Request;$name=([string]$body.Name).Trim()
                $s=Get-Content $stateFile -Raw -Encoding UTF8|ConvertFrom-Json
                $j=@($s.Jobs|Where-Object{$_.Name -eq $name}|Select-Object -First 1)[0]
                if($null -eq $j -or $j.SyncStatus -ne "SYNCED"){Write-Text $context 409 '{"error":"latest backup is not safely synced"}' "application/json; charset=utf-8";continue}
                $deleted=@()
                foreach($c in @($j.RetentionCandidates)){
                    if($c.Key -eq $j.S3Key){continue}
                    $profile=""
                    # resolve profile from base/managed jobs
                    $base=Import-PowerShellDataFile $configFile
                    $jobCfg=@($base.Jobs|Where-Object{$_.Name -eq $name}|Select-Object -First 1)[0]
                    if($jobCfg){$profile=[string]$jobCfg.AwsProfile}
                    $args=@("--endpoint-url",$base.Global.EndpointUrl)
                    if($profile){$args+=@("--profile",$profile)}
                    $args+=@("s3api","delete-object","--bucket",$j.Bucket,"--key",$c.Key)
                    & aws @args 2>&1|Out-Null
                    if($LASTEXITCODE -eq 0){$deleted+=$c.Key}
                }
                Write-Text $context 200 (@{status="done";deleted=$deleted}|ConvertTo-Json -Depth 5) "application/json; charset=utf-8";continue
            }



            if ($path -eq "/api/ui-settings" -and $context.Request.HttpMethod -eq "GET") {
                $u=Get-UiSettings
                Write-Text $context 200 ($u|ConvertTo-Json -Depth 10) "application/json; charset=utf-8"
                continue
            }

            if ($path -eq "/api/ui-settings/job" -and $context.Request.HttpMethod -eq "POST") {
                try{
                    $body=Read-JsonBody -Request $context.Request
                    $name=([string]$body.Name).Trim()
                    if([string]::IsNullOrWhiteSpace($name)){throw "Name is required"}

                    $allowed=@("Normal","High","Critical","Low")
                    $priority=([string]$body.Priority).Trim()
                    if($allowed -notcontains $priority){$priority="Normal"}

                    $accent=([string]$body.Accent).Trim()
                    $allowedAccents=@("default","red","orange","yellow","green","blue","purple")
                    if($allowedAccents -notcontains $accent){$accent="default"}

                    $u=Get-UiSettings
                    $jobsHash=[ordered]@{}
                    foreach($p in $u.Jobs.PSObject.Properties){$jobsHash[$p.Name]=$p.Value}

                    $jobsHash[$name]=[PSCustomObject]@{
                        Pinned=[bool]$body.Pinned
                        Priority=$priority
                        Accent=$accent
                        Alias=(Repair-Utf8Mojibake ([string]$body.Alias).Trim())
                        Group=(Repair-Utf8Mojibake ([string]$body.Group).Trim())
                        Note=(Repair-Utf8Mojibake ([string]$body.Note).Trim())
                    }

                    Save-UiSettings ([PSCustomObject]@{
                        Jobs=[PSCustomObject]$jobsHash
                        DefaultSort=[string]$u.DefaultSort
                        ShowFavorites=[bool]$u.ShowFavorites
                    })

                    Write-AuditLog -Action "DB_UI_UPDATE" -Database $name -Message "Изменено отображение; Priority='$priority'; Accent='$accent'; Pinned=$([bool]$body.Pinned); Alias='$([string]$body.Alias)'; Group='$([string]$body.Group)'"
                    Write-Text $context 200 '{"status":"saved"}' "application/json; charset=utf-8"
                }catch{
                    Write-Text $context 400 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/ui-settings/global" -and $context.Request.HttpMethod -eq "POST") {
                try{
                    $body=Read-JsonBody -Request $context.Request
                    $u=Get-UiSettings
                    $sort=([string]$body.DefaultSort).Trim()
                    if(@("priority","name","age","size","next") -notcontains $sort){$sort="priority"}

                    Save-UiSettings ([PSCustomObject]@{
                        Jobs=$u.Jobs
                        DefaultSort=$sort
                        ShowFavorites=[bool]$body.ShowFavorites
                    })

                    Write-AuditLog -Action "UI_SETTINGS_UPDATE" -Message "Изменены настройки интерфейса; DefaultSort='$sort'; ShowFavorites=$([bool]$body.ShowFavorites)"
                    Write-Text $context 200 '{"status":"saved"}' "application/json; charset=utf-8"
                }catch{
                    Write-Text $context 400 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/settings" -and $context.Request.HttpMethod -eq "GET") {
                $s=Get-RuntimeSettingsForServer
                Write-Text $context 200 ($s|ConvertTo-Json -Compress -Depth 5) "application/json; charset=utf-8"
                continue
            }

            if ($path -eq "/api/settings" -and $context.Request.HttpMethod -eq "POST") {
                try{
                    $body=Read-JsonBody -Request $context.Request
                    if($null -eq $body){
                        Write-Text $context 400 '{"error":"empty request"}' "application/json; charset=utf-8"
                        continue
                    }

                    # Диапазоны, чтобы нельзя было случайно выставить опасные/бессмысленные значения.
                    if([int]$body.MinFileIdleMinutes -lt 1 -or [int]$body.MinFileIdleMinutes -gt 120){throw "MinFileIdleMinutes: 1..120"}
                    if([int]$body.RetryCount -lt 1 -or [int]$body.RetryCount -gt 10){throw "RetryCount: 1..10"}
                    if([int]$body.RetryDelaySeconds -lt 5 -or [int]$body.RetryDelaySeconds -gt 600){throw "RetryDelaySeconds: 5..600"}
                    if([int]$body.HistoryDays -lt 1 -or [int]$body.HistoryDays -gt 365){throw "HistoryDays: 1..365"}
                    if([int]$body.DefaultSizeAnomalyPercent -lt 5 -or [int]$body.DefaultSizeAnomalyPercent -gt 500){throw "DefaultSizeAnomalyPercent: 5..500"}
                    if([int]$body.AutoRefreshSeconds -lt 10 -or [int]$body.AutoRefreshSeconds -gt 3600){throw "AutoRefreshSeconds: 10..3600"}
                    if([int]$body.AutoSchedulerIntervalMinutes -lt 1 -or [int]$body.AutoSchedulerIntervalMinutes -gt 60){throw "AutoSchedulerIntervalMinutes: 1..60"}

                    # IMPORTANT: Scheduled Task is touched ONLY when user presses Save.
                    # There is no scheduler polling/background request in the Dashboard.
                    Apply-AutoSchedulerSetting `
                        -Enabled ([bool]$body.AutoSchedulerEnabled) `
                        -IntervalMinutes ([int]$body.AutoSchedulerIntervalMinutes)

                    Save-RuntimeSettingsForServer $body
                    Write-AuditLog -Action "RUNTIME_SETTINGS_UPDATE" -Message "Изменены настройки; SafeMode=$([bool]$body.SafeMode); Upload=$([bool]$body.EnableUpload); Cleanup=$([bool]$body.EnableCleanup); Graylog=$([bool]$body.EnableGraylog); RetryCount=$([int]$body.RetryCount); RetryDelay=$([int]$body.RetryDelaySeconds)s; AutoRefresh=$([int]$body.AutoRefreshSeconds)s; AutoScheduler=$([bool]$body.AutoSchedulerEnabled); SchedulerInterval=$([int]$body.AutoSchedulerIntervalMinutes)min"
                    Write-Text $context 200 '{"status":"saved"}' "application/json; charset=utf-8"
                }catch{
                    Write-Text $context 400 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }


            if ($path -eq "/api/log" -and $context.Request.HttpMethod -eq "GET") {
                try {
                    $source = ([string]$context.Request.QueryString["source"]).Trim().ToLowerInvariant()
                    $lines = if($source -in @("server","audit")){100}else{250}
                    if ($context.Request.QueryString["lines"]) {
                        [int]$requested = 0
                        if ([int]::TryParse([string]$context.Request.QueryString["lines"], [ref]$requested)) {
                            $lines = [Math]::Max(20, [Math]::Min(2000, $requested))
                        }
                    }

                    $database = ([string]$context.Request.QueryString["database"]).Trim()
                    $level = ([string]$context.Request.QueryString["level"]).Trim().ToUpperInvariant()
                    $query = ([string]$context.Request.QueryString["q"]).Trim()
                    $selectedLogFile = switch($source){
                        "server" {$serverLogFile}
                        "audit" {$auditLogFile}
                        default {$controllerLogFile}
                    }

                    $items = @()

                    if (Test-Path $selectedLogFile -PathType Leaf) {
                        $items = @(
                            Get-SafeLogTail -Path $selectedLogFile -Lines $lines
                        )

                        if (-not [string]::IsNullOrWhiteSpace($database)) {
                            $needle = "[$database]"
                            $items = @($items | Where-Object { $_ -like "*$needle*" })
                        }

                        if ($level -in @("INFO","WARN","ERROR")) {
                            $levelNeedle = "[$level]"
                            $items = @($items | Where-Object { $_ -like "*$levelNeedle*" })
                        }

                        if (-not [string]::IsNullOrWhiteSpace($query)) {
                            $items = @($items | Where-Object { $_ -like "*$query*" })
                        }
                    }

                    $lastWrite = $null
                    $sizeBytes = 0

                    if (Test-Path $selectedLogFile -PathType Leaf) {
                        $fi = Get-Item $selectedLogFile
                        $lastWrite = $fi.LastWriteTime.ToString("o")
                        $sizeBytes = [Int64]$fi.Length
                    }

                    $payload = [ordered]@{
                        file       = $selectedLogFile
                        source     = if($source -in @("server","audit")){$source}else{"controller"}
                        exists     = (Test-Path $selectedLogFile -PathType Leaf)
                        lastWrite  = $lastWrite
                        sizeBytes  = $sizeBytes
                        count      = @($items).Count
                        responseChars = [int](($items | ForEach-Object { ([string]$_).Length + 1 } | Measure-Object -Sum).Sum)
                        lines      = @($items)
                        checkedAt  = (Get-Date).ToString("o")
                    }

                    Write-Text $context 200 ($payload | ConvertTo-Json -Depth 5) "application/json; charset=utf-8"
                }
                catch {
                    Write-Text $context 500 (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json; charset=utf-8"
                }
                continue
            }

            if ($path -eq "/api/progress" -and $context.Request.HttpMethod -eq "GET") {
                if (-not (Test-Path $progressFile)) {
                    Write-Text -Context $context -StatusCode 200 -Text '{"running":false,"current":0,"total":0,"percent":0,"database":"","phase":"IDLE","message":"Ожидание запуска"}' -ContentType "application/json; charset=utf-8"
                    continue
                }

                $progressJson = Get-Content $progressFile -Raw -Encoding UTF8
                Write-Text -Context $context -StatusCode 200 -Text $progressJson -ContentType "application/json; charset=utf-8"
                continue
            }

            if ($path -eq "/api/state" -and $context.Request.HttpMethod -eq "GET") {
                if (-not (Test-Path $stateFile)) {
                    Write-Text -Context $context -StatusCode 404 -Text '{"error":"state not found"}' -ContentType "application/json; charset=utf-8"
                    continue
                }

                $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $payload = @{
                    generatedAt      = $state.GeneratedAt
                    generatedDisplay = if ($state.GeneratedAt) { ([datetime]$state.GeneratedAt).ToString("dd.MM.yyyy HH:mm:ss") } else { "" }
                } | ConvertTo-Json -Compress

                Write-Text -Context $context -StatusCode 200 -Text $payload -ContentType "application/json; charset=utf-8"
                continue
            }

            if ($context.Request.HttpMethod -ne "GET") {
                Write-Text -Context $context -StatusCode 405 -Text "Method Not Allowed"
                continue
            }

            $relative = $path.TrimStart("/")
            if ([string]::IsNullOrWhiteSpace($relative)) {
                $relative = "index.html"
            }

            # Защита от path traversal.
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $webRoot $relative))
            if (-not $candidate.StartsWith($webRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Text -Context $context -StatusCode 403 -Text "Forbidden"
                continue
            }

            if (-not (Test-Path $candidate -PathType Leaf)) {
                Write-Text -Context $context -StatusCode 404 -Text "Not Found"
                continue
            }

            $bytes = [System.IO.File]::ReadAllBytes($candidate)
            Write-Response `
                -Context $context `
                -StatusCode 200 `
                -ContentType (Get-ContentType $candidate) `
                -Body $bytes
        }
        catch {
            try {
                Write-Text -Context $context -StatusCode 500 -Text $_.Exception.Message
            }
            catch {}
        }
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
}
