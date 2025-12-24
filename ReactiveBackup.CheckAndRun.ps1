# ReactiveBackup.CheckAndRun.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)

    $logDir = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }

    $logPath = Join-Path $logDir "ReactiveBackup.log"
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logPath -Value "[$timestamp] $Message"
}

# --- Load config ---
$configPath = Join-Path $PSScriptRoot 'ReactiveBackup.config'
if (-not (Test-Path $configPath)) {
    throw "Config file not found at $configPath"
}

$config = Get-Content $configPath | ConvertFrom-Json

$rootCodeDirectory   = $config.rootCodeDirectory
$backupRootDirectory = $config.backupRootDirectory
$includeRootFiles    = $config.includeRootFiles
$includedSubdirs     = $config.includedSubdirectories
$timestampFormat     = $config.timestampFormat

# --- Get last backup time ---
function Get-LastBackupTime {
    param (
        [string]$BackupRoot
    )

    if (-not (Test-Path $BackupRoot)) {
        return $null
    }

    $dirs = Get-ChildItem -Path $BackupRoot -Directory -ErrorAction SilentlyContinue
    if (-not $dirs) {
        return $null
    }

    return ($dirs |
        Sort-Object { $_.LastWriteTimeUtc } -Descending |
        Select-Object -First 1
    ).LastWriteTimeUtc
}


# --- Get tracked files ---
function Get-TrackedFiles {
    param (
        [string]$Root,
        [bool]$IncludeRootFiles,
        [string[]]$IncludedSubdirs
    )

    $files = @()

    if ($IncludeRootFiles) {
        $files += Get-ChildItem -Path $Root -File -ErrorAction SilentlyContinue
    }

    foreach ($sub in $IncludedSubdirs) {
        $fullPath = Join-Path $Root $sub
        if (Test-Path $fullPath) {
            $files += Get-ChildItem -Path $fullPath -Recurse -File -ErrorAction SilentlyContinue
        }
    }

    return $files
}

# --- Main logic ---
$lastBackupTime = Get-LastBackupTime `
    -BackupRoot $backupRootDirectory

$trackedFiles = Get-TrackedFiles `
    -Root $rootCodeDirectory `
    -IncludeRootFiles $includeRootFiles `
    -IncludedSubdirs $includedSubdirs

Write-Log "Tracked files: $($trackedFiles))"

if (-not $trackedFiles) {
    Write-Log "No tracked files found. Exiting."
    return
}

$latestFileChange = ($trackedFiles |
    Sort-Object { $_.LastWriteTimeUtc } -Descending |
    Select-Object -First 1).LastWriteTimeUtc

if (-not $lastBackupTime) {
    Write-Log "No prior backup found. Running initial backup."
    & (Join-Path $PSScriptRoot 'ReactiveBackup.ps1')
    return
}

Write-Log "Last backup time: $lastBackupTime"
Write-Log "Latest file change: $latestFileChange"

if ($latestFileChange -gt $lastBackupTime) {
    Write-Log "Changes detected. Running backup."
    & (Join-Path $PSScriptRoot 'ReactiveBackup.ps1')
}
else {
    Write-Log "No changes detected. Backup not required."
}
