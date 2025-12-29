# ReactiveBackup.CheckAndRun.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "Info"
    )

    # Filter based on configured log level
    # 'error' level: only show Error
    # 'info' level: show Info and Error
    $shouldLog = $false
    if ($config.logLevel -eq 'info') { $shouldLog = $true }
    elseif ($config.logLevel -eq 'error' -and $Level -eq 'Error') { $shouldLog = $true }

    if ($shouldLog) {
        $logDir = Join-Path $PSScriptRoot 'logs'
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir | Out-Null
        }
        $logPath = Join-Path $logDir "ReactiveBackup.log"
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $logPath -Value "[$timestamp] [$Level] $Message"
    }
}

# --- Load config ---
$configPath = Join-Path $PSScriptRoot 'ReactiveBackup.config'
if (-not (Test-Path $configPath)) {
    throw "Config file not found at $configPath"
}

$config = Get-Content $configPath | ConvertFrom-Json

$rootCodeDirectory   = $config.rootCodeDirectory
$rootBackupDirectory = $config.rootBackupDirectory
$logLevel            = $config.logLevel
$backupLevel         = $config.backupLevel
$includeRootFiles    = $config.includeRootFiles
$excludedSubdirs     = $config.excludedSubdirectories
$timestampFormat     = $config.timestampFormat

# Ensure the backup directory name is always excluded to prevent recursion
$backupDirName = Split-Path $rootBackupDirectory -Leaf
if ($backupDirName -and $excludedSubdirs -notcontains $backupDirName) {
    $excludedSubdirs += $backupDirName
}

# Default log level if missing
if (-not $logLevel) { $logLevel = "error" }
# Ensure config object has it for Write-Log to use
if (-not $config.PSObject.Properties.Name -contains 'logLevel') { $config | Add-Member -MemberType NoteProperty -Name 'logLevel' -Value $logLevel }

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
        [string[]]$ExcludedSubdirs
    )

    $spinner = @('|', '/', '-', '\')
    $spinIdx = 0
    $count = 0
    
    # Initial spinner
    Write-Host $spinner[0] -NoNewline

    # Get all files recursively
    $allFiles = Get-ChildItem -Path $Root -Recurse -File -Exclude $ExcludedSubdirs -ErrorAction SilentlyContinue | ForEach-Object {
        $count++
        if ($count % 10 -eq 0) {
            $spinIdx = ($spinIdx + 1) % 4
            Write-Host "`b$($spinner[$spinIdx])" -NoNewline
        }
        $_
    }

    # Filter out exclusions
    $files = $allFiles | Where-Object {
        $count++
        if ($count % 10 -eq 0) {
            $spinIdx = ($spinIdx + 1) % 4
            Write-Host "`b$($spinner[$spinIdx])" -NoNewline
        }

        $path = $_.FullName
        $shouldExclude = $false
        
        foreach ($ex in $ExcludedSubdirs) {
            # Escape the exclusion for regex and ensure it matches a directory boundary
            $pattern = [regex]::Escape($ex)
            if ($path -match "\\$pattern\\") {
                $shouldExclude = $true
                break
            }
        }
        -not $shouldExclude
    }

    # Clear spinner
    Write-Host "`b " -NoNewline

    return $files
}

# --- Main logic ---

# Determine which repositories to check based on backupLevel
$reposToCheck = @()

if ($backupLevel -eq 'repo-parent') {
    # Iterate subfolders as repos
    if (Test-Path $rootCodeDirectory) {
        $reposToCheck = Get-ChildItem -Path $rootCodeDirectory -Directory
    }
} else {
    # Default to 'repo' mode: rootCodeDirectory is the single repo
    if (Test-Path $rootCodeDirectory) {
        $reposToCheck = @(Get-Item $rootCodeDirectory)
    }
}

foreach ($repo in $reposToCheck) {
    $repoName = $repo.Name
    $repoPath = $repo.FullName
    
    # Skip the backup directory if it is found within the source directories
    $normRepo      = $repoPath.TrimEnd('\', '/')
    $normBackup    = $rootBackupDirectory.TrimEnd('\', '/')
    $backupDirName = Split-Path $normBackup -Leaf

    Write-Log "Processing repository: $repoName";

    if ($normRepo -eq $normBackup -or $repo.Name -eq $backupDirName) {
        Write-Log "Skipping backup directory: $repoName"
        Write-Host "Skipping backup directory: $repoName"
        continue
    }

    # Determine backup destination for this repo
    $repoBackupPath = Join-Path $rootBackupDirectory $repoName

    if (-not (Test-Path $repoBackupPath)) {
        New-Item -ItemType Directory -Path $repoBackupPath -Force | Out-Null
    }

    Write-Log "Checking repo: $repoName"
    Write-Host "Checking repo: $repoName... " -NoNewline

    $lastBackupTime = Get-LastBackupTime -BackupRoot $repoBackupPath
    
    try {
        $trackedFiles = Get-TrackedFiles -Root $repoPath -ExcludedSubdirs $excludedSubdirs
        Write-Host "" # Newline after spinner
    } catch {
        Write-Host "" # Newline after error
        Write-Log "  Error scanning repo $repoName : $($_.Exception.Message)" -Level Error
        Write-Host "Error scanning repo $repoName : $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    if (-not $trackedFiles) {
        Write-Log "  No tracked files found in $repoName."
        Write-Host "No tracked files found in $repoName."
        continue
    }

    $latestFileChange = ($trackedFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc

    $shouldBackup = $false
    if (-not $lastBackupTime) {
        Write-Log "  No prior backup found. Backup required."
        $shouldBackup = $true
    } elseif ($latestFileChange -gt $lastBackupTime) {
        Write-Log "  Changes detected (Last backup: $lastBackupTime, Last change: $latestFileChange). Backup required."
        $shouldBackup = $true
    } else {
        Write-Log "  No changes detected."
        Write-Host "No changes detected."
    }

    if ($shouldBackup) {
        Write-Host "Running backup for $repoName..."
        & (Join-Path $PSScriptRoot 'ReactiveBackup.ps1') -SourceDirectory $repoPath -DestinationDirectory $repoBackupPath -ExcludedSubdirectories $excludedSubdirs -IncludeRootFiles $includeRootFiles -TimestampFormat $timestampFormat -LogLevel $logLevel
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  $repoName backup successful."
        } else {
            Write-Log "  $repoName backup failed." -Level Error
        }
    }
}
