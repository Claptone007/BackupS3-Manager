$ErrorActionPreference="Stop"
$here=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "tools\DotNet-Helpers.ps1")
$proj=Join-Path $here "src\BackupS3Manager.csproj"
$dotnetInfo=Assert-DotNet8Sdk
& $dotnetInfo.DotNetExe build $proj -c Release --no-restore
if($LASTEXITCODE-ne0){throw "C# source validation failed"}
Write-Host "[OK] C# source compiles" -ForegroundColor Green
