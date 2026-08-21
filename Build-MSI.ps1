param(
    [string]$Configuration = "Release",
    [string]$WixPath = ""
)

$ErrorActionPreference="Stop"
$here=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "tools\DotNet-Helpers.ps1")

$dotnetInfo=Assert-DotNet8Sdk
$dotnet=$dotnetInfo.DotNetExe
& (Join-Path $here "Build-App.ps1") -Configuration $Configuration

$app=Join-Path $here "dist\app"
$msiDir=Join-Path $here "dist\msi"
$product=Join-Path $here "installer\Product.wxs"
$harvest=Join-Path $here "installer\Harvested.wxs"
New-Item -ItemType Directory -Path $msiDir -Force|Out-Null

function Get-WixExe {
    $cmd=Get-Command wix.exe -ErrorAction SilentlyContinue
    if($null-ne$cmd){return $cmd.Source}
    $cmd=Get-Command wix -ErrorAction SilentlyContinue
    if($null-ne$cmd){return $cmd.Source}
    $candidate=Join-Path $env:USERPROFILE ".dotnet\tools\wix.exe"
    if(Test-Path $candidate){return $candidate}
    return $null
}

$wix=if(-not[string]::IsNullOrWhiteSpace($WixPath)){$WixPath}else{Get-WixExe}
if(-not[string]::IsNullOrWhiteSpace($wix) -and -not(Test-Path -LiteralPath $wix -PathType Leaf)){
    throw "Указанный WixPath не найден: $wix"
}
if([string]::IsNullOrWhiteSpace($wix)){
    Write-Host "WiX Toolset CLI не найден. Устанавливаю WiX 4 как dotnet tool..." -ForegroundColor Yellow
    & $dotnet tool install --global wix --version "4.*"
    if($LASTEXITCODE-ne0){throw "Не удалось установить WiX Toolset CLI"}
    $wix=Join-Path $env:USERPROFILE ".dotnet\tools\wix.exe"
    if(-not(Test-Path $wix)){throw "wix.exe не найден после установки"}
}

Write-Host "WiX: $wix" -ForegroundColor Cyan
$out=Join-Path $msiDir "BackupS3Manager-v23.14-x64.msi"
& (Join-Path $here "tools\New-WixHarvest.ps1") -SourceDirectory $app -OutputPath $harvest

& $wix build $product $harvest `
    -arch x64 `
    -d PublishDir="$app" `
    -o $out

if($LASTEXITCODE-ne0){throw "wix build failed"}
if(-not(Test-Path $out -PathType Leaf)){throw "MSI не создан: $out"}

Write-Host ""
Write-Host "OK: MSI created" -ForegroundColor Green
Write-Host $out -ForegroundColor Green
