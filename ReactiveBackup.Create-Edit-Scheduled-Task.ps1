# ReactiveBackup - Create/Edit Scheduled Task.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = "Reactive Backup"

function Write-ErrorLog {
    param([string]$Message)
    $logDir = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $logPath = Join-Path $logDir "ReactiveBackupScheduledTask.errors.log"
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logPath -Value "[$timestamp] $Message"
}

try {
    # -------------------------------
    # Load configuration
    # -------------------------------
    $defaultConfigPath = Join-Path $PSScriptRoot 'ReactiveBackup.config'
    $actualConfigPath  = Join-Path $PSScriptRoot 'ReactiveBackup.actual.config'

    # Load default config first
    $config = (Get-Content $defaultConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json

    if (Test-Path $actualConfigPath) {
        try {
            $actualConfig = (Get-Content $actualConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json
            if (-not $actualConfig.checkForCodeChangesIntervalMinutes) { throw "Missing required key: checkForCodeChangesIntervalMinutes" }
            $config = $actualConfig
        }
        catch {
            Write-ErrorLog "Failed to load ReactiveBackup.actual.config: $($_.Exception.Message). Using default config."
        }
    }

    if (-not $config.PSObject.Properties.Name -contains 'checkForCodeChangesIntervalMinutes') {
        throw "Missing required config value: checkForCodeChangesIntervalMinutes"
    }

    $repeatMinutes = [int]$config.checkForCodeChangesIntervalMinutes

    # -------------------------------
    # Check if scheduled task exists
    # -------------------------------
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($task) {
        # Robust TaskState handling
        $taskInfo = Get-ScheduledTaskInfo $taskName
        if ($taskInfo -and $taskInfo.PSObject.Properties.Name -contains 'TaskState') {
            $state = $taskInfo.TaskState
        } else {
            $state = "Unknown"
        }
        Write-Host "Existing scheduled task found: $taskName"
        Write-Host "Task State: $state"

        $choice = Read-Host "Do you want to start, stop, or delete the task? (start/stop/delete/none)"
        switch ($choice.ToLower()) {
            "start"  { Start-ScheduledTask $taskName; Write-Host "Task started." }
            "stop"   { Stop-ScheduledTask $taskName; Write-Host "Task stopped." }
            "delete" { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; Write-Host "Task deleted." }
            default  { Write-Host "No changes made." }
        }
    }
    else {
        $choice = Read-Host "No scheduled task named '$taskName' found. Create it? (Y/N)"
        if ($choice.ToUpper() -eq 'Y') {
            $scriptPath = Join-Path $PSScriptRoot 'ReactiveBackup.EvaluateAndRun.ps1'

            # Trigger: start 1 min from now, repeat every X minutes, duration 1 year
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                        -RepetitionInterval (New-TimeSpan -Minutes $repeatMinutes) `
                        -RepetitionDuration (New-TimeSpan -Days 365)

            # Action: run PowerShell hidden
            $action = New-ScheduledTaskAction -Execute "powershell.exe" `
                        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -ScheduledTask"

            # Register the task
            Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action `
                                   -RunLevel Limited -User $env:USERNAME

            Write-Host "Created scheduled task '$taskName' to run every $repeatMinutes minutes (hidden)."
        }
    }
}
catch {
    Write-ErrorLog $_.Exception.ToString()
    Write-Host "Error managing scheduled task. Check logs." -ForegroundColor Red
}
