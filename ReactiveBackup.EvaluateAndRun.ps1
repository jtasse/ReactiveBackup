param([switch]$ScheduledTask, [switch]$Once)

# ReactiveBackup.EvaluateAndRun.ps1
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
        [string]$Level = "Info"
    )

    $prefix = if ($ScheduledTask) { "[ScheduledTask] " } else { "" }
    $configForLog = $null
    $configVar = Get-Variable -Name config -ErrorAction SilentlyContinue
    if ($configVar) { $configForLog = $configVar.Value }
    Write-ReactiveBackupLog -Message $Message -Level $Level -Prefix $prefix -Config $configForLog
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

    return ($dirs | Sort-Object CreationTimeUtc -Descending | Select-Object -First 1)
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

    $backupDirectory = Split-Path -Parent $BackupRoot
    $manifestSet = Read-ReactiveBackupInventory -BackupDirectory $backupDirectory
    if ($null -ne $manifestSet) {
        $backupSet = @($manifestSet)
    }
    elseif (Test-Path -LiteralPath $BackupRoot) {
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
    $configSource = 'ReactiveBackup.config'

    $actualConfigPath = Join-Path $PSScriptRoot 'ReactiveBackup.actual.config'
    if (Test-Path $actualConfigPath) {
        try {
            $actualConfig = Get-JsonConfig -Path $actualConfigPath
        }
        catch {
            throw "ReactiveBackup.actual.config is not valid JSON. Quote every name in arrays (for example [""jtt"", ""repo""]). $($_.Exception.Message)"
        }
        try {
            if (-not $actualConfig.rootCodeDirectory -or -not $actualConfig.rootBackupDirectory) {
                throw "Missing required keys: rootCodeDirectory or rootBackupDirectory"
            }
            $config = $actualConfig
            $configSource = 'ReactiveBackup.actual.config'

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
    $logLevel            = Get-ReactiveBackupLogLevel -Config $config
    $backupLevel         = $config.backupLevel
    $includeRootFiles    = $config.includeRootFiles
    $includedRepoFolders = $config.includedRepoFolders
    $excludedRepoFolders = $config.excludedRepoFolders
    $includedRepoSubfolders = $config.includedRepoSubfolders
    $excludedRepoSubfolders = $config.excludedRepoSubfolders
    $timestampFormat     = $config.timestampFormat

    # Resolve paths relative to the solution directory (not the process CWD).
    # .desktop launchers often start with $HOME or / as the working directory.
    $rootCodeDirectory = Resolve-ReactiveBackupPath -Path $rootCodeDirectory -BasePath $PSScriptRoot
    $rootBackupDirectory = Resolve-ReactiveBackupPath -Path $rootBackupDirectory -BasePath $PSScriptRoot

    if (-not (Test-Path -LiteralPath $rootCodeDirectory)) {
        throw "Source directory not found: $rootCodeDirectory"
    }

    Assert-ReactiveBackupWritable -Path $rootBackupDirectory -Purpose 'backup destination'

    # Ensure the backup directory name is always excluded to prevent recursion
    $backupDirName = Split-Path $rootBackupDirectory -Leaf
    if ($backupDirName -and $excludedRepoSubfolders -notcontains $backupDirName) {
        $excludedRepoSubfolders += $backupDirName
    }

    # Ensure config object has logLevel for Write-Log to use
    if (-not ($config.PSObject.Properties.Name -contains 'logLevel')) {
        $config | Add-Member -MemberType NoteProperty -Name 'logLevel' -Value $logLevel
    }

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

    if (-not $reposToCheck -or @($reposToCheck).Count -eq 0) {
        Write-Log "No repositories found to check under $rootCodeDirectory" -Level Error
        Write-Host "No repositories found to check under $rootCodeDirectory" -ForegroundColor Yellow
        Write-Host ""
    }
    else {
        $repoNames = @($reposToCheck | ForEach-Object { $_.Name })
        Write-Log "Using $configSource (backupLevel=$backupLevel). Repositories: $($repoNames -join ', ')"
        Write-Host "Using $configSource. Repositories: $($repoNames -join ', ')" -ForegroundColor Gray
        Write-Host ""
    }

    foreach ($repo in $reposToCheck) {
        try {
        $repoName = $repo.Name
        $repoPath = $repo.FullName
        
        $normRepo      = $repoPath.TrimEnd('\', '/')
        $normBackup    = $rootBackupDirectory.TrimEnd('\', '/')
        $backupDirName = Split-Path $normBackup -Leaf

        Write-Log "Processing repository: $repoName";

        if ($normRepo -eq $normBackup -or $repo.Name -eq $backupDirName) {
            Write-Log "Skipping backup directory: $repoName"
            Write-Host "Skipping backup directory: $repoName" -ForegroundColor Gray
            continue
        }

        $repoBackupPath = Join-Path $rootBackupDirectory $repoName

        if (-not (Test-Path $repoBackupPath)) {
            New-Item -ItemType Directory -Path $repoBackupPath -Force | Out-Null
        }

        Write-Log "Checking repo: $repoName"
        Write-Host "Checking repo: " -NoNewline
        Write-Host $repoName -ForegroundColor Cyan -NoNewline
        Write-Host "... " -NoNewline

        $lastBackupDirectory = Get-LastBackupDirectory -BackupRoot $repoBackupPath
        $lastBackupTime = if ($lastBackupDirectory) { $lastBackupDirectory.CreationTimeUtc } else { $null }
        
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
                Write-Host "Repository has no tracked files; deletion detected. Backup required." -ForegroundColor Yellow
                $shouldBackup = $true
            } else {
                Write-Log "  No tracked files found in $repoName and no prior backup exists."
                Write-Host "No tracked files found in $repoName." -ForegroundColor Gray
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
                Write-Host "Inventory changed (created or deleted file). Backup required." -ForegroundColor Yellow
                $shouldBackup = $true
            }
        }

        if (-not $shouldBackup) {
            Write-Log "  No changes detected."
            Write-Host "No changes detected." -ForegroundColor Gray
        }

        if ($shouldBackup) {
            Write-Host "Running backup for $repoName..." -ForegroundColor Cyan
            & (Join-Path $PSScriptRoot 'ReactiveBackup.ps1') -SourceDirectory $repoPath -DestinationDirectory $repoBackupPath -IncludedRepoSubfolders $includedRepoSubfolders -ExcludedRepoSubfolders $excludedRepoSubfolders -IncludeRootFiles $includeRootFiles -TimestampFormat $timestampFormat -LogLevel $logLevel | Out-Null
            $backupExitCode = $LASTEXITCODE
            if ($null -eq $backupExitCode) {
                $backupExitCode = if ($?) { 0 } else { 1 }
            }
            if ($backupExitCode -eq 0) {
                Write-Log "  $repoName backup successful."
            } else {
                Write-Log "  $repoName backup failed." -Level Error
            }
        }
        }
        finally {
            Write-Host ""
        }
    }

    return $config.checkForCodeChangesIntervalMinutes
}

if ($ScheduledTask) {
    try {
        Invoke-BackupCycle | Out-Null
    }
    catch {
        Write-Log $_.Exception.ToString() -Level Error
        throw
    }
} elseif ($Once) {
    Invoke-BackupCycle | Out-Null
} elseif ($MyInvocation.InvocationName -ne '.') {
    $interactive = Test-ReactiveBackupInteractive
    if (-not $interactive) {
        Write-Host "No interactive terminal detected; running once." -ForegroundColor Yellow
        Write-Host ""
        Invoke-BackupCycle | Out-Null
    } else {
        Write-Host "Reactive Backup Evaluation Script" -ForegroundColor Cyan
        Write-Host "--------------------------"
        Write-Host "1. Run Once"
        Write-Host "2. Run Continuously"
        
        try {
            $selection = Read-Host "Select an option (1-2)"
        }
        catch {
            Write-Host "Input is not available; running once." -ForegroundColor Yellow
            $selection = '1'
        }

        Write-Host ""
        
        if ($selection -eq '2') {
            Write-Host "Starting continuous backup mode. Press Ctrl+C to stop." -ForegroundColor Yellow
            Write-Host ""
            $interval = 15
            while ($true) {
                $runInterval = Invoke-BackupCycle
                if ($runInterval) { $interval = $runInterval }
                
                Write-Host "Current time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
                Write-Host "Sleeping for $interval minutes..." -ForegroundColor Gray
                Write-Host ""
                Start-Sleep -Seconds ($interval * 60)
            }
        } else {
            Invoke-BackupCycle | Out-Null
        }
    }
}