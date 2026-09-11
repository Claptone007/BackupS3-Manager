$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$project=Join-Path $root 'server\BackupS3Manager.Server.csproj'
dotnet build $project -c Release
if($LASTEXITCODE -ne 0){throw 'Server project does not compile.'}
$program=Get-Content (Join-Path $root 'server\Program.cs') -Raw -Encoding UTF8
$store=Get-Content (Join-Path $root 'server\ServerStore.cs') -Raw -Encoding UTF8
foreach($needle in @('/agent/enroll','/agent/heartbeat','RequireAuthorization','BS3_ADMIN_PASSWORD')){
  if(-not $program.Contains($needle)){throw "Server route/security missing: $needle"}
}
foreach($needle in @('CryptographicOperations.FixedTimeEquals','tokenHash','assignedJobs')){
  if(-not $store.Contains($needle)){throw "Server store protection missing: $needle"}
}
Write-Host '[OK] BackupS3 Manager Server routes, authentication and storage checks passed' -ForegroundColor Green
