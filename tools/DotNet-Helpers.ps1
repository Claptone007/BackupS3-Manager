function Get-DotNetExe {
    $candidates = New-Object System.Collections.Generic.List[string]

    # Current PATH first.
    try {
        $cmd = Get-Command dotnet.exe -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
            $candidates.Add($cmd.Source)
        }
    } catch {}

    # Standard x64 install location.
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramFiles "dotnet\dotnet.exe"))
    }

    # Explicit 64-bit Program Files from registry/environment, useful when
    # PowerShell was already open while .NET SDK was installed.
    try {
        $pf64 = [Environment]::GetEnvironmentVariable("ProgramW6432", "Machine")
        if (-not [string]::IsNullOrWhiteSpace($pf64)) {
            $candidates.Add((Join-Path $pf64 "dotnet\dotnet.exe"))
        }
    } catch {}

    # Registry install location.
    foreach ($reg in @(
        "HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64",
        "HKLM:\SOFTWARE\WOW6432Node\dotnet\Setup\InstalledVersions\x64"
    )) {
        try {
            $v = (Get-ItemProperty $reg -ErrorAction Stop).InstallLocation
            if (-not [string]::IsNullOrWhiteSpace($v)) {
                $candidates.Add((Join-Path $v "dotnet.exe"))
            }
        } catch {}
    }

    # Last fallback: where.exe can see a machine PATH even when PowerShell's
    # cached $env:PATH has not been refreshed.
    try {
        $found = & "$env:SystemRoot\System32\where.exe" dotnet.exe 2>$null
        foreach ($p in @($found)) {
            if (-not [string]::IsNullOrWhiteSpace($p)) {
                $candidates.Add([string]$p)
            }
        }
    } catch {}

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate -PathType Leaf)) {
            return (Resolve-Path $candidate).Path
        }
    }

    return $null
}

function Get-DotNetSdkInfo {
    param(
        [Parameter(Mandatory=$true)]
        [string]$DotNetExe
    )

    $raw = & $DotNetExe --list-sdks 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{
            Found = $false
            Versions = @()
            Raw = ($raw -join "`n")
        }
    }

    $versions = @()
    foreach ($line in @($raw)) {
        if ([string]$line -match '^\s*(\d+\.\d+\.\d+)') {
            $versions += [version]$Matches[1]
        }
    }

    $net8 = @($versions | Where-Object { $_.Major -eq 8 } | Sort-Object -Descending)

    return [PSCustomObject]@{
        Found = ($net8.Count -gt 0)
        Versions = $net8
        Raw = ($raw -join "`n")
    }
}

function Assert-DotNet8Sdk {
    $dotnet = Get-DotNetExe

    if ([string]::IsNullOrWhiteSpace($dotnet)) {
        throw @"
.NET SDK не найден.

Проверены:
- текущий PATH;
- C:\Program Files\dotnet\dotnet.exe;
- registry InstalledVersions\x64;
- where.exe dotnet.exe.

Если SDK был установлен при уже открытом PowerShell, закрой PowerShell и
открой новый. Также можно проверить вручную:
    Test-Path "C:\Program Files\dotnet\dotnet.exe"
"@
    }

    $sdk = Get-DotNetSdkInfo -DotNetExe $dotnet
    if (-not $sdk.Found) {
        throw @"
dotnet.exe найден:
    $dotnet

Но .NET 8 SDK не обнаружен.

Вывод:
$sdk.Raw
"@
    }

    return [PSCustomObject]@{
        DotNetExe = $dotnet
        HighestSdk = $sdk.Versions[0].ToString()
        AllNet8 = @($sdk.Versions | ForEach-Object { $_.ToString() })
    }
}
