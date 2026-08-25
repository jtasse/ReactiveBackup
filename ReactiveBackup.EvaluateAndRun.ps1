param([switch]$ScheduledTask, [switch]$Once)

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

function Get-NormalizedRelativePath {
    param(
        [string]$Path,
        [string]$Root
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $relative = $pathFull.Substring($rootFull.Length).TrimStart('\', '/')
    return ($relative -replace '\\', '/').Trim('/')
}

function Test-RelativePathExcluded {
    param(
        [string]$RelativePath,
        [string[]]$ExcludedSegments
    )

    $normalized = ($RelativePath -replace '\\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }

    foreach ($ex in $ExcludedSegments) {
        $segment = ($ex -replace '\\', '/').Trim('/')
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        if ($normalized -eq $segment) {
            return $true
        }

        if ($normalized.StartsWith($segment + '/')) {
            return $true
        }

        if ($normalized.Contains('/' + $segment + '/')) {
            return $true
        }
    }

    return $false
}

function Get-RelativePathSet {
    param(
        [string]$Root,
        [string[]]$IncludedRepoSubfolders,
        [string[]]$ExcludedRepoSubfolders,
        [bool]$IncludeRootFiles
    )

    $files = @()

    if ($IncludedRepoSubfolders -and $IncludedRepoSubfolders.Count -gt 0) {
        if ($IncludeRootFiles) {
            $files += Get-ChildItem -Path $Root -File -Force -ErrorAction SilentlyContinue
        }

        foreach ($sub in $IncludedRepoSubfolders) {
            $subPath = Join-Path $Root $sub
            if (Test-Path $subPath) {
                $files += Get-ChildItem -Path $subPath -Recurse -File -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        $files = @(Get-ChildItem -Path $Root -Recurse -File -Force -ErrorAction SilentlyContinue)
    }

    $relativePaths = @()
    foreach ($file in $files) {
        $relativePath = Get-NormalizedRelativePath -Path $file.FullName -Root $Root
        if (-not $IncludeRootFiles -and $relativePath.IndexOf('/') -lt 0) {
            continue
        }

        if ($ExcludedRepoSubfolders -and (Test-RelativePathExcluded -RelativePath $relativePath -ExcludedSegments $ExcludedRepoSubfolders)) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
            $relativePaths += $relativePath
        }
    }

    return @($relativePaths | Sort-Object -Unique)
}

# --- Get last backup directory/time ---
function Get-LastBackupDirectory {
    param (
        [string]$BackupRoot
    )

    if (-not (Test-Path $BackupRoot)) {
        return $null
    }

    $dirs = @(Get-ChildItem -Path $BackupRoot -Directory -ErrorAction SilentlyContinue)
    if (-not $dirs -or $dirs.Count -eq 0) {
        return $null
    }

    return ($dirs | Sort-Object { $_.LastWriteTimeUtc } -Descending | Select-Object -First 1)
}

function Get-LastBackupTime {
    param (
        [string]$BackupRoot
    )

    $lastBackup = Get-LastBackupDirectory -BackupRoot $BackupRoot
    if (-not $lastBackup) {
        return $null
    }

    return $lastBackup.LastWriteTimeUtc
}

function Get-InventoryChange {
    param(
        [string]$RepoPath,
        [string]$BackupRoot,
        [string[]]$IncludedRepoSubfolders,
        [string[]]$ExcludedRepoSubfolders,
        [bool]$IncludeRootFiles
    )

    if (-not (Test-Path $BackupRoot)) {
        return $false
    }

    $currentSet = @(Get-RelativePathSet -Root $RepoPath -IncludedRepoSubfolders $IncludedRepoSubfolders -ExcludedRepoSubfolders $ExcludedRepoSubfolders -IncludeRootFiles $IncludeRootFiles)
    $backupSet = @()

    if (Test-Path $BackupRoot) {
        $backupSet = @(Get-RelativePathSet -Root $BackupRoot -IncludedRepoSubfolders @() -ExcludedRepoSubfolders $ExcludedRepoSubfolders -IncludeRootFiles $true)
    }

    if ($currentSet.Count -ne $backupSet.Count) {
        return $true
    }

    return @(Compare-Object -ReferenceObject $currentSet -DifferenceObject $backupSet).Count -gt 0
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
    
    Write-Host $spinner[0] -NoNewline

    $files = @()

    if ($IncludedRepoSubfolders -and $IncludedRepoSubfolders.Count -gt 0) {
        $candidates = @()
        if ($IncludeRootFiles) {
            $candidates += Get-ChildItem -Path $Root -File -Force -ErrorAction SilentlyContinue
        }
        foreach ($sub in $IncludedRepoSubfolders) {
            $path = Join-Path $Root $sub
            if (Test-Path $path) {
                $candidates += Get-ChildItem -Path $path -Recurse -File -Force -ErrorAction SilentlyContinue
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
        $allFiles = @(Get-ChildItem -Path $Root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $count++
            if ($count % 10 -eq 0) {
                $spinIdx = ($spinIdx + 1) % 4
                Write-Host "`b$($spinner[$spinIdx])" -NoNewline
            }
            $_
        })

        $files = @($allFiles | Where-Object {
            $relativePath = Get-NormalizedRelativePath -Path $_.FullName -Root $Root
            if (-not $IncludeRootFiles -and $relativePath.IndexOf('/') -lt 0) {
                return $false
            }

            if (Test-RelativePathExcluded -RelativePath $relativePath -ExcludedSegments $ExcludedRepoSubfolders) {
                return $false
            }

            return $true
        })
    }

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
        
        $normRepo      = $repoPath.TrimEnd('\', '/')
        $normBackup    = $rootBackupDirectory.TrimEnd('\', '/')
        $backupDirName = Split-Path $normBackup -Leaf

        Write-Log "Processing repository: $repoName";

        if ($normRepo -eq $normBackup -or $repo.Name -eq $backupDirName) {
            Write-Log "Skipping backup directory: $repoName"
            Write-Host "Skipping backup directory: $repoName"
            continue
        }

        $repoBackupPath = Join-Path $rootBackupDirectory $repoName

        if (-not (Test-Path $repoBackupPath)) {
            New-Item -ItemType Directory -Path $repoBackupPath -Force | Out-Null
        }

        Write-Log "Checking repo: $repoName"
        Write-Host "Checking repo: $repoName... " -NoNewline

        $lastBackupDirectory = Get-LastBackupDirectory -BackupRoot $repoBackupPath
        $lastBackupTime = if ($lastBackupDirectory) { $lastBackupDirectory.LastWriteTimeUtc } else { $null }
        
        try {
            $trackedFiles = Get-TrackedFiles -Root $repoPath -IncludedRepoSubfolders $includedRepoSubfolders -ExcludedRepoSubfolders $excludedRepoSubfolders -IncludeRootFiles $includeRootFiles
            Write-Host "" 
        } catch {
            Write-Host ""
            Write-Log "  Error scanning repo $repoName : $($_.Exception.Message)" -Level Error
            Write-Host "Error scanning repo $repoName : $($_.Exception.Message)" -ForegroundColor Red
            continue
        }

        $shouldBackup = $false

        if (-not $trackedFiles) {
            if ($lastBackupDirectory) {
                Write-Log "  Repo has no tracked files and a prior backup exists. Deletion detected. Backup required."
                Write-Host "Repository has no tracked files; deletion detected. Backup required."
                $shouldBackup = $true
            } else {
                Write-Log "  No tracked files found in $repoName and no prior backup exists."
                Write-Host "No tracked files found in $repoName."
            }
        } else {
            $latestFileChange = ($trackedFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc

            if (-not $lastBackupTime) {
                Write-Log "  No prior backup found. Backup required."
                $shouldBackup = $true
            } elseif ($latestFileChange -gt $lastBackupTime) {
                Write-Log "  Changes detected (Last backup: $lastBackupTime, Last change: $latestFileChange). Backup required."
                $shouldBackup = $true
            }
        }

        if (-not $shouldBackup -and $lastBackupDirectory) {
            $backupCodePath = Join-Path $lastBackupDirectory.FullName 'code'
            $inventoryChanged = Get-InventoryChange -RepoPath $repoPath -BackupRoot $backupCodePath -IncludedRepoSubfolders $includedRepoSubfolders -ExcludedRepoSubfolders $excludedRepoSubfolders -IncludeRootFiles $includeRootFiles
            if ($inventoryChanged) {
                Write-Log "  Inventory comparison shows a created or deleted file. Backup required."
                $shouldBackup = $true
            }
        }

        if (-not $shouldBackup) {
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
} elseif ($Once) {
    Invoke-BackupCycle | Out-Null
} elseif ($MyInvocation.InvocationName -ne '.') {
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