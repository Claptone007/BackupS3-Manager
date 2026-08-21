$ErrorActionPreference="Stop"
$root=Split-Path -Parent $MyInvocation.MyCommand.Path

$program=Get-Content (Join-Path $root "src\Program.cs") -Raw -Encoding UTF8
$diag=Get-Content (Join-Path $root "src\StartupDiagnostics.cs") -Raw -Encoding UTF8
$form=Get-Content (Join-Path $root "src\DiagnosticsForm.cs") -Raw -Encoding UTF8
$main=Get-Content (Join-Path $root "src\MainForm.cs") -Raw -Encoding UTF8
$paths=Get-Content (Join-Path $root "src\AppPaths.cs") -Raw -Encoding UTF8

Write-Host "=== BackupS3 Manager v23.12 self-diagnostics source check ===" -ForegroundColor Cyan

foreach($pair in @(
    @($program,'new DiagnosticsForm(startupMode: true)'),
    @($diag,'CheckPowerShellConfigAsync'),
    @($diag,'CheckS3ConnectionsAsync'),
    @($diag,'CheckSchedulerAsync'),
    @($diag,'старая задача Windows ещё существует'),
    @($diag,'CheckDashboardGenerationAsync'),
    @($form,'Проверить снова'),
    @($form,'Копировать отчёт'),
    @($form,'using System.Diagnostics;'),
    @($main,'Диагностика'),
    @($main,'new("Обновить Dashboard") { Enabled = false }'),
    @($main,'_web.CoreWebView2 is null'),
    @($main,'await RefreshDashboardAsync()'),
    @($main,'AppPaths.BundledWebView2RuntimeOrNull'),
    @($paths,'WebView2Runtime'),
    @($paths,'msedgewebview2.exe')
)){
    if(-not $pair[0].Contains($pair[1])){throw "Missing: $($pair[1])"}
    Write-Host "[OK] $($pair[1])" -ForegroundColor Green
}

Write-Host "v23.12 self-diagnostics source check passed." -ForegroundColor Green
