# ReactiveBackup.Run-Scheduled.ps1
# Stable Task Scheduler entrypoint. Resolves the current pwsh.exe on each run
# (MSI or Store package) so PowerShell updates do not break the scheduled task.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ReactiveBackup.Common.ps1')

$evaluateScript = Join-Path $PSScriptRoot 'ReactiveBackup.EvaluateAndRun.ps1'
if (-not (Test-Path -LiteralPath $evaluateScript)) {
    throw "EvaluateAndRun script not found: $evaluateScript"
}

$pwsh = Get-PwshExecutablePath
if (-not $pwsh) {
    throw 'Could not find pwsh. Install PowerShell and re-run ReactiveBackup.Create-Edit-Scheduled-Task.ps1.'
}

$argList = @(
    '-NoProfile'
    '-WindowStyle'
    'Hidden'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    $evaluateScript
    '-ScheduledTask'
)

$process = Start-Process -FilePath $pwsh -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
$code = 0
if ($null -ne $process -and $null -ne $process.ExitCode) {
    $code = [int]$process.ExitCode
}

exit $code
