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

    $logDir = $null
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
        if (Test-IsUnixPlatform) {
            $helpPath = $null
            if ($logDir) { $helpPath = $logDir }
            Write-Host (Get-ReactiveBackupPermissionHelp -Path $helpPath) -ForegroundColor Yellow
        }
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

function Get-PowerShellHostPath {
    $pwsh = Get-PwshExecutablePath
    if ($pwsh) {
        return $pwsh
    }

    foreach ($name in @('powershell.exe', 'powershell')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source) {
            return $command.Source
        }
    }

    if ($env:WINDIR) {
        $systemPs = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $systemPs) {
            return $systemPs
        }
    }

    return $null
}

function Get-ReactiveBackupPlatform {
    if (-not (Test-IsUnixPlatform)) {
        return 'windows'
    }

    $macVar = Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue
    if ($macVar -and [bool]$macVar.Value) {
        return 'mac'
    }

    try {
        $uname = [string](& uname -s)
        if ($uname -eq 'Darwin') {
            return 'mac'
        }
    }
    catch {
    }

    return 'linux'
}

function Get-UnixUserId {
    if (-not (Test-IsUnixPlatform)) {
        return $null
    }

    try {
        $raw = & id -u
        if ([string]::IsNullOrWhiteSpace([string]$raw)) {
            return $null
        }
        return [int]$raw
    }
    catch {
        return $null
    }
}

function Get-UnixSessionUserName {
    if (-not [string]::IsNullOrWhiteSpace($env:SUDO_USER) -and $env:SUDO_USER -ne 'root') {
        return $env:SUDO_USER
    }
    if (-not [string]::IsNullOrWhiteSpace($env:PKEXEC_UID)) {
        try {
            $name = & id -nu $env:PKEXEC_UID
            if ($name -and $name -ne 'root') {
                return [string]$name
            }
        }
        catch {
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USER) -and $env:USER -ne 'root') {
        return $env:USER
    }
    return $null
}

function Get-ReactiveBackupPermissionHelp {
    param([string]$Path)

    $user = Get-UnixSessionUserName
    if ([string]::IsNullOrWhiteSpace($user)) {
        $user = 'YOUR_USER'
    }

    $uid = Get-UnixUserId
    $lines = @()
    if ($uid -eq 0) {
        $lines += "This process is running as root. Ubuntu user mounts such as /media/$user/... (USB, NTFS, exFAT) typically allow only the desktop user, not root."
        $lines += "Remove sudo/pkexec from the .desktop Exec line and run as $user."
    }
    else {
        $lines += "User '$user' cannot write to '$Path'. If you previously ran with sudo, root may own the files. Fix with:"
        $lines += "  sudo chown -R ${user}:${user} '$Path'"
    }

    return ($lines -join [Environment]::NewLine)
}

function Assert-ReactiveBackupWritable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$Purpose = 'path'
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $stream.Dispose()
            return
        }
        catch {
            $help = Get-ReactiveBackupPermissionHelp -Path $Path
            throw "Cannot write $Purpose at '$Path'. $($_.Exception.Message)$([Environment]::NewLine)$help"
        }
    }

    $existing = $Path
    while ($existing -and -not (Test-Path -LiteralPath $existing)) {
        $parent = Split-Path -Parent $existing
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $existing) {
            break
        }
        $existing = $parent
    }

    if (-not $existing -or -not (Test-Path -LiteralPath $existing)) {
        throw "Cannot write $Purpose at '$Path' because no parent directory exists."
    }

    $probe = Join-Path $existing ('.reactivebackup-write-test-' + [guid]::NewGuid().ToString('N'))
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($probe, 'ok', $utf8)
        [System.IO.File]::Delete($probe)
    }
    catch {
        $help = Get-ReactiveBackupPermissionHelp -Path $existing
        throw "Cannot write $Purpose at '$Path'. $($_.Exception.Message)$([Environment]::NewLine)$help"
    }
}

function Get-ReactiveBackupRelaunchArgumentList {
    param($BoundParameters)

    $list = @()
    if (-not $BoundParameters) {
        return $list
    }

    foreach ($key in $BoundParameters.Keys) {
        $val = $BoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) {
                $list += "-$key"
            }
            continue
        }

        $list += "-$key"
        if ($null -eq $val) {
            continue
        }

        if ($val -is [array]) {
            foreach ($item in $val) {
                $list += [string]$item
            }
        }
        else {
            $list += [string]$val
        }
    }

    return $list
}

function Invoke-ReactiveBackupRelaunchAsSessionUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        $BoundParameters
    )

    if (-not (Test-IsUnixPlatform)) {
        return $null
    }

    $uid = Get-UnixUserId
    if ($uid -ne 0) {
        return $null
    }

    $sudoUser = $env:SUDO_USER
    if ([string]::IsNullOrWhiteSpace($sudoUser) -or $sudoUser -eq 'root') {
        $sudoUser = Get-UnixSessionUserName
    }
    if ([string]::IsNullOrWhiteSpace($sudoUser) -or $sudoUser -eq 'root') {
        Write-Host "Running as root. Ubuntu mounts under /media/<user>/ usually deny root; run this without sudo." -ForegroundColor Yellow
        return $null
    }

    $pwsh = Get-PwshExecutablePath
    if (-not $pwsh) {
        $pwsh = (Get-Process -Id $PID).Path
    }

    Write-Host "Detected sudo. Re-launching as $sudoUser because root cannot write to user-mounted drives." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-File', $ScriptPath) + @(Get-ReactiveBackupRelaunchArgumentList -BoundParameters $BoundParameters)
    & sudo -u $sudoUser --preserve-env=DOTNET_SYSTEM_IO_DISABLEFILELOCKING -- $pwsh @argList
    return $LASTEXITCODE
}
