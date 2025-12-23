# ReactiveBackup.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$backupSucceeded = $false
$backupRoot = $null

# -------------------------------
# Error-only logging (centralized)
# -------------------------------
function Write-ErrorLog {
    param ([string]$Message)

    $logDir = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }

    $logPath = Join-Path $logDir "$scriptName.errors.log"
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    Add-Content -Path $logPath -Value "[$timestamp] $Message"
}

try {
    # -------------------------------
    # Load configuration
    # -------------------------------
    $configPath = Join-Path $PSScriptRoot 'ReactiveBackup.config'
    $config     = (Get-Content $configPath -Raw -Encoding UTF8) | ConvertFrom-Json

    foreach ($required in @(
        'rootCodeDirectory',
        'backupRootDirectory',
        'includedSubdirectories',
        'timestampFormat',
        'includeRootFiles'
    )) {
        if (-not $config.PSObject.Properties.Name -contains $required) {
            throw "Missing required config value: $required"
        }
    }

    $rootCodeDirectory   = $config.rootCodeDirectory
    $backupRootDirectory = $config.backupRootDirectory
    $includedSubdirs     = $config.includedSubdirectories
    $includeRootFiles    = [bool]$config.includeRootFiles
    $timestampFormat     = $config.timestampFormat

    if (-not (Test-Path $rootCodeDirectory)) {
        throw "Root code directory not found: $rootCodeDirectory"
    }

    if (-not (Test-Path $backupRootDirectory)) {
        New-Item -ItemType Directory -Path $backupRootDirectory | Out-Null
    }

    # -------------------------------
    # Generate Windows-safe timestamp
    # -------------------------------
    $rawTimestamp = Get-Date -Format $timestampFormat
    $timestamp = $rawTimestamp `
        -replace ':', '.' `
        -replace '/', '-' `
        -replace '\\', '-'

    $backupRoot = Join-Path $backupRootDirectory $timestamp
    New-Item -ItemType Directory -Path $backupRoot | Out-Null

    # -------------------------------
    # Create backup subfolders
    # -------------------------------
    $codeBackupPath = Join-Path $backupRoot 'code'
    $dataBackupPath = Join-Path $backupRoot 'backup data'

    New-Item -ItemType Directory -Path $codeBackupPath | Out-Null
    New-Item -ItemType Directory -Path $dataBackupPath | Out-Null

    # -------------------------------
    # Backup log (per-backup)
    # -------------------------------
    $backupLogPath = Join-Path $dataBackupPath 'backup.log'
    Add-Content $backupLogPath "Backup started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    # -------------------------------
    # Copy root files (optional)
    # -------------------------------
    if ($includeRootFiles -eq $true) {
        Get-ChildItem $rootCodeDirectory -File |
            ForEach-Object {
                Copy-Item $_.FullName -Destination $codeBackupPath -Force
            }
    }

    # -------------------------------
    # Copy included subdirectories
    # -------------------------------
    foreach ($sub in $includedSubdirs) {
        $src = Join-Path $rootCodeDirectory $sub
        if (Test-Path $src) {
            $dest = Join-Path $codeBackupPath $sub
            Copy-Item $src -Destination $dest -Recurse -Force
        }
    }

    Add-Content $backupLogPath "Backup completed successfully."
    $backupSucceeded = $true
}
catch {
    Write-ErrorLog $_.Exception.ToString()

    if ($backupRoot -and (Test-Path $backupRoot)) {
        $errorPath = "$backupRoot - BACKUP ERROR"
        if (-not (Test-Path $errorPath)) {
            Rename-Item $backupRoot $errorPath -Force
        }
    }
}
finally {
    if ($backupSucceeded) {
        Write-Host "Backup successful" -ForegroundColor Green
    }
    else {
        Write-Host "One or more errors occurred during backup - check logs in ReactiveBackup solution folder" -ForegroundColor Red
    }
}
