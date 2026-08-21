$ErrorActionPreference="Stop"
$here=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "tools\DotNet-Helpers.ps1")

Write-Host "=== BackupS3 Manager v23.11 build environment ===" -ForegroundColor Cyan
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
Write-Host "OS: $([Environment]::OSVersion.VersionString)"
Write-Host "Process architecture: $([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
Write-Host ""

$dotnet = Get-DotNetExe
if($dotnet){
    Write-Host "[OK] dotnet.exe: $dotnet" -ForegroundColor Green
    Write-Host ""
    & $dotnet --info
    Write-Host ""
    $sdk=Get-DotNetSdkInfo $dotnet
    if($sdk.Found){
        Write-Host "[OK] .NET 8 SDK found: $($sdk.Versions[0])" -ForegroundColor Green
    }else{
        Write-Host "[FAIL] dotnet found but .NET 8 SDK is missing" -ForegroundColor Red
        Write-Host $sdk.Raw
    }
}else{
    Write-Host "[FAIL] dotnet.exe not found" -ForegroundColor Red
    Write-Host ""
    Write-Host 'Test standard path:'
    Write-Host ('  C:\Program Files\dotnet\dotnet.exe = ' + (Test-Path 'C:\Program Files\dotnet\dotnet.exe'))
}

Write-Host ""
Write-Host "PATH contains dotnet:"
($env:PATH -split ';' | Where-Object {$_ -match 'dotnet'}) | ForEach-Object { Write-Host "  $_" }
