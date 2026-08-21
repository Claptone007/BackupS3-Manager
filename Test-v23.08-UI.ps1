$ErrorActionPreference="Stop"
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$genPath=Join-Path $root "BackendTemplate\Generate-Dashboard.ps1"
$text=Get-Content $genPath -Raw -Encoding UTF8

Write-Host "=== BackupS3 Manager v23.08 UI regression check ===" -ForegroundColor Cyan

$start=$text.IndexOf("// v23.11 Desktop: S3 connection health")
if($start-lt0){throw "S3 UI JavaScript block start not found"}
$end=$text.IndexOf("// Report.",$start)
if($end-lt0){throw "S3 UI JavaScript block end not found"}

$block=$text.Substring($start,$end-$start)

# A JavaScript backtick inside an expandable PowerShell here-string was the
# reason all buttons stopped working in v23.07.
if($block.Contains([char]96)){
    throw "S3 UI block still contains a backtick/template literal."
}
Write-Host "[OK] S3 UI block contains no JavaScript template literals" -ForegroundColor Green

foreach($needle in @(
    "s3StatusButton.addEventListener",
    "settingsButton.addEventListener",
    "addJobButton.addEventListener",
    "refreshButton.addEventListener",
    'id="appDialogBackdrop"',
    "function showAppDialog(options)",
    "window.alert=function(message)",
    "await appConfirm("
)){
    if(-not$text.Contains($needle)){throw "Missing UI event binding: $needle"}
    Write-Host "[OK] $needle" -ForegroundColor Green
}

if($text -match '\bconfirm\s*\('){
    throw "Native browser confirm() is still present"
}
Write-Host "[OK] native browser confirm() removed" -ForegroundColor Green

$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($genPath,[ref]$tokens,[ref]$errors)
if($errors.Count){
    $errors|ForEach-Object{Write-Host ("[FAIL] line {0}: {1}" -f $_.Extent.StartLineNumber,$_.Message) -ForegroundColor Red}
    throw "Generate-Dashboard.ps1 syntax error"
}
Write-Host "[OK] Generate-Dashboard.ps1 PowerShell syntax" -ForegroundColor Green
Write-Host "UI regression check passed." -ForegroundColor Green
