param(
    [switch]$Shortcuts,
    [switch]$Schedule
)

# Creates desktop/start-menu launchers and optional scheduled backups.
# Windows: .lnk shortcuts + Task Scheduler
# Linux: .desktop launchers + user crontab
# macOS: .command launchers + user crontab
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

function Get-JsonConfig {
    param([string]$Path)
    $content = Get-Content $Path -Raw -Encoding UTF8
    try {
        return $content | ConvertFrom-Json
    }
    catch {
        $fixed = $content -replace '(?<!\\)\\(?!["\\])', '\\'
        return $fixed | ConvertFrom-Json
    }
}

function Get-LauncherConfig {
    $defaultConfigPath = Join-Path $PSScriptRoot 'ReactiveBackup.config'
    $actualConfigPath = Join-Path $PSScriptRoot 'ReactiveBackup.actual.config'
    $config = Get-JsonConfig -Path $defaultConfigPath
    $defaultInterval = $null
    if ($config.PSObject.Properties.Name -contains 'checkForCodeChangesIntervalMinutes') {
        $defaultInterval = $config.checkForCodeChangesIntervalMinutes
    }

    if (Test-Path $actualConfigPath) {
        try {
            $actualConfig = Get-JsonConfig -Path $actualConfigPath
            $config = $actualConfig
            if ($defaultInterval -and -not ($config.PSObject.Properties.Name -contains 'checkForCodeChangesIntervalMinutes')) {
                $config | Add-Member -MemberType NoteProperty -Name 'checkForCodeChangesIntervalMinutes' -Value $defaultInterval
            }
        }
        catch {
            Write-Log "Failed to load ReactiveBackup.actual.config: $($_.Exception.Message). Using default config." -Level Error
        }
    }

    return $config
}

function Get-RepeatMinutes {
    param($Config)

    if ($Config -and ($Config.PSObject.Properties.Name -contains 'checkForCodeChangesIntervalMinutes') -and $Config.checkForCodeChangesIntervalMinutes) {
        return [int]$Config.checkForCodeChangesIntervalMinutes
    }

    throw 'Missing required config value: checkForCodeChangesIntervalMinutes'
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
            Comment     = 'Evaluate configured repos and run backups if needed'
        }
    )
}

function Get-EvaluateAndRunScriptPath {
    return (Join-Path $PSScriptRoot 'ReactiveBackup.EvaluateAndRun.ps1')
}

function Get-CronExpression {
    param([int]$Minutes)

    if ($Minutes -le 0) {
        $Minutes = 15
    }

    if ($Minutes -lt 60) {
        return "*/$Minutes * * * *"
    }

    $hours = [Math]::Max(1, [int][Math]::Floor($Minutes / 60))
    return "0 */$hours * * *"
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

function Edit-WindowsScheduledBackup {
    param(
        [int]$RepeatMinutes,
        [string]$ShellPath
    )

    $taskName = 'Reactive Backup'
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($task) {
        $taskInfo = Get-ScheduledTaskInfo $taskName
        $state = 'Unknown'
        if ($taskInfo -and ($taskInfo.PSObject.Properties.Name -contains 'TaskState')) {
            $state = $taskInfo.TaskState
        }
        Write-Host "Existing scheduled task found: $taskName"
        Write-Host "Task State: $state"

        $choice = Read-Host 'Do you want to start, stop, or delete the task? (start/stop/delete/none)'
        switch ($choice.ToLower()) {
            'start'  { Start-ScheduledTask $taskName; Write-Host 'Task started.' }
            'stop'   { Stop-ScheduledTask $taskName; Write-Host 'Task stopped.' }
            'delete' { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; Write-Host 'Task deleted.' }
            default  { Write-Host 'No changes made.' }
        }
        return
    }

    $choice = Read-Host "No scheduled task named '$taskName' found. Create it? (Y/N)"
    if ($choice.ToUpper() -ne 'Y') {
        return
    }

    $scriptPath = Get-EvaluateAndRunScriptPath
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes) `
                -RepetitionDuration (New-TimeSpan -Days 365)
    $action = New-ScheduledTaskAction -Execute $ShellPath `
                -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -ScheduledTask"
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden
    Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action `
                           -Principal $principal -Settings $settings | Out-Null
    Write-Host "Created scheduled task '$taskName' to run every $RepeatMinutes minutes (hidden)."
}

function Get-UserCrontabText {
    try {
        $text = & crontab -l 2>$null
        if ($LASTEXITCODE -ne 0) {
            return ''
        }
        return [string]$text
    }
    catch {
        return ''
    }
}

function Set-UserCrontabText {
    param([string]$Text)

    $Text | & crontab -
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to update crontab. Install cron if it is missing, then re-run this script.'
    }
}

function Remove-ReactiveBackupCronBlock {
    param([string]$CrontabText)

    $lines = @()
    $inBlock = $false
    foreach ($line in @($CrontabText -split "`r?`n")) {
        if ($line -match '^# BEGIN ReactiveBackup') {
            $inBlock = $true
            continue
        }
        if ($line -match '^# END ReactiveBackup') {
            $inBlock = $false
            continue
        }
        if (-not $inBlock) {
            $lines += $line
        }
    }

    return (($lines | Where-Object { $_ -ne $null }) -join "`n").TrimEnd()
}

function Edit-UnixScheduledBackup {
    param(
        [int]$RepeatMinutes,
        [string]$ShellPath
    )

    $crontabCmd = Get-Command crontab -ErrorAction SilentlyContinue
    if (-not $crontabCmd) {
        throw "crontab was not found. Install cron, or use EvaluateAndRun.ps1 continuous mode instead."
    }

    $scriptPath = Get-EvaluateAndRunScriptPath
    $cronExpr = Get-CronExpression -Minutes $RepeatMinutes
    $cronLine = "$cronExpr env DOTNET_SYSTEM_IO_DISABLEFILELOCKING=1 `"$ShellPath`" -NoProfile -File `"$scriptPath`" -ScheduledTask"
    $current = Get-UserCrontabText
    $hasBlock = $current -match '# BEGIN ReactiveBackup'

    if ($hasBlock) {
        Write-Host 'Existing ReactiveBackup cron entry found.'
        $choice = Read-Host 'Do you want to update or delete it? (update/delete/none)'
        switch ($choice.ToLower()) {
            'delete' {
                $next = Remove-ReactiveBackupCronBlock -CrontabText $current
                if ([string]::IsNullOrWhiteSpace($next)) {
                    & crontab -r
                }
                else {
                    Set-UserCrontabText -Text ($next + "`n")
                }
                Write-Host 'Cron entry deleted.'
            }
            'update' {
                $next = Remove-ReactiveBackupCronBlock -CrontabText $current
                $block = @"
# BEGIN ReactiveBackup
$cronLine
# END ReactiveBackup
"@
                $merged = if ([string]::IsNullOrWhiteSpace($next)) { $block } else { $next.TrimEnd() + "`n" + $block }
                Set-UserCrontabText -Text ($merged.TrimEnd() + "`n")
                Write-Host "Updated cron entry to run every $RepeatMinutes minutes ($cronExpr)."
            }
            default { Write-Host 'No changes made.' }
        }
        return
    }

    $choice = Read-Host "No ReactiveBackup cron entry found. Create it? (Y/N)"
    if ($choice.ToUpper() -ne 'Y') {
        return
    }

    $block = @"
# BEGIN ReactiveBackup
$cronLine
# END ReactiveBackup
"@
    $merged = if ([string]::IsNullOrWhiteSpace($current)) { $block } else { $current.TrimEnd() + "`n" + $block }
    Set-UserCrontabText -Text ($merged.TrimEnd() + "`n")
    Write-Host "Created cron entry to run every $RepeatMinutes minutes ($cronExpr)."
}

function Edit-ReactiveBackupSchedule {
    $config = Get-LauncherConfig
    $script:config = $config
    $repeatMinutes = Get-RepeatMinutes -Config $config
    $shellPath = Get-PowerShellHostPath
    if (-not $shellPath) {
        throw 'Could not find pwsh or powershell. Install PowerShell and re-run this script.'
    }

    $platform = Get-ReactiveBackupPlatform
    if ($platform -eq 'windows') {
        Edit-WindowsScheduledBackup -RepeatMinutes $repeatMinutes -ShellPath $shellPath
    }
    else {
        Edit-UnixScheduledBackup -RepeatMinutes $repeatMinutes -ShellPath $shellPath
    }
}

try {
    $doShortcuts = [bool]$Shortcuts
    $doSchedule = [bool]$Schedule

    if (-not $doShortcuts -and -not $doSchedule) {
        if (Test-ReactiveBackupInteractive) {
            Write-Host 'ReactiveBackup launchers' -ForegroundColor Cyan
            Write-Host '------------------------'
            Write-Host '1. Create desktop / start-menu shortcuts'
            Write-Host '2. Manage scheduled backups'
            Write-Host '3. Both'
            $selection = Read-Host 'Select an option (1-3)'
            Write-Host ""
            switch ($selection) {
                '2' { $doSchedule = $true }
                '3' { $doShortcuts = $true; $doSchedule = $true }
                default { $doShortcuts = $true }
            }
        }
        else {
            $doShortcuts = $true
        }
    }

    if ($doShortcuts) {
        Install-ReactiveBackupShortcuts
    }
    if ($doSchedule) {
        if ($doShortcuts) { Write-Host '' }
        Edit-ReactiveBackupSchedule
    }
}
catch {
    Write-Log $_.Exception.ToString() -Level Error
    Write-Host "Error managing launchers. $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check logs in the ReactiveBackup solution folder if logLevel includes errors.'
    exit 1
}
