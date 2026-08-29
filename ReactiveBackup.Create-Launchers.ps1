param(
    [switch]$Shortcuts,
    [switch]$Schedule
)

# Creates desktop/start-menu launchers.
# Windows: .lnk shortcuts
# Linux: .desktop launchers
# macOS: .command launchers
# Scheduled backups are managed by ReactiveBackup.Create-Edit-Scheduled-Task.ps1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ReactiveBackup.Common.ps1')

$relaunchCode = Invoke-ReactiveBackupRelaunchAsSessionUser -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
if ($null -ne $relaunchCode) {
    exit $relaunchCode
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'Info'
    )

    $configForLog = $null
    $configVar = Get-Variable -Name config -ErrorAction SilentlyContinue
    if ($configVar) { $configForLog = $configVar.Value }
    Write-ReactiveBackupLog -Message $Message -Level $Level -Prefix '[Launchers] ' -Config $configForLog
}

function Get-ShortcutEntries {
    return @(
        @{
            Name        = 'ReactiveBackup'
            LinuxFile   = 'ReactiveBackup.desktop'
            MacFile     = 'ReactiveBackup.command'
            WindowsFile = 'ReactiveBackup.lnk'
            Script      = 'ReactiveBackup.ps1'
            Comment     = 'Run an ad-hoc ReactiveBackup backup'
        },
        @{
            Name        = 'ReactiveBackup EvaluateAndRun'
            LinuxFile   = 'ReactiveBackup-EvaluateAndRun.desktop'
            MacFile     = 'ReactiveBackup-EvaluateAndRun.command'
            WindowsFile = 'ReactiveBackup EvaluateAndRun.lnk'
            Script      = 'ReactiveBackup.EvaluateAndRun.ps1'
            Comment     = 'Evaluate configured repos and run a one-off or continuous backup'
        },
        @{
            Name        = 'ReactiveBackup Scheduled Task'
            LinuxFile   = 'ReactiveBackup-Scheduled-Task.desktop'
            MacFile     = 'ReactiveBackup-Scheduled-Task.command'
            WindowsFile = 'ReactiveBackup Scheduled Task.lnk'
            Script      = 'ReactiveBackup.Create-Edit-Scheduled-Task.ps1'
            Comment     = 'Create or edit the background backup schedule'
        }
    )
}

function Install-LinuxDesktopShortcuts {
    param(
        [string]$ShellPath,
        [object[]]$Entries
    )

    $applicationsDir = Join-Path $env:HOME '.local/share/applications'
    $desktopDir = Join-Path $env:HOME 'Desktop'
    $created = @()

    foreach ($entry in $Entries) {
        $scriptPath = Join-Path $PSScriptRoot $entry.Script
        $exec = "env DOTNET_SYSTEM_IO_DISABLEFILELOCKING=1 `"$ShellPath`" -NoExit -NoProfile -File `"$scriptPath`""
        $content = @(
            '[Desktop Entry]'
            'Type=Application'
            'Version=1.0'
            "Name=$($entry.Name)"
            "Comment=$($entry.Comment)"
            '# Do not wrap Exec in sudo or pkexec. Ubuntu mounts /media/$USER for the desktop user; root cannot write there.'
            "Exec=$exec"
            "Path=$PSScriptRoot"
            'Terminal=true'
            'StartupNotify=false'
            'Categories=Utility;'
        ) -join "`n"

        foreach ($dir in @($applicationsDir, $desktopDir)) {
            if ($dir -eq $desktopDir -and -not (Test-Path -LiteralPath $dir)) {
                continue
            }
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }

            $dest = Join-Path $dir $entry.LinuxFile
            $utf8 = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($dest, ($content.Trim() + "`n"), $utf8)
            try { & chmod +x $dest } catch { }
            $gio = Get-Command gio -ErrorAction SilentlyContinue
            if ($gio) {
                try { & gio set $dest 'metadata::trusted' true } catch { }
            }
            $created += $dest
        }
    }

    return $created
}

function Install-MacCommandShortcuts {
    param(
        [string]$ShellPath,
        [object[]]$Entries
    )

    $desktopDir = Join-Path $env:HOME 'Desktop'
    $created = @()

    foreach ($entry in $Entries) {
        $scriptPath = Join-Path $PSScriptRoot $entry.Script
        $content = @(
            '#!/bin/bash'
            "cd `"$PSScriptRoot`""
            "exec env DOTNET_SYSTEM_IO_DISABLEFILELOCKING=1 `"$ShellPath`" -NoExit -NoProfile -File `"$scriptPath`""
        ) -join "`n"

        if (-not (Test-Path -LiteralPath $desktopDir)) {
            New-Item -ItemType Directory -Path $desktopDir -Force | Out-Null
        }

        $dest = Join-Path $desktopDir $entry.MacFile
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($dest, ($content.Trim() + "`n"), $utf8)
        try { & chmod +x $dest } catch { }
        $created += $dest
    }

    return $created
}

function Install-WindowsShortcuts {
    param(
        [string]$ShellPath,
        [object[]]$Entries
    )

    $desktopDir = [Environment]::GetFolderPath('Desktop')
    $programsDir = Join-Path (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs') 'ReactiveBackup'
    $created = @()
    $wsh = New-Object -ComObject WScript.Shell

    try {
        if (-not (Test-Path -LiteralPath $programsDir)) {
            New-Item -ItemType Directory -Path $programsDir -Force | Out-Null
        }

        foreach ($entry in $Entries) {
            $scriptPath = Join-Path $PSScriptRoot $entry.Script
            $arguments = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

            foreach ($dir in @($desktopDir, $programsDir)) {
                if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) {
                    continue
                }

                $dest = Join-Path $dir $entry.WindowsFile
                $shortcut = $wsh.CreateShortcut($dest)
                $shortcut.TargetPath = $ShellPath
                $shortcut.Arguments = $arguments
                $shortcut.WorkingDirectory = $PSScriptRoot
                $shortcut.Description = $entry.Comment
                $shortcut.WindowStyle = 1
                $shortcut.Save()
                $created += $dest
            }
        }
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
    }

    return $created
}

function Install-ReactiveBackupShortcuts {
    $shellPath = Get-PowerShellHostPath
    if (-not $shellPath) {
        throw 'Could not find pwsh or powershell. Install PowerShell and re-run this script.'
    }

    $platform = Get-ReactiveBackupPlatform
    $entries = @(Get-ShortcutEntries)
    $created = @()

    switch ($platform) {
        'windows' { $created = @(Install-WindowsShortcuts -ShellPath $shellPath -Entries $entries) }
        'mac'     { $created = @(Install-MacCommandShortcuts -ShellPath $shellPath -Entries $entries) }
        default   { $created = @(Install-LinuxDesktopShortcuts -ShellPath $shellPath -Entries $entries) }
    }

    Write-Host "Created launchers ($platform):" -ForegroundColor Green
    $created | ForEach-Object { Write-Host "  $_" }
    Write-Host ""

    if ($platform -eq 'linux') {
        Write-Host "If a Desktop icon says it is untrusted, right-click it and choose Allow Launching."
        Write-Host "Do not add sudo to the launcher. User-mounted drives under /media deny root."
    }
    elseif ($platform -eq 'mac') {
        Write-Host "If macOS blocks the .command file, right-click it and choose Open."
    }

    Write-Host "The terminal stays open after the script finishes so you can read errors and logs."
}

try {
    $doShortcuts = [bool]$Shortcuts
    $doSchedule = [bool]$Schedule

    if (-not $doShortcuts -and -not $doSchedule) {
        $doShortcuts = $true
    }

    if ($doShortcuts) {
        Install-ReactiveBackupShortcuts
    }
    if ($doSchedule) {
        if ($doShortcuts) { Write-Host '' }
        Write-Host 'Scheduled backups are managed by ReactiveBackup.Create-Edit-Scheduled-Task.ps1' -ForegroundColor Cyan
        Write-Host ''
        & (Join-Path $PSScriptRoot 'ReactiveBackup.Create-Edit-Scheduled-Task.ps1')
        if ($LASTEXITCODE) {
            exit $LASTEXITCODE
        }
    }
}
catch {
    Write-Log $_.Exception.ToString() -Level Error
    Write-Host "Error managing launchers. $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check logs in the ReactiveBackup solution folder if logLevel includes errors.'
    exit 1
}
