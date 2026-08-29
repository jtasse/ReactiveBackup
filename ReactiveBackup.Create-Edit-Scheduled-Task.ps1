# ReactiveBackup.Create-Edit-Scheduled-Task.ps1
# Windows: Task Scheduler
# Linux/macOS: user crontab
# The scheduled job runs EvaluateAndRun.ps1 -ScheduledTask in the background.
# For a visible one-off or continuous backup, run ReactiveBackup.EvaluateAndRun.ps1 instead.
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
    Write-ReactiveBackupLog -Message $Message -Level $Level -Prefix '[TaskManagement] ' -Config $configForLog
}

function Wait-ForAnyKey {
    if (-not (Test-ReactiveBackupInteractive)) {
        return
    }

    Write-Host ''
    Write-Host 'Press any key to exit...'
    try {
        $null = [Console]::ReadKey($true)
        Write-Host ''
        return
    }
    catch {
    }

    try {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        Write-Host ''
        return
    }
    catch {
    }

    Read-Host 'Press Enter to exit'
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

function Get-ScheduleConfig {
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
        }
        catch {
            throw "ReactiveBackup.actual.config is not valid JSON. Quote every name in arrays (for example [""jtt"", ""repo""]). $($_.Exception.Message)"
        }
        try {
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

function Write-EvaluateAndRunReminder {
    Write-Host 'This script schedules a hidden background check that runs ReactiveBackup.EvaluateAndRun.ps1 -ScheduledTask.' -ForegroundColor Cyan
    Write-Host 'To watch a one-off or continuous backup in this window, run ReactiveBackup.EvaluateAndRun.ps1 instead.'
    Write-Host ''
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
        [string]$ShellPath,
        [string]$Platform
    )

    $crontabCmd = Get-Command crontab -ErrorAction SilentlyContinue
    if (-not $crontabCmd) {
        Write-Host "Windows Task Scheduler is not available on $Platform." -ForegroundColor Yellow
        Write-Host 'cron was not found, so a background schedule cannot be created on this machine.'
        Write-Host 'Install cron and re-run this script, or run ReactiveBackup.EvaluateAndRun.ps1 for a one-off or continuous backup in this window.'
        $script:waitForExitKey = $true
        return
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

try {
    $script:waitForExitKey = $false
    Write-EvaluateAndRunReminder

    $config = Get-ScheduleConfig
    $script:config = $config
    $repeatMinutes = Get-RepeatMinutes -Config $config
    $shellPath = Get-PowerShellHostPath
    if (-not $shellPath) {
        throw 'Could not find pwsh or powershell. Install PowerShell and re-run this script.'
    }

    $platform = Get-ReactiveBackupPlatform
    if ($platform -ne 'windows') {
        $script:waitForExitKey = $true
    }
    if ($platform -eq 'windows') {
        Edit-WindowsScheduledBackup -RepeatMinutes $repeatMinutes -ShellPath $shellPath
    }
    else {
        Edit-UnixScheduledBackup -RepeatMinutes $repeatMinutes -ShellPath $shellPath -Platform $platform
    }
}
catch {
    Write-Log $_.Exception.ToString() -Level Error
    Write-Host "Error managing scheduled backups. $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check logs in the ReactiveBackup solution folder if logLevel includes errors.'
    Wait-ForAnyKey
    exit 1
}

if ($script:waitForExitKey) {
    Wait-ForAnyKey
}
