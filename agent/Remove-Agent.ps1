$ErrorActionPreference='Stop'
$serviceName='BackupS3Agent'
if(Get-Service $serviceName -ErrorAction SilentlyContinue){
    Stop-Service $serviceName -Force -ErrorAction SilentlyContinue
    sc.exe delete $serviceName|Out-Null
    Write-Host 'BackupS3 Agent removed. Configuration remains in ProgramData.' -ForegroundColor Yellow
}else{Write-Host 'BackupS3 Agent service is not installed.'}
