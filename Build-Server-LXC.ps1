$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$project=Join-Path $root 'server\BackupS3Manager.Server.csproj'
$publish=Join-Path $root 'dist\server\publish'
$packageRoot=Join-Path $root 'dist\server\package'
$archive=Join-Path $root 'dist\server\BackupS3Manager-Server-v25.0-linux-x64.tar.gz'

if(Test-Path $publish){Remove-Item -LiteralPath $publish -Recurse -Force}
if(Test-Path $packageRoot){Remove-Item -LiteralPath $packageRoot -Recurse -Force}
New-Item -ItemType Directory -Path $publish,$packageRoot -Force|Out-Null

dotnet publish $project -c Release -r linux-x64 --self-contained true `
  -p:PublishSingleFile=true -p:PublishTrimmed=false -o $publish
if($LASTEXITCODE -ne 0){throw 'Не удалось собрать Linux-сервер.'}

Copy-Item (Join-Path $publish 'BackupS3Manager.Server') $packageRoot
Copy-Item (Join-Path $publish 'wwwroot') $packageRoot -Recurse
Copy-Item (Join-Path $root 'server\deploy\install.sh') $packageRoot
Copy-Item (Join-Path $root 'server\deploy\backups3-manager.service') $packageRoot
Copy-Item (Join-Path $root 'server\README.md') $packageRoot
Copy-Item (Join-Path $root 'server\ROADMAP.md') $packageRoot

if(Test-Path $archive){[IO.File]::Delete($archive)}
tar -czf $archive -C $packageRoot .
if($LASTEXITCODE -ne 0){throw 'Не удалось создать tar.gz.'}
Write-Host "OK: $archive" -ForegroundColor Green
