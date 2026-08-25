param(
    [Parameter(Mandatory=$true)][string]$ManagerUrl,
    [Parameter(Mandatory=$true)][string]$EnrollmentCode,
    [string]$DisplayName=$env:COMPUTERNAME
)
$ErrorActionPreference='Stop'
$serviceName='BackupS3Agent'
$exe=Join-Path $PSScriptRoot 'BackupS3Agent.exe'
if(-not(Test-Path $exe -PathType Leaf)){throw "File not found: $exe"}
$data=Join-Path $env:ProgramData 'BackupS3Agent'
New-Item -ItemType Directory -Path $data -Force|Out-Null
$config=[ordered]@{ManagerUrl=$ManagerUrl;EnrollmentCode=$EnrollmentCode;DisplayName=$DisplayName;AgentId='';Token='';PollSeconds=15;Jobs=@()}
$config|ConvertTo-Json -Depth 8|Set-Content (Join-Path $data 'agent-settings.json') -Encoding UTF8
if(Get-Service $serviceName -ErrorAction SilentlyContinue){Stop-Service $serviceName -Force -ErrorAction SilentlyContinue;sc.exe delete $serviceName|Out-Null;Start-Sleep -Seconds 1}
sc.exe create $serviceName binPath= ('"'+$exe+'"') start= auto DisplayName= 'BackupS3 Agent'|Out-Null
sc.exe description $serviceName 'Local backup inspection agent for BackupS3 Manager'|Out-Null
sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/15000/restart/60000|Out-Null
Start-Service $serviceName
Write-Host "BackupS3 Agent installed and started. Host=$env:COMPUTERNAME" -ForegroundColor Green
