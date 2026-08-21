param(
    [Parameter(Mandatory=$true)][string]$RootPath,
    [Parameter(Mandatory=$true)][string]$Database,
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string]$OperationId
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

$root = [System.IO.Path]::GetFullPath($RootPath)
$configFile = Join-Path $root "BackupJobs.psd1"
$managedFile = Join-Path $root "State\managed-jobs.json"
$settingsFile = Join-Path $root "State\settings.json"
$statusDir = Join-Path $root "State\ManualUploads"
$statusFile = Join-Path $statusDir "$OperationId.json"
$logFile = Join-Path $statusDir "$OperationId.log"

function Write-UploadLog {
    param([string]$Message)
    try {
        Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -Encoding UTF8
    } catch {}
}

function Write-Status {
    param(
        [string]$Status,
        [int]$Percent,
        [string]$Message,
        [string]$S3Key = "",
        [Nullable[double]]$DurationSec = $null,
        [Nullable[double]]$SpeedMBps = $null,
        [string]$FinishedAt = "",
        [Int64]$UploadedBytes = 0,
        [Int64]$RemainingBytes = 0,
        [string]$SpeedText = ""
    )

    $item = Get-Item $FilePath -ErrorAction SilentlyContinue
    $obj = [ordered]@{
        id          = $OperationId
        database    = $Database
        file        = if($item){$item.Name}else{[System.IO.Path]::GetFileName($FilePath)}
        filePath    = $FilePath
        sizeBytes   = if($item){[Int64]$item.Length}else{0}
        status      = $Status
        percent     = $Percent
        message     = if([string]::IsNullOrWhiteSpace($Message)){"Неизвестная ошибка. См. лог операции."}else{$Message}
        logFile     = $logFile
        startedAt   = $script:StartedAt
        finishedAt  = if($FinishedAt){$FinishedAt}else{$null}
        s3Key       = if($S3Key){$S3Key}else{$null}
        speedMBps   = $SpeedMBps
        speedText   = $SpeedText
        uploadedBytes = $UploadedBytes
        remainingBytes = $RemainingBytes
        durationSec = $DurationSec
    }

    $tmp="$statusFile.tmp"
    $obj|ConvertTo-Json -Depth 6|Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $statusFile -Force
}

function Get-Managed {
    if(-not(Test-Path $managedFile)){
        return [PSCustomObject]@{AddedJobs=@();DeletedNames=@();Overrides=[PSCustomObject]@{}}
    }
    try{return Get-Content $managedFile -Raw -Encoding UTF8|ConvertFrom-Json}
    catch{return [PSCustomObject]@{AddedJobs=@();DeletedNames=@();Overrides=[PSCustomObject]@{}}}
}

function Get-Job {
    param([string]$Name)
    $cfg=Import-PowerShellDataFile $configFile
    $m=Get-Managed

    $j=@($cfg.Jobs|Where-Object{[string]$_.Name -ieq $Name}|Select-Object -First 1)
    $job=if($j.Count){$j[0]}else{$null}
    if($null -eq $job){
        $a=@($m.AddedJobs|Where-Object{[string]$_.Name -ieq $Name}|Select-Object -First 1)
        if($a.Count){$job=$a[0]}
    }
    if($null -eq $job){return $null}

    $copy=[ordered]@{}
    if($job -is [Collections.IDictionary]){
        foreach($k in $job.Keys){$copy[$k]=$job[$k]}
    }else{
        foreach($p in $job.PSObject.Properties){$copy[$p.Name]=$p.Value}
    }

    if($m.Overrides){
        $p=$m.Overrides.PSObject.Properties[$Name]
        if($p){
            foreach($x in $p.Value.PSObject.Properties){$copy[$x.Name]=$x.Value}
        }
    }
    return [PSCustomObject]$copy
}



function Convert-TransferUnitToBytes {
    param([double]$Value,[string]$Unit)
    switch($Unit){
        "Bytes"{[Int64][math]::Round($Value)}
        "B"{[Int64][math]::Round($Value)}
        "KiB"{[Int64][math]::Round($Value*1KB)}
        "MiB"{[Int64][math]::Round($Value*1MB)}
        "GiB"{[Int64][math]::Round($Value*1GB)}
        "TiB"{[Int64][math]::Round($Value*1TB)}
        default{0}
    }
}

function Get-AwsTransferProgressFromText {
    param([string]$Text,[Int64]$ExpectedTotalBytes)
    if([string]::IsNullOrWhiteSpace($Text)){return $null}
    $matches=[regex]::Matches(
        $Text,
        'Completed\s+([0-9]+(?:[\.,][0-9]+)?)\s*(Bytes|B|KiB|MiB|GiB|TiB)\s*/\s*([0-9]+(?:[\.,][0-9]+)?)\s*(Bytes|B|KiB|MiB|GiB|TiB)\s*\(([^)]*)\)',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if($matches.Count -eq 0){return $null}
    $x=$matches[$matches.Count-1]
    $value=[double](($x.Groups[1].Value -replace ',','.'))
    $uploaded=Convert-TransferUnitToBytes $value $x.Groups[2].Value
    return [PSCustomObject]@{
        UploadedBytes=[Int64][Math]::Min($ExpectedTotalBytes,$uploaded)
        SpeedText=[string]$x.Groups[5].Value
    }
}

function Invoke-AwsNative {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$Arguments
    )

    $awsCommand = Get-Command aws -ErrorAction SilentlyContinue
    if($null -eq $awsCommand){
        return [PSCustomObject]@{
            ExitCode = 9009
            StdOut   = ""
            StdErr   = "AWS CLI не найден в PATH."
            Output   = "AWS CLI не найден в PATH."
        }
    }

    $stdoutFile = Join-Path $statusDir ("aws-" + [Guid]::NewGuid().ToString("N") + ".stdout.txt")
    $stderrFile = Join-Path $statusDir ("aws-" + [Guid]::NewGuid().ToString("N") + ".stderr.txt")

    function Quote-AwsArgument {
        param([string]$Value)

        if($null -eq $Value){ return '""' }

        if($Value -notmatch '[\s"]'){
            return $Value
        }

        $escaped = $Value.Replace('"','\"')
        return '"' + $escaped + '"'
    }

    $argumentString = (($Arguments | ForEach-Object {
        Quote-AwsArgument ([string]$_)
    }) -join ' ')

    Write-UploadLog "AWS Start-Process: $($awsCommand.Source) $argumentString"

    try {
        $p = Start-Process `
            -FilePath $awsCommand.Source `
            -ArgumentList $argumentString `
            -WorkingDirectory $root `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        $stdout = ""
        $stderr = ""

        if(Test-Path $stdoutFile){
            $stdout = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue
        }
        if(Test-Path $stderrFile){
            $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
        }

        $combined = @()
        if(-not [string]::IsNullOrWhiteSpace($stdout)){ $combined += $stdout.Trim() }
        if(-not [string]::IsNullOrWhiteSpace($stderr)){ $combined += $stderr.Trim() }

        return [PSCustomObject]@{
            ExitCode = [int]$p.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
            Output   = ($combined -join [Environment]::NewLine)
        }
    }
    catch {
        $details = @()

        if($_.Exception){
            $details += "ExceptionType=$($_.Exception.GetType().FullName)"
            $details += "Message=$($_.Exception.Message)"

            if($_.Exception.InnerException){
                $details += "InnerType=$($_.Exception.InnerException.GetType().FullName)"
                $details += "InnerMessage=$($_.Exception.InnerException.Message)"
            }
        }

        if($_.ErrorDetails -and $_.ErrorDetails.Message){
            $details += "ErrorDetails=$($_.ErrorDetails.Message)"
        }

        if($_.CategoryInfo){
            $details += "Category=$($_.CategoryInfo)"
        }

        if($_.FullyQualifiedErrorId){
            $details += "FQID=$($_.FullyQualifiedErrorId)"
        }

        if($_.ScriptStackTrace){
            $details += "Stack=$($_.ScriptStackTrace)"
        }

        $message = ($details -join " | ")
        if([string]::IsNullOrWhiteSpace($message)){
            $message = ($_ | Out-String).Trim()
        }

        Write-UploadLog "Invoke-AwsNative exception: $message"

        return [PSCustomObject]@{
            ExitCode = 999
            StdOut   = ""
            StdErr   = $message
            Output   = $message
        }
    }
    finally {
        Remove-Item $stdoutFile,$stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-RuntimeSettings {
    $cfg=Import-PowerShellDataFile $configFile
    $safe=$true;$upload=[bool]$cfg.Global.EnableUpload
    if(Test-Path $settingsFile){
        try{
            $s=Get-Content $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json
            $safe=[bool]$s.SafeMode
            $upload=[bool]$s.EnableUpload
        }catch{}
    }
    [PSCustomObject]@{SafeMode=$safe;EnableUpload=$upload;Endpoint=$cfg.Global.EndpointUrl}
}

$script:StartedAt=(Get-Date).ToString("o")
if(-not(Test-Path $statusDir)){New-Item -ItemType Directory -Path $statusDir -Force|Out-Null}

try{
    Write-UploadLog "START operation=$OperationId database=$Database file=$FilePath root=$root"
    Write-Status "STARTING" 0 "Проверяю параметры"

    $runtime=Get-RuntimeSettings
    Write-UploadLog "Settings: SafeMode=$($runtime.SafeMode), EnableUpload=$($runtime.EnableUpload), Endpoint=$($runtime.Endpoint)"
    if($runtime.SafeMode -or -not $runtime.EnableUpload){
        throw "Upload заблокирован. SafeMode=$($runtime.SafeMode), EnableUpload=$($runtime.EnableUpload)."
    }

    $job=Get-Job $Database
    if($null -eq $job){throw "База '$Database' не найдена."}
    Write-UploadLog "Job: LocalPath=$($job.LocalPath), Bucket=$($job.Bucket), S3Path=$($job.S3Path), Profile=$($job.AwsProfile), Prefix=$($job.FilePrefix)"

    $item=Get-Item $FilePath -ErrorAction Stop
    $jobRoot=[IO.Path]::GetFullPath([string]$job.LocalPath)
    $candidate=[IO.Path]::GetFullPath($item.FullName)
    $rootSep=$jobRoot.TrimEnd([char[]]@([char]'\',[char]'/'))+[IO.Path]::DirectorySeparatorChar
    if(-not $candidate.StartsWith($rootSep,[StringComparison]::OrdinalIgnoreCase)){
        throw "Файл находится вне каталога базы."
    }
    if(-not $item.Name.StartsWith([string]$job.FilePrefix,[StringComparison]::OrdinalIgnoreCase)){
        throw "Файл не соответствует FilePrefix."
    }

    $s3Root=([string]$job.S3Path).Trim("/")
    $key=if($s3Root){"$s3Root/$($item.Name)"}else{$item.Name}
    $dest="s3://$($job.Bucket)/$key"

    # If object already exists with same size, do not upload it again.
    $aws=@("--endpoint-url",[string]$runtime.Endpoint)
    if(-not[string]::IsNullOrWhiteSpace([string]$job.AwsProfile)){
        $aws+=@("--profile",[string]$job.AwsProfile)
    }

    $awsCommand=Get-Command aws -ErrorAction SilentlyContinue
    if($null -eq $awsCommand){throw "AWS CLI не найден в PATH дочернего процесса."}
    Write-UploadLog "AWS CLI: $($awsCommand.Source)"
    Write-UploadLog "Destination: $dest"

    $headArgs=$aws+@("s3api","head-object","--bucket",[string]$job.Bucket,"--key",$key,"--output","json")
    $headResult=Invoke-AwsNative -Arguments $headArgs
    $headExit=$headResult.ExitCode
    Write-UploadLog "Initial head-object exit=$headExit output=$($headResult.Output)"

    # Код != 0 здесь допустим: чаще всего это означает, что объекта ещё нет.
    if($headExit -eq 0 -and -not [string]::IsNullOrWhiteSpace($headResult.StdOut)){
        try{
            $h=$headResult.StdOut|ConvertFrom-Json
            if([Int64]$h.ContentLength -eq [Int64]$item.Length){
                Write-Status "FINISHED" 100 "Файл уже существует на S3 с тем же размером" $key 0 0 (Get-Date).ToString("o")
                exit 0
            }
        }catch{}
    }


    function Invoke-AwsUploadWithProgress {
        param(
            [string[]]$BaseArguments,
            [Int64]$TotalBytes,
            [string]$S3Key
        )

        $awsCommand=Get-Command aws -ErrorAction SilentlyContinue
        if($null-eq$awsCommand){throw "AWS CLI не найден в PATH."}

        $outFile=Join-Path $statusDir ("upload-"+[Guid]::NewGuid().ToString("N")+".out.txt")
        $errFile=Join-Path $statusDir ("upload-"+[Guid]::NewGuid().ToString("N")+".err.txt")

        function Quote-Arg([string]$v){
            if($null-eq$v){return '""'}
            if($v -notmatch '[\s"]'){return $v}
            return '"'+($v.Replace('"','\"'))+'"'
        }

        $args=@($BaseArguments)
        $args=@($args|Where-Object{$_ -ne "--only-show-errors"})
        $args+=@("--progress-frequency","1","--progress-multiline")
        $argString=(($args|ForEach-Object{Quote-Arg ([string]$_)}) -join " ")

        $p=Start-Process `
            -FilePath $awsCommand.Source `
            -ArgumentList $argString `
            -WorkingDirectory $root `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile

        $lastUploaded=[Int64]0

        try{
            while(-not$p.HasExited){
                Start-Sleep -Milliseconds 300
                try{$p.Refresh()}catch{}

                $text=""
                if(Test-Path $outFile){$text+=(Get-Content $outFile -Raw -ErrorAction SilentlyContinue)}
                if(Test-Path $errFile){$text+="`n"+(Get-Content $errFile -Raw -ErrorAction SilentlyContinue)}

                $parsed=Get-AwsTransferProgressFromText $text $TotalBytes
                if($null-ne$parsed){
                    $lastUploaded=[Int64]$parsed.UploadedBytes
                    $remaining=[Math]::Max([Int64]0,$TotalBytes-$lastUploaded)
                    $pct=if($TotalBytes-gt0){[math]::Round(($lastUploaded/[double]$TotalBytes)*100,1)}else{0}

                    Write-Status `
                        -Status "UPLOADING" `
                        -Percent ([int][math]::Floor($pct)) `
                        -Message "Загрузка на $dest" `
                        -S3Key $S3Key `
                        -UploadedBytes $lastUploaded `
                        -RemainingBytes $remaining `
                        -SpeedText ([string]$parsed.SpeedText)
                }
            }

            $stdout=if(Test-Path $outFile){Get-Content $outFile -Raw -ErrorAction SilentlyContinue}else{""}
            $stderr=if(Test-Path $errFile){Get-Content $errFile -Raw -ErrorAction SilentlyContinue}else{""}
            return [PSCustomObject]@{
                ExitCode=[int]$p.ExitCode
                Output=(($stdout,$stderr|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}) -join [Environment]::NewLine)
            }
        }finally{
            Remove-Item $outFile,$errFile -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Status "UPLOADING" 10 "Загрузка на $dest" $key
    $sw=[Diagnostics.Stopwatch]::StartNew()

    $cpArgs=$aws+@("s3","cp",$item.FullName,$dest)
    Write-UploadLog "Starting stable synchronous aws s3 cp (progress bar disabled)"
    Write-UploadLog ("CP arguments: "+(($cpArgs|ForEach-Object{"["+[string]$_+"]"}) -join " "))
    $cpResult=Invoke-AwsNative -Arguments $cpArgs

    if($null -eq $cpResult){
        throw "AWS CLI не вернул результат выполнения."
    }

    $exit=[int]$cpResult.ExitCode

    $sw.Stop()
    Write-UploadLog "aws s3 cp exit=$exit output=$($cpResult.Output)"
    if($exit -ne 0){
        $detail=$cpResult.Output
        if([string]::IsNullOrWhiteSpace($detail)){$detail="AWS CLI завершился с кодом $exit без текста ошибки."}
        throw "AWS upload failed (exit $exit): $detail"
    }

    Write-Status "VERIFYING" 90 "Проверяю объект после загрузки" $key

    # Some S3-compatible providers may expose a newly uploaded object to
    # HEAD a little later than the high-level `aws s3 cp` command returns.
    # Do not fail on the first 404: retry verification for a short period.
    $verifyResult=$null
    $verifyExit=1
    $verified=$false
    $verifyAttempts=8

    for($verifyAttempt=1;$verifyAttempt -le $verifyAttempts;$verifyAttempt++){
        $verifyResult=Invoke-AwsNative -Arguments $headArgs
        $verifyExit=$verifyResult.ExitCode

        Write-UploadLog (
            "Verify head-object attempt={0}/{1} exit={2} output={3}" -f
            $verifyAttempt,$verifyAttempts,$verifyExit,$verifyResult.Output
        )

        if($verifyExit -eq 0 -and -not[string]::IsNullOrWhiteSpace($verifyResult.StdOut)){
            try{
                $h=$verifyResult.StdOut|ConvertFrom-Json

                if([Int64]$h.ContentLength -eq [Int64]$item.Length){
                    $verified=$true
                    break
                }

                Write-UploadLog (
                    "Verify size mismatch attempt={0}: Local={1}, S3={2}" -f
                    $verifyAttempt,$item.Length,$h.ContentLength
                )
            }catch{
                Write-UploadLog "Verify JSON parse failed: $($_.Exception.Message)"
            }
        }

        if($verifyAttempt -lt $verifyAttempts){
            Write-Status `
                "VERIFYING" `
                (90+$verifyAttempt) `
                ("Проверяю объект после загрузки · попытка "+($verifyAttempt+1)+"/"+$verifyAttempts) `
                $key

            Start-Sleep -Seconds 1
        }
    }

    if(-not$verified){
        # Diagnostic: list the exact destination folder. This makes key/path
        # mistakes visible in the operation log instead of returning only 404.
        $parentPrefix=""
        $slashIndex=$key.LastIndexOf("/")
        if($slashIndex -ge 0){
            $parentPrefix=$key.Substring(0,$slashIndex+1)
        }

        $listArgs=$aws+@(
            "s3api","list-objects-v2",
            "--bucket",[string]$job.Bucket,
            "--prefix",$parentPrefix,
            "--max-items","20",
            "--output","json"
        )

        $listResult=Invoke-AwsNative -Arguments $listArgs
        Write-UploadLog (
            "Verify diagnostics list-objects-v2 prefix='{0}' exit={1} output={2}" -f
            $parentPrefix,$listResult.ExitCode,$listResult.Output
        )

        $verifyText=if($null-ne$verifyResult){[string]$verifyResult.Output}else{"нет ответа"}

        throw (
            "Upload завершился с exit=0, но объект не появился по ожидаемому ключу " +
            "'$key' после $verifyAttempts проверок. Последний head-object: $verifyText. " +
            "Подробный список объектов записан в лог операции."
        )
    }

    $duration=[math]::Round($sw.Elapsed.TotalSeconds,1)
    $speed=if($duration -gt 0){[math]::Round(($item.Length/1MB)/$duration,2)}else{0}

    Write-Status "FINISHED" 100 "Файл успешно загружен и проверен" $key $duration $speed (Get-Date).ToString("o") ([Int64]$item.Length) 0 "$speed MB/s"
}
catch{
    $parts=@()

    try{
        if($_.Exception){
            $parts += "ExceptionType=$($_.Exception.GetType().FullName)"
            $parts += "Message=$($_.Exception.Message)"
            if($_.Exception.InnerException){
                $parts += "InnerType=$($_.Exception.InnerException.GetType().FullName)"
                $parts += "InnerMessage=$($_.Exception.InnerException.Message)"
            }
        }
    }catch{}

    try{
        if($_.ErrorDetails -and $_.ErrorDetails.Message){
            $parts += "ErrorDetails=$($_.ErrorDetails.Message)"
        }
    }catch{}

    try{
        if($_.CategoryInfo){
            $parts += "Category=$($_.CategoryInfo)"
        }
    }catch{}

    try{
        if($_.FullyQualifiedErrorId){
            $parts += "FQID=$($_.FullyQualifiedErrorId)"
        }
    }catch{}

    try{
        if($_.ScriptStackTrace){
            $parts += "Stack=$($_.ScriptStackTrace)"
        }
    }catch{}

    $detail=($parts -join " | ")

    if([string]::IsNullOrWhiteSpace($detail)){
        try{$detail=($_|Out-String).Trim()}catch{}
    }
    if([string]::IsNullOrWhiteSpace($detail)){
        $detail="Неизвестная ошибка PowerShell."
    }

    Write-UploadLog "ERROR: $detail"
    Write-Status "ERROR" 100 $detail "" $null $null (Get-Date).ToString("o")
    exit 1
}
