param(
    [string]$Configuration = "Release"
)

$ErrorActionPreference="Stop"
$here=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "tools\DotNet-Helpers.ps1")

$proj=Join-Path $here "src\BackupS3Manager.csproj"
$out=Join-Path $here "dist\app"

$dotnetInfo = Assert-DotNet8Sdk
$dotnet = $dotnetInfo.DotNetExe

Write-Host "dotnet.exe: $dotnet" -ForegroundColor Cyan
Write-Host ".NET 8 SDK: $($dotnetInfo.HighestSdk)" -ForegroundColor Green

Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $out -Force|Out-Null

& $dotnet restore $proj
if($LASTEXITCODE-ne0){throw "dotnet restore failed"}

& $dotnet publish $proj `
    -c $Configuration `
    -r win-x64 `
    --self-contained true `
    -p:PublishReadyToRun=false `
    -o $out

if($LASTEXITCODE-ne0){throw "dotnet publish failed"}

# В публичную сборку никогда не помещаем рабочую конфигурацию разработчика.
# Новый пользователь начинает с пустого списка баз и безопасных настроек.
$cleanConfig=Join-Path $here "installer\BackupJobs.clean.psd1"
$publishedConfig=Join-Path $out "BackendTemplate\BackupJobs.psd1"
Copy-Item -LiteralPath $cleanConfig -Destination $publishedConfig -Force

# Сгенерированный Dashboard содержит снимок конкретной конфигурации и никогда
# не должен попадать в публичную сборку. На целевом ПК он создаётся заново.
$publishedWeb=Join-Path $out "BackendTemplate\Web"
if(Test-Path -LiteralPath $publishedWeb){
    $resolvedWeb=(Resolve-Path -LiteralPath $publishedWeb).Path
    if(-not $resolvedWeb.StartsWith($out+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
        throw "Небезопасный путь очистки Dashboard: $resolvedWeb"
    }
    Remove-Item -LiteralPath $resolvedWeb -Recurse -Force
}

$fixedRuntime=Join-Path $here "runtime\WebView2Runtime"
if(Test-Path -LiteralPath $fixedRuntime -PathType Container){
    $runtimeOut=Join-Path $out "WebView2Runtime"
    New-Item -ItemType Directory -Path $runtimeOut -Force|Out-Null
    Copy-Item -Path (Join-Path $fixedRuntime '*') -Destination $runtimeOut -Recurse -Force
    Write-Host "Bundled WebView2 Fixed Runtime: $runtimeOut" -ForegroundColor Green
}else{
    Write-Host "WARN: bundled WebView2 Fixed Runtime not found: $fixedRuntime" -ForegroundColor Yellow
}

$exe=Join-Path $out "BackupS3Manager.exe"
if(-not(Test-Path $exe -PathType Leaf)){
    throw "Сборка завершилась без BackupS3Manager.exe"
}

Write-Host ""
Write-Host "OK: application built" -ForegroundColor Green
Write-Host "EXE: $exe" -ForegroundColor Green
Write-Host ""
Write-Host "Это self-contained build: на целевой машине отдельный .NET Runtime/SDK не требуется." -ForegroundColor Cyan
