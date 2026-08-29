$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "ASSERTION FAILED: $Message. Expected '$Expected' but got '$Actual'."
    }
}

. (Join-Path $PSScriptRoot 'ReactiveBackup.Common.ps1')

$base = Get-Date '2026-08-29T12:00:00Z'

function Get-Decision {
    param(
        [string[]]$Names,
        [int]$ThresholdMb = 10240,
        [int]$TotalThresholdMb = 0,
        [bool]$TotalExceeded = $false,
        $State = $null,
        [datetime]$Now = $base
    )

    return Get-ReactiveBackupThresholdAlertDecision -ExceedingRepoNames $Names -ThresholdMb $ThresholdMb -TotalThresholdMb $TotalThresholdMb -TotalExceeded $TotalExceeded -State $State -Now $Now
}

$none = Get-Decision -Names @()
Assert-True $none.ClearState 'no exceeding folders should clear state'
Assert-True (-not $none.Send) 'no exceeding folders should not send'

$first = Get-Decision -Names @('meowlin')
Assert-True $first.Send 'first crossing should send'
Assert-Equal $first.Step 1 'first email is step 1'
Assert-True (-not $first.State.sleeping) 'first email should not sleep'

$sameNextHour = Get-Decision -Names @('meowlin') -State $first.State -Now $base.AddHours(1)
Assert-True (-not $sameNextHour.Send) 'should not resend before 3 days'
Assert-Equal $sameNextHour.Step 1 'step stays 1 while waiting'

$day3 = Get-Decision -Names @('meowlin') -State $first.State -Now $base.AddDays(3)
Assert-True $day3.Send 'second reminder at 3 days'
Assert-Equal $day3.Step 2 'second email is step 2'

$day7 = Get-Decision -Names @('meowlin') -State $day3.State -Now $base.AddDays(7)
Assert-True $day7.Send 'final reminder at 7 days'
Assert-Equal $day7.Step 3 'final email is step 3'
Assert-True $day7.State.sleeping 'final reminder should sleep'

$afterSleep = Get-Decision -Names @('meowlin') -State $day7.State -Now $base.AddDays(30)
Assert-True (-not $afterSleep.Send) 'sleeping set should not send again'
Assert-True $afterSleep.State.sleeping 'should remain sleeping'

$newRepo = Get-Decision -Names @('meowlin', 'jtt') -State $day7.State -Now $base.AddDays(30)
Assert-True $newRepo.Send 'a new exceeding folder should start a new cycle'
Assert-Equal $newRepo.Step 1 'new folder resets to step 1'

$thresholdChange = Get-Decision -Names @('meowlin') -ThresholdMb 20480 -State $first.State -Now $base.AddHours(1)
Assert-True $thresholdChange.Send 'changing the threshold should send again'
Assert-Equal $thresholdChange.State.thresholdMb 20480 'new threshold is stored'

$totalOnly = Get-Decision -Names @() -TotalThresholdMb 51200 -TotalExceeded $true
Assert-True $totalOnly.Send 'total-only exceed should send'
Assert-True ($totalOnly.State.fingerprint -eq '__TOTAL__') 'total-only fingerprint is __TOTAL__'

$totalThenRepo = Get-Decision -Names @('jtt') -TotalThresholdMb 51200 -TotalExceeded $true -State $totalOnly.State
Assert-True $totalThenRepo.Send 'a new per-repo exceed should reset after total-only'

$totalThresholdChange = Get-Decision -Names @() -TotalThresholdMb 20480 -TotalExceeded $true -State $totalOnly.State
Assert-True $totalThresholdChange.Send 'changing the total threshold should send again'
Assert-Equal $totalThresholdChange.State.totalThresholdMb 20480 'new total threshold is stored'

$includedNames = @(Get-ReactiveBackupConfiguredBackupFolderNames -Config ([pscustomobject]@{
    backupLevel = 'repo-parent'
    includedRepoFolders = @('jtt', 'ReactiveBackup')
    excludedRepoFolders = @()
    rootCodeDirectory = 'C:\dev\github'
    rootBackupDirectory = 'C:\dev\github\_BACKUPS'
}))
Assert-Equal (($includedNames -join ',')) 'jtt,ReactiveBackup' 'include list is the configured set'

$repoModeNames = @(Get-ReactiveBackupConfiguredBackupFolderNames -Config ([pscustomobject]@{
    backupLevel = 'repo'
    includedRepoFolders = @()
    excludedRepoFolders = @()
    rootCodeDirectory = 'C:\dev\github\jtt'
    rootBackupDirectory = 'C:\dev\github\_BACKUPS\jtt'
}))
Assert-Equal $repoModeNames[0] 'jtt' 'repo mode uses the source folder name'

$smtpBlank = [pscustomobject]@{
    smtpHost = ''
    smtpUsername = ''
    smtpPassword = ''
    alertEmail = ''
    smtpFrom = ''
    smtpPort = 0
}
Assert-Equal (Get-ReactiveBackupSmtpStatus -Config $smtpBlank) 'blank' 'all-empty SMTP is blank'

$smtpPartial = [pscustomobject]@{
    smtpHost = 'smtp.gmail.com'
    smtpUsername = 'james.tasse@gmail.com'
    smtpPassword = ''
    alertEmail = 'james.tasse@gmail.com'
    smtpFrom = 'james.tasse@gmail.com'
    smtpPort = 587
}
Assert-Equal (Get-ReactiveBackupSmtpStatus -Config $smtpPartial) 'partial' 'missing password is partial'

$smtpReady = [pscustomobject]@{
    smtpHost = 'smtp.gmail.com'
    smtpUsername = 'james.tasse@gmail.com'
    smtpPassword = 'app-password'
    alertEmail = 'james.tasse@gmail.com'
    smtpFrom = ''
    smtpPort = 587
}
Assert-Equal (Get-ReactiveBackupSmtpStatus -Config $smtpReady) 'ready' 'from can default to username'

$skipLeftovers = Get-ReactiveBackupConfigBool -Config $smtpReady -Name 'includeUnconfiguredBackupFoldersInSizeAlerts'
Assert-True (-not $skipLeftovers) 'unconfigured scan defaults to false'
$includeLeftovers = Get-ReactiveBackupConfigBool -Config ([pscustomobject]@{ includeUnconfiguredBackupFoldersInSizeAlerts = $true }) -Name 'includeUnconfiguredBackupFoldersInSizeAlerts'
Assert-True $includeLeftovers 'unconfigured scan can be enabled'

$body = New-ReactiveBackupThresholdAlertBody -MachineName 'TESTPC' -ThresholdMb 10240 -Step 1 -ExceedingFolders @(
    [pscustomobject]@{ Name = 'meowlin'; Path = 'C:\backups\meowlin'; SizeBytes = 15GB }
)
Assert-True ($body -match 'TESTPC') 'body includes machine name'
Assert-True ($body -match 'meowlin') 'body lists the repo'
Assert-True ($body -match 'two more reminders') 'first email describes the reminder sequence'
Assert-True ($body -match 'Configured repo folders over') 'per-repo section is labeled'

$totalBody = New-ReactiveBackupThresholdAlertBody -MachineName 'TESTPC' -ThresholdMb 10240 -TotalThresholdMb 51200 -Step 1 -ExceedingFolders @() -TotalFolder ([pscustomobject]@{
    Name = '_BACKUPS'
    Path = 'C:\backups'
    SizeBytes = 60GB
})
Assert-True ($totalBody -match 'Entire backup folder over') 'total section is labeled'
Assert-True ($totalBody -notmatch 'Configured repo folders over') 'total-only email omits the per-repo section'

Write-Host 'All threshold-alert tests passed.' -ForegroundColor Green
