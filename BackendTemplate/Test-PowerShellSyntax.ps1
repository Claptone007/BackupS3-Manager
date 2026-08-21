param(
    [string]$RootPath = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

$files = @(
    "Start-DashboardServer.ps1",
    "BackupS3.ps1",
    "AutoScheduler.ps1",
    "Install-AutoScheduler.ps1",
    "Remove-AutoScheduler.ps1",
    "Get-AutoSchedulerStatus.ps1",
    "Manual-Upload.ps1",
    "Generate-Dashboard.ps1"
)

$failed = $false

foreach($name in $files){
    $path = Join-Path $RootPath $name
    if(-not(Test-Path $path -PathType Leaf)){
        Write-Host "[SKIP] $name - file not found" -ForegroundColor Yellow
        continue
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors
    )

    if($errors.Count -eq 0){
        Write-Host "[OK]   $name" -ForegroundColor Green
    }else{
        $failed = $true
        Write-Host "[FAIL] $name" -ForegroundColor Red
        foreach($e in $errors){
            Write-Host ("       line {0}, col {1}: {2}" -f `
                $e.Extent.StartLineNumber,
                $e.Extent.StartColumnNumber,
                $e.Message
            ) -ForegroundColor Red
        }
    }
}

if($failed){
    exit 1
}

Write-Host ""
Write-Host "All PowerShell files parsed successfully." -ForegroundColor Green
