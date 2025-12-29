# ReactiveBackup.ps1
# -------------------------------
# Parameters (Override config if provided)
# -------------------------------
param(
    [string]$SourceDirectory,
    [string]$DestinationDirectory,
    [string[]]$ExcludedSubdirectories,
    [bool]$IncludeRootFiles,
    [string]$TimestampFormat,
    [string]$LogLevel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$backupSucceeded = $false
$backupRoot = $null

# -------------------------------
# Centralized Solution Logging
# -------------------------------
function Write-SolutionLog {
    param (
        [string]$Message,
        [string]$Level = "Info"
    )

    $shouldLog = $false
    if ($LogLevel -eq 'info') { $shouldLog = $true }
    elseif ($LogLevel -eq 'error' -and $Level -eq 'Error') { $shouldLog = $true }

    if ($shouldLog) {
        $logDir = Join-Path $PSScriptRoot 'logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
        $logPath = Join-Path $logDir "ReactiveBackup.log"
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $logPath -Value "[$timestamp] [$Level] $Message"
    }
}

try {
    # -------------------------------
    # Load configuration
    # -------------------------------
    $configPath = Join-Path $PSScriptRoot 'ReactiveBackup.config'
    $config     = (Get-Content $configPath -Raw -Encoding UTF8) | ConvertFrom-Json

    # Use param if provided, otherwise config, otherwise default
    if (-not $LogLevel) { $LogLevel = $config.logLevel }
    if (-not $LogLevel) { $LogLevel = "error" }

    # -------------------------------
    # Handle 'repo-parent' mode (Batch Mode)
    # -------------------------------
    if (-not $SourceDirectory -and $config.backupLevel -eq 'repo-parent') {
        Write-Host "Running in 'repo-parent' mode. Checking repositories..." -ForegroundColor Cyan
        $repoName = "All Repositories"
        
        $rootSrc = $config.rootCodeDirectory
        $rootDest = $config.rootBackupDirectory
        $excl = $config.excludedSubdirectories
        $incRoot = [bool]$config.includeRootFiles
        $fmt = $config.timestampFormat

        # Ensure backup dir is excluded
        $backupDirName = Split-Path $rootDest.TrimEnd('\', '/') -Leaf
        if ($backupDirName -and $excl -notcontains $backupDirName) {
            $excl += $backupDirName
        }

        $repos = Get-ChildItem -Path $rootSrc -Directory
        $anyFailure = $false

        foreach ($repo in $repos) {
            $normRepo = $repo.FullName.TrimEnd('\', '/')
            $normBackup = $rootDest.TrimEnd('\', '/')
            
            if ($normRepo -eq $normBackup -or $repo.Name -eq $backupDirName) {
                Write-Host "Skipping backup directory: $($repo.Name)"
                continue
            }

            $repoDest = Join-Path $rootDest $repo.Name
            & $PSCommandPath -SourceDirectory $repo.FullName -DestinationDirectory $repoDest -ExcludedSubdirectories $excl -IncludeRootFiles $incRoot -TimestampFormat $fmt -LogLevel $LogLevel
            if ($LASTEXITCODE -ne 0) { $anyFailure = $true }
        }

        $backupSucceeded = (-not $anyFailure)
        if ($backupSucceeded) { exit 0 } else { exit 1 }
    }

    # Use params if provided, otherwise fall back to config
    if (-not $SourceDirectory) { $SourceDirectory = $config.rootCodeDirectory }
    if (-not $DestinationDirectory) { $DestinationDirectory = $config.rootBackupDirectory }
    if (-not $ExcludedSubdirectories) { $ExcludedSubdirectories = $config.excludedSubdirectories }
    if (-not $TimestampFormat) { $TimestampFormat = $config.timestampFormat }
    # Handle boolean explicitly to avoid null issues
    if (-not $PSBoundParameters.ContainsKey('IncludeRootFiles')) { 
        $IncludeRootFiles = [bool]$config.includeRootFiles 
    }

    # Validate required paths
    if (-not $SourceDirectory) { throw "Source directory is not defined." }
    if (-not $DestinationDirectory) { throw "Destination directory is not defined." }

    if (-not (Test-Path $SourceDirectory)) {
        throw "Source directory not found: $SourceDirectory"
    }

    if (-not (Test-Path $DestinationDirectory)) {
        New-Item -ItemType Directory -Path $DestinationDirectory | Out-Null
    }

    $repoName = Split-Path $SourceDirectory.TrimEnd('\', '/') -Leaf

    # -------------------------------
    # Generate Windows-safe timestamp
    # -------------------------------
    $rawTimestamp = Get-Date -Format $TimestampFormat
    $timestamp = $rawTimestamp `
        -replace ':', '.' `
        -replace '/', '-' `
        -replace '\\', '-'

    $backupRoot = Join-Path $DestinationDirectory $timestamp
    New-Item -ItemType Directory -Path $backupRoot | Out-Null

    # -------------------------------
    # Create backup subfolders
    # -------------------------------
    $codeBackupPath = Join-Path $backupRoot 'code'
    $dataBackupPath = Join-Path $backupRoot 'backup data'

    New-Item -ItemType Directory -Path $codeBackupPath | Out-Null
    New-Item -ItemType Directory -Path $dataBackupPath | Out-Null

    # -------------------------------
    # Per-Backup Log Helper
    # -------------------------------
    $backupLogPath = Join-Path $dataBackupPath 'backup.log'
    
    function Write-BackupLog {
        param (
            [string]$Message,
            [string]$Level = "Info"
        )
        $shouldLog = $false
        if ($LogLevel -eq 'info') { $shouldLog = $true }
        elseif ($LogLevel -eq 'error' -and $Level -eq 'Error') { $shouldLog = $true }

        if ($shouldLog) { Add-Content $backupLogPath $Message }
    }

    Write-BackupLog "Backup started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-BackupLog "Source: $SourceDirectory"

    # -------------------------------
    # Gather files
    # -------------------------------
    $spinner = @('|', '/', '-', '\')
    $prepSpinIdx = 0
    $repoBackupCount = 0
    $prepareMsg = "Preparing to back up files in $SourceDirectory..."
    "" # write blank line
    Write-Host -NoNewline "$($spinner[0]) $prepareMsg"

    try {
        $allFiles = Get-ChildItem -Path $SourceDirectory -Recurse -File | ForEach-Object {
            $repoBackupCount++
            if ($repoBackupCount % 10 -eq 0) {
                $prepSpinIdx = ($prepSpinIdx + 1) % 4
                Write-Host -NoNewline "`r$($spinner[$prepSpinIdx]) $prepareMsg"
            }
            $_
        }
    }
    catch {
        Write-Host "`r$prepareMsg - Failed" -ForegroundColor Red
        Write-SolutionLog "Error preparing backup for $SourceDirectory : $($_.Exception.Message)" -Level Error
        exit 1
    }
    Write-Host "`r$prepareMsg - Found $($allFiles.Count) files."
    $anyFileError = $false
    
    # Progress spinner setup
    $spinnerIndex = 0
    $fileCounter = 0
    
    $progressMsg = "Backing up files in $SourceDirectory..."
    Write-Host -NoNewline "$($spinner[0]) $progressMsg"

    foreach ($file in $allFiles) {
        # Update spinner every 10 files
        $fileCounter++
        if ($fileCounter % 10 -eq 0) {
            $spinnerIndex = ($spinnerIndex + 1) % 4
            Write-Host -NoNewline "`r$($spinner[$spinnerIndex]) $progressMsg"
        }

        $targetFile = $null
        $relPath = $file.Name # Default for error logging
        try {
            $relPath = $file.FullName.Substring($SourceDirectory.Length).TrimStart('\', '/')
            
            # Check exclusions
            $shouldExclude = $false
            foreach ($ex in $ExcludedSubdirectories) {
                $pattern = [regex]::Escape($ex)
                if ($file.FullName -match "\\$pattern\\") {
                    $shouldExclude = $true
                    break
                }
            }

            if ($shouldExclude) { continue }

            # Check root file inclusion
            if (-not $IncludeRootFiles -and -not $relPath.Contains('\')) {
                continue
            }

            # Construct destination path
            $targetFile = Join-Path $codeBackupPath $relPath
            $targetDir = Split-Path $targetFile -Parent

            if (-not (Test-Path $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }

            Copy-Item -Path $file.FullName -Destination $targetFile -Force
        }
        catch {
            $anyFileError = $true
            $errorMsg = $_.Exception.Message
            
            # Check for potential long path issue (MAX_PATH = 260)
            if ($targetFile -and $targetFile.Length -ge 260) {
                $errorMsg = "Path too long ($($targetFile.Length) chars). Windows limit is 260. Original Error: $errorMsg"
            }
            
            Write-BackupLog "ERROR copying file '$($file.FullName)': $errorMsg" -Level Error
            Write-SolutionLog "ERROR copying file '$($file.FullName)': $errorMsg" -Level Error
            # Print error on new line, then restore spinner prompt
            # Clear line first to ensure clean error display
            Write-Host "`r$(' ' * ($progressMsg.Length + 5))" -NoNewline
            Write-Host "`r[Error] Failed to copy $($relPath): $errorMsg" -ForegroundColor Red
            Write-Host -NoNewline "$($spinner[$spinnerIndex]) $progressMsg"
        }
    }

    # Overwrite the spinner line with the clean message (padded to ensure spinner chars are erased)
    Write-Host "`r$progressMsg - Completed.  "

    if (-not $anyFileError) {
        Write-BackupLog "$repoName Backup completed successfully."
        $backupSucceeded = $true
    } else {
        Write-BackupLog "Backup completed with errors (see above)." -Level Error
        # We leave $backupSucceeded as false so the script exits with 1 to indicate partial failure
    }
}
catch {
    Write-Host ""
    Write-SolutionLog $_.Exception.ToString() -Level Error

    if ($backupRoot -and (Test-Path $backupRoot)) {
        $errorPath = "$backupRoot - BACKUP ERROR"
        if (-not (Test-Path $errorPath)) {
            Rename-Item $backupRoot $errorPath -Force
        }
    }
}
finally {
    if ($backupSucceeded) {
        Write-Host "$repoName Backup successful" -ForegroundColor Green
    }
    else {
        Write-Host "One or more errors occurred while backing up $repoName - check logs in ReactiveBackup solution folder" -ForegroundColor Red
    }
}

if ($backupSucceeded) {
    exit 0
} else {
    exit 1
}
