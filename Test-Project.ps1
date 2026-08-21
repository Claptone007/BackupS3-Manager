$ErrorActionPreference="Stop"
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$backend=Join-Path $root "BackendTemplate"

Write-Host "=== BackupS3 Manager v23 project test ===" -ForegroundColor Cyan

$required=@(
    "src\BackupS3Manager.csproj",
    "src\Program.cs",
    "src\MainForm.cs",
    "src\ApiBridge.cs",
    "src\AppPaths.cs",
    "src\StartupDiagnostics.cs",
    "src\DiagnosticsForm.cs",
    "BackendTemplate\BackupS3.ps1",
    "BackendTemplate\Manual-Upload.ps1",
    "BackendTemplate\Generate-Dashboard.ps1",
    "Build-App.ps1",
    "Build-MSI.ps1",
    "tools\DotNet-Helpers.ps1",
    "Test-BuildEnvironment.ps1",
    "Test-CSharpSource.ps1",
    "Test-DesktopApiBridge.ps1",
    "Test-v23.11-Scheduler.ps1",
    "Test-v23.12-SelfDiagnostics.ps1",
    "Test-v23.12-ProfilesAndAutomation.ps1",
    "Test-v23.08-UI.ps1"
)

foreach($rel in $required){
    $p=Join-Path $root $rel
    if(-not(Test-Path $p)){throw "Missing: $rel"}
    Write-Host "[OK] $rel" -ForegroundColor Green
}

foreach($f in Get-ChildItem $backend -Filter *.ps1 -File){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){
        Write-Host "[FAIL] $($f.Name)" -ForegroundColor Red
        $errors|ForEach-Object{Write-Host "  line $($_.Extent.StartLineNumber): $($_.Message)"}
        throw "PowerShell syntax errors"
    }
    Write-Host "[OK] PS syntax: $($f.Name)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Project structure OK." -ForegroundColor Green
