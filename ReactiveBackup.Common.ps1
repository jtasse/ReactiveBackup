# ReactiveBackup.Common.ps1
# Shared helpers. Dot-source from other scripts in this folder.
Set-StrictMode -Version Latest

function Test-IsUnixPlatform {
    return ([System.IO.Path]::DirectorySeparatorChar -eq '/')
}

function Get-ReactiveBackupLogLevel {
    param(
        $Config,
        [string]$Override
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.Trim().ToLowerInvariant()
    }

    if ($Config -and ($Config.PSObject.Properties.Name -contains 'logLevel') -and $Config.logLevel) {
        return ([string]$Config.logLevel).Trim().ToLowerInvariant()
    }

    return 'error'
}

function Write-ReactiveBackupLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Level = 'Info',
        [string]$Prefix = '',
        $Config,
        [string]$LogLevel
    )

    $current = Get-ReactiveBackupLogLevel -Config $Config -Override $LogLevel
    $levelNorm = $Level.ToLowerInvariant()
    $shouldLog = ($current -eq 'info') -or ($levelNorm -eq 'error')
    if (-not $shouldLog) {
        return
    }

    try {
        $solutionRoot = $null
        if ($PSCommandPath) {
            $solutionRoot = Split-Path -Parent $PSCommandPath
        }
        if ([string]::IsNullOrWhiteSpace($solutionRoot) -and $PSScriptRoot) {
            $solutionRoot = $PSScriptRoot
        }
        if ([string]::IsNullOrWhiteSpace($solutionRoot)) {
            $solutionRoot = (Get-Location).ProviderPath
        }

        $logDir = Join-Path $solutionRoot 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $logPath = Join-Path $logDir 'ReactiveBackup.log'
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = "[$timestamp] [$Level] $Prefix$Message" + [Environment]::NewLine
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::AppendAllText($logPath, $line, $utf8)
    }
    catch {
        Write-Host "WARNING: Failed to write log: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "[$Level] $Prefix$Message"
    }
}

function Write-ReactiveBackupFileLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::AppendAllText($Path, ($Message + [Environment]::NewLine), $utf8)
}

function Resolve-ReactiveBackupPath {
    param(
        [string]$Path,
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $Path = $Path.Trim().Trim('"')

    if ((Test-IsUnixPlatform) -and ($Path -match '^[A-Za-z]:[\\/]')) {
        throw "Path '$Path' looks like a Windows drive-letter path. On this OS use a Unix path (for example /home/you/code)."
    }

    if ($Path.StartsWith('~')) {
        $home = $env:HOME
        if ([string]::IsNullOrWhiteSpace($home)) {
            $home = $env:USERPROFILE
        }
        if ([string]::IsNullOrWhiteSpace($home)) {
            throw "Cannot expand '~' because HOME / USERPROFILE is not set."
        }

        $rest = $Path.Substring(1).TrimStart('\', '/')
        $Path = if ($rest) { Join-Path $home $rest } else { $home }
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        if ([string]::IsNullOrWhiteSpace($BasePath)) {
            $BasePath = (Get-Location).ProviderPath
        }
        $Path = Join-Path $BasePath $Path
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Test-ReactiveBackupInteractive {
    try {
        if ([Console]::IsInputRedirected) {
            return $false
        }
        if (-not [Environment]::UserInteractive) {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

function Get-PwshExecutablePath {
    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        return $command.Source
    }

    $bundled = Join-Path $PSHOME 'pwsh'
    if (Test-Path -LiteralPath $bundled) {
        return $bundled
    }

    $bundledExe = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $bundledExe) {
        return $bundledExe
    }

    return $null
}
