param([switch]$ScheduledTask)

# ReactiveBackup.EvaluateAndRun.ps1
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
    $currentLogLevel = if ($config -and $config.logLevel) { $config.logLevel } else { "error" }

    if ($currentLogLevel -eq 'info') { $shouldLog = $true }
    elseif ($currentLogLevel -eq 'error' -and $Level -eq 'Error') { $shouldLog = $true }

    if ($shouldLog) {
        $logDir = Join-Path $PSScriptRoot 'logs'
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir | Out-Null
        }
        $logPath = Join-Path $logDir "ReactiveBackup.log"
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $prefix = if ($ScheduledTask) { "[ScheduledTask] " } else { "" }
        Add-Content -Path $logPath -Value "[$timestamp] [$Level] $prefix$Message"
    }
}

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
        [string[]]$IncludedRepoSubfolders,
        [string[]]$ExcludedRepoSubfolders,
        [bool]$IncludeRootFiles
    )

    $spinner = @('|', '/', '-', '\')
    $spinIdx = 0
    $count = 0
    
    # Initial spinner
    Write-Host $spinner[0] -NoNewline

    $files = @()

    if ($IncludedRepoSubfolders -and $IncludedRepoSubfolders.Count -gt 0) {
        # --- INCLUSION MODE ---
        $candidates = @()
        if ($IncludeRootFiles) {
            $candidates += Get-ChildItem -Path $Root -File -ErrorAction SilentlyContinue
        }
        foreach ($sub in $IncludedRepoSubfolders) {
            $path = Join-Path $Root $sub
            if (Test-Path $path) {
                $candidates += Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue
            }
        }
        
        $files = @($candidates | ForEach-Object {
            $count++
            if ($count % 10 -eq 0) {
                $spinIdx = ($spinIdx + 1) % 4
                Write-Host "`b$($spinner[$spinIdx])" -NoNewline
            }
            $_
        })
    } 
    else {
        # --- EXCLUSION MODE ---
        # Get all files recursively
        $allFiles = @(Get-ChildItem -Path $Root -Recurse -File -Exclude $ExcludedRepoSubfolders -ErrorAction SilentlyContinue | ForEach-Object {
            $count++
            if ($count % 10 -eq 0) {
                $spinIdx = ($spinIdx + 1) % 4
                Write-Host "`b$($spinner[$spinIdx])" -NoNewline
            }
            $_
        })

        # Filter out exclusions
        $files = @($allFiles | Where-Object {
            $count++
            if ($count % 10 -eq 0) {
                $spinIdx = ($spinIdx + 1) % 4
                Write-Host "`b$($spinner[$spinIdx])" -NoNewline
            }

            $path = $_.FullName
            $shouldExclude = $false
            
            foreach ($ex in $ExcludedRepoSubfolders) {
                $pattern = [regex]::Escape($ex)
                if ($path -match "\\$pattern\\") {
                    $shouldExclude = $true
                    break
                }
            }
            -not $shouldExclude
        })
    }

    # Clear spinner
    Write-Host "`b " -NoNewline

    return $files
}

function Invoke-BackupCycle {
    # --- Load config ---
    $defaultConfigPath = Join-Path $PSScriptRoot 'ReactiveBackup.config'
    if (-not (Test-Path $defaultConfigPath)) {
        throw "Config file not found at $defaultConfigPath"
    }

    function Get-JsonConfig {
        param([string]$Path)
        $content = Get-Content $Path -Raw -Encoding UTF8
        try {
            return $content | ConvertFrom-Json
        } catch {
            # Fix unescaped backslashes: \ not preceded by \ and not followed by \ or "
            $fixed = $content -replace '(?<!\\)\\(?!["\\])', '\\'
            return $fixed | ConvertFrom-Json
        }
    }

    # Load default config first
    $config = Get-JsonConfig -Path $defaultConfigPath
    $defaultInterval = $config.checkForCodeChangesIntervalMinutes

    $actualConfigPath = Join-Path $PSScriptRoot 'ReactiveBackup.actual.config'
    if (Test-Path $actualConfigPath) {
        try {
            $actualConfig = Get-JsonConfig -Path $actualConfigPath
            if (-not $actualConfig.rootCodeDirectory -or -not $actualConfig.rootBackupDirectory) {
                throw "Missing required keys: rootCodeDirectory or rootBackupDirectory"
            }
            $config = $actualConfig

            if (-not $config.PSObject.Properties.Name -contains 'checkForCodeChangesIntervalMinutes') {
                $config | Add-Member -MemberType NoteProperty -Name 'checkForCodeChangesIntervalMinutes' -Value $defaultInterval
            }
        }
        catch {
            Write-Log "Failed to load ReactiveBackup.actual.config: $($_.Exception.Message). Using default config." -Level Error
        }
    }

    $rootCodeDirectory   = $config.rootCodeDirectory
    $rootBackupDirectory = $config.rootBackupDirectory
    $logLevel            = $config.logLevel
    $backupLevel         = $config.backupLevel
    $includeRootFiles    = $config.includeRootFiles
    $includedRepoFolders = $config.includedRepoFolders
    $excludedRepoFolders = $config.excludedRepoFolders
    $includedRepoSubfolders = $config.includedRepoSubfolders
    $excludedRepoSubfolders = $config.excludedRepoSubfolders
    $timestampFormat     = $config.timestampFormat

    # Normalize paths to support forward slashes (JSON friendly) and network paths
    $rootCodeDirectory = [System.IO.Path]::GetFullPath($rootCodeDirectory)
    $rootBackupDirectory = [System.IO.Path]::GetFullPath($rootBackupDirectory)

    # Ensure the backup directory name is always excluded to prevent recursion
    $backupDirName = Split-Path $rootBackupDirectory -Leaf
    if ($backupDirName -and $excludedRepoSubfolders -notcontains $backupDirName) {
        $excludedRepoSubfolders += $backupDirName
    }

    # Default log level if missing
    if (-not $logLevel) { $logLevel = "error" }
    # Ensure config object has it for Write-Log to use
    if (-not $config.PSObject.Properties.Name -contains 'logLevel') { $config | Add-Member -MemberType NoteProperty -Name 'logLevel' -Value $logLevel }

    # --- Main logic ---

    # Determine which repositories to check based on backupLevel
    $reposToCheck = @()

    if ($backupLevel -eq 'repo-parent') {
        # Iterate subfolders as repos
        if (Test-Path $rootCodeDirectory) {
            $allRepos = Get-ChildItem -Path $rootCodeDirectory -Directory
            
            if ($includedRepoFolders -and $includedRepoFolders.Count -gt 0) {
                $reposToCheck = $allRepos | Where-Object { $includedRepoFolders -contains $_.Name }
            } else {
                $reposToCheck = $allRepos | Where-Object { $excludedRepoFolders -notcontains $_.Name }
            }
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
            $trackedFiles = Get-TrackedFiles -Root $repoPath -IncludedRepoSubfolders $includedRepoSubfolders -ExcludedRepoSubfolders $excludedRepoSubfolders -IncludeRootFiles $includeRootFiles
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
            & (Join-Path $PSScriptRoot 'ReactiveBackup.ps1') -SourceDirectory $repoPath -DestinationDirectory $repoBackupPath -IncludedRepoSubfolders $includedRepoSubfolders -ExcludedRepoSubfolders $excludedRepoSubfolders -IncludeRootFiles $includeRootFiles -TimestampFormat $timestampFormat -LogLevel $logLevel | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "  $repoName backup successful."
            } else {
                Write-Log "  $repoName backup failed." -Level Error
            }
        }
    }

    return $config.checkForCodeChangesIntervalMinutes
}

if ($ScheduledTask) {
    Invoke-BackupCycle *>$null
} else {
    Write-Host "Reactive Backup Evaluation Script" -ForegroundColor Cyan
    Write-Host "--------------------------"
    Write-Host "1. Run Once"
    Write-Host "2. Run Continuously"
    
    $selection = Read-Host "Select an option (1-2)"
    
    if ($selection -eq '2') {
        Write-Host "Starting continuous backup mode. Press Ctrl+C to stop." -ForegroundColor Yellow
        $interval = 15
        while ($true) {
            $runInterval = Invoke-BackupCycle
            if ($runInterval) { $interval = $runInterval }
            
            Write-Host "Current time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
            Write-Host "Sleeping for $interval minutes..." -ForegroundColor Gray
            Start-Sleep -Seconds ($interval * 60)
        }
    } else {
        Invoke-BackupCycle | Out-Null
    }
}