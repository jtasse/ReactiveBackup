# ReactiveBackup.Create-Desktop-Shortcuts.ps1
# Creates Ubuntu/GNOME .desktop launchers that start in the solution directory
# with a full path to pwsh, so they do not depend on GUI PATH or CWD.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ReactiveBackup.Common.ps1')

if (-not (Test-IsUnixPlatform)) {
    Write-Host "This helper is for Linux desktop environments. On Windows, use ReactiveBackup.Create-Edit-Scheduled-Task.ps1 instead." -ForegroundColor Yellow
    return
}

$pwshPath = Get-PwshExecutablePath
if (-not $pwshPath) {
    throw "Could not find pwsh on PATH. Install PowerShell and re-run this script."
}

function New-DesktopEntryContent {
    param(
        [string]$Name,
        [string]$Comment,
        [string]$ScriptFileName
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptFileName
    $exec = "env DOTNET_SYSTEM_IO_DISABLEFILELOCKING=1 `"$pwshPath`" -NoExit -NoProfile -File `"$scriptPath`""

    @(
        '[Desktop Entry]'
        'Type=Application'
        'Version=1.0'
        "Name=$Name"
        "Comment=$Comment"
        "Exec=$exec"
        "Path=$PSScriptRoot"
        'Terminal=true'
        'StartupNotify=false'
        'Categories=Utility;'
    ) -join "`n"
}

function Save-DesktopEntry {
    param(
        [string]$DestinationDir,
        [string]$FileName,
        [string]$Content
    )

    if (-not (Test-Path -LiteralPath $DestinationDir)) {
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }

    $dest = Join-Path $DestinationDir $FileName
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($dest, ($Content.Trim() + "`n"), $utf8)

    try {
        & chmod +x $dest
    }
    catch {
        Write-Host "Could not mark $dest executable: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $gio = Get-Command gio -ErrorAction SilentlyContinue
    if ($gio) {
        try {
            & gio set $dest 'metadata::trusted' true
        }
        catch {
            # Older GNOME builds may not support this key; Allow Launching from the UI still works.
        }
    }

    return $dest
}

$applicationsDir = Join-Path $env:HOME '.local/share/applications'
$desktopDir = Join-Path $env:HOME 'Desktop'

$entries = @(
    @{
        Name     = 'ReactiveBackup'
        FileName = 'ReactiveBackup.desktop'
        Script   = 'ReactiveBackup.ps1'
        Comment  = 'Run an ad-hoc ReactiveBackup backup'
    },
    @{
        Name     = 'ReactiveBackup EvaluateAndRun'
        FileName = 'ReactiveBackup-EvaluateAndRun.desktop'
        Script   = 'ReactiveBackup.EvaluateAndRun.ps1'
        Comment  = 'Evaluate configured repos and run backups if needed'
    }
)

$created = @()
foreach ($entry in $entries) {
    $content = New-DesktopEntryContent -Name $entry.Name -Comment $entry.Comment -ScriptFileName $entry.Script
    $created += Save-DesktopEntry -DestinationDir $applicationsDir -FileName $entry.FileName -Content $content
    if (Test-Path -LiteralPath $desktopDir) {
        $created += Save-DesktopEntry -DestinationDir $desktopDir -FileName $entry.FileName -Content $content
    }
}

Write-Host "Created desktop launchers:" -ForegroundColor Green
$created | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "If a Desktop icon says it is untrusted, right-click it and choose Allow Launching."
Write-Host "The terminal stays open after the script finishes so you can read errors and logs."
