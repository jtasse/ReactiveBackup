# ReactiveBackup.Common.ps1
# Shared helpers. Dot-source from other scripts in this folder.
Set-StrictMode -Version Latest

$script:ReactiveBackupCommonDirectory = $PSScriptRoot

function Test-IsUnixPlatform {
    return ([System.IO.Path]::DirectorySeparatorChar -eq '/')
}

if (Test-IsUnixPlatform) {
    try {
        [System.AppContext]::SetSwitch('System.IO.DisableFileLocking', $true)
    }
    catch {
    }
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

$script:ReactiveBackupChosenLogPath = $null
$script:ReactiveBackupLogFallbackNotified = $false

function Get-ReactiveBackupLogCandidates {
    param([string]$SolutionRoot)

    $paths = @()
    $paths += Join-Path (Join-Path $SolutionRoot 'logs') 'ReactiveBackup.log'

    $userHome = $env:HOME
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        $userHome = $env:USERPROFILE
    }
    if (-not [string]::IsNullOrWhiteSpace($userHome)) {
        $stateHome = $env:XDG_STATE_HOME
        if ([string]::IsNullOrWhiteSpace($stateHome)) {
            $stateHome = Join-Path $userHome '.local/state'
        }
        $paths += Join-Path (Join-Path $stateHome 'ReactiveBackup') 'ReactiveBackup.log'
    }

    return $paths
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

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Prefix$Message" + [Environment]::NewLine
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $preferred = @(Get-ReactiveBackupLogCandidates -SolutionRoot $solutionRoot)[0]
    $candidates = @()
    if ($script:ReactiveBackupChosenLogPath) {
        $candidates += $script:ReactiveBackupChosenLogPath
    }
    $candidates += @(Get-ReactiveBackupLogCandidates -SolutionRoot $solutionRoot)
    $candidates = @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    $preferred = $candidates[0]
    foreach ($logPath in $candidates) {
        try {
            $logDir = Split-Path -Parent $logPath
            if (-not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            [System.IO.File]::AppendAllText($logPath, $line, $utf8)
            if (-not $script:ReactiveBackupChosenLogPath) {
                $script:ReactiveBackupChosenLogPath = $logPath
            }
            if ($logPath -ne $preferred -and -not $script:ReactiveBackupLogFallbackNotified) {
                $script:ReactiveBackupLogFallbackNotified = $true
                Write-Host "Cannot write '$preferred'; logging to '$logPath' instead." -ForegroundColor Yellow
                Write-Host (Get-ReactiveBackupPermissionHelp -Path $preferred) -ForegroundColor Yellow
            }
            return
        }
        catch {
            continue
        }
    }

    Write-Host "WARNING: Failed to write log to any candidate path." -ForegroundColor Yellow
    Write-Host (Get-ReactiveBackupPermissionHelp -Path $preferred) -ForegroundColor Yellow
    Write-Host "[$Level] $Prefix$Message"
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
        $userHome = $env:HOME
        if ([string]::IsNullOrWhiteSpace($userHome)) {
            $userHome = $env:USERPROFILE
        }
        if ([string]::IsNullOrWhiteSpace($userHome)) {
            throw "Cannot expand '~' because HOME / USERPROFILE is not set."
        }

        $rest = $Path.Substring(1).TrimStart('\', '/')
        $Path = if ($rest) { Join-Path $userHome $rest } else { $userHome }
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

function Complete-ReactiveBackupScript {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Code,
        [switch]$Nested
    )

    $global:LASTEXITCODE = $Code

    # `exit` ends the whole pwsh process, which closes .desktop/.lnk windows
    # even when the shortcut uses -NoExit. Nested callers and interactive
    # terminals should just return so the host session can stay open.
    if ($Nested -or (Test-ReactiveBackupInteractive)) {
        return
    }

    exit $Code
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

function Get-UnixPrimaryGroupName {
    if (-not (Test-IsUnixPlatform)) {
        return $null
    }

    try {
        $name = [string](& id -gn)
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return $name.Trim()
        }
    }
    catch {
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
        $group = Get-UnixPrimaryGroupName
        $ownerSpec = if ($group) { "${user}:${group}" } else { $user }
        $lines += "User '$user' cannot write to '$Path'. If you previously ran with sudo, root may own the files. Fix with:"
        $lines += "  sudo chown -R $ownerSpec '$Path'"
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

function Copy-ReactiveBackupFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $destDir = [System.IO.Path]::GetDirectoryName($Destination)
    if ($destDir -and -not [System.IO.Directory]::Exists($destDir)) {
        [void][System.IO.Directory]::CreateDirectory($destDir)
    }

    [System.IO.File]::Copy($Source, $Destination, $true)
}

function Get-ReactiveBackupInventoryPath {
    param([string]$BackupDirectory)

    return (Join-Path (Join-Path $BackupDirectory 'backup data') 'source-inventory.txt')
}

function Write-ReactiveBackupInventory {
    param(
        [string]$BackupDirectory,
        [string[]]$RelativePaths
    )

    $path = Get-ReactiveBackupInventoryPath -BackupDirectory $BackupDirectory
    $dir = Split-Path -Parent $path
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }

    $lines = @($RelativePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($path, $lines, $utf8)
}

function Read-ReactiveBackupInventory {
    param([string]$BackupDirectory)

    $path = Get-ReactiveBackupInventoryPath -BackupDirectory $BackupDirectory
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)
    return @($lines | ForEach-Object { ($_ -replace '\\', '/').Trim('/') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Get-ReactiveBackupConfigString {
    param($Config, [string]$Name)

    if (-not $Config -or -not ($Config.PSObject.Properties.Name -contains $Name) -or $null -eq $Config.$Name) {
        return ''
    }

    return ([string]$Config.$Name).Trim()
}

function Get-ReactiveBackupConfigStringArray {
    param($Config, [string]$Name)

    if (-not $Config -or -not ($Config.PSObject.Properties.Name -contains $Name) -or $null -eq $Config.$Name) {
        return @()
    }

    return @($Config.$Name | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ReactiveBackupConfigBool {
    param($Config, [string]$Name, [bool]$Default = $false)

    if (-not $Config -or -not ($Config.PSObject.Properties.Name -contains $Name) -or $null -eq $Config.$Name) {
        return $Default
    }

    $val = $Config.$Name
    if ($val -is [bool]) {
        return $val
    }

    $text = ([string]$val).Trim().ToLowerInvariant()
    if ($text -in @('true', '1', 'yes')) {
        return $true
    }
    if ($text -in @('false', '0', 'no', '')) {
        return $false
    }

    return $Default
}

function Get-ReactiveBackupConfigInt {
    param($Config, [string]$Name, [int]$Default = 0)

    if (-not $Config -or -not ($Config.PSObject.Properties.Name -contains $Name) -or $null -eq $Config.$Name -or [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return $Default
    }

    try {
        return [int]$Config.$Name
    }
    catch {
        return $Default
    }
}

function Get-ReactiveBackupMachineName {
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        return $env:COMPUTERNAME
    }

    try {
        $name = [string](& hostname)
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return $name.Trim()
        }
    }
    catch {
    }

    return 'unknown-machine'
}

function Get-ReactiveBackupThresholdAlertStatePath {
    param([string]$SolutionRoot)

    return (Join-Path (Join-Path $SolutionRoot 'logs') 'threshold-alerts.json')
}

function Read-ReactiveBackupThresholdAlertState {
    param([string]$SolutionRoot)

    $path = Get-ReactiveBackupThresholdAlertStatePath -SolutionRoot $SolutionRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Write-ReactiveBackupThresholdAlertState {
    param(
        [string]$SolutionRoot,
        $State
    )

    $path = Get-ReactiveBackupThresholdAlertStatePath -SolutionRoot $SolutionRoot
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 6
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $json, $utf8)
}

function Remove-ReactiveBackupThresholdAlertState {
    param([string]$SolutionRoot)

    $path = Get-ReactiveBackupThresholdAlertStatePath -SolutionRoot $SolutionRoot
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-ReactiveBackupFolderSizeCacheSignature {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $dirs = @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue)
    $newest = $dirs | Sort-Object CreationTimeUtc -Descending | Select-Object -First 1
    $newestName = if ($newest) { $newest.Name } else { '' }
    return ('{0}|{1}' -f $dirs.Count, $newestName)
}

function Get-ReactiveBackupElapsedText {
    param([datetime]$StartedUtc)

    $seconds = [math]::Max(0, [int]([datetime]::UtcNow - $StartedUtc).TotalSeconds)
    $hours = [int][math]::Floor($seconds / 3600)
    $minutes = [int][math]::Floor(($seconds % 3600) / 60)
    $remain = $seconds % 60
    if ($hours -gt 0) {
        return ('{0}h {1}m {2}s' -f $hours, $minutes, $remain)
    }
    if ($minutes -gt 0) {
        return ('{0}m {1}s' -f $minutes, $remain)
    }
    return ('{0}s' -f $remain)
}

function Format-ReactiveBackupByteSize {
    param([int64]$Bytes)

    $gb = [math]::Round($Bytes / 1GB, 2)
    $mb = [math]::Round($Bytes / 1MB, 1)
    return ('{0} GB ({1} MB)' -f $gb, $mb)
}

function Get-ReactiveBackupFolderSizeBytes {
    param(
        [string]$Path,
        [string]$ProgressLabel = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [int64]0
    }

    $sum = [int64]0
    $count = 0
    $spinner = @('|', '/', '-', '\')
    $spinIdx = 0
    $lastSpin = [datetime]::MinValue
    $startedUtc = [datetime]::UtcNow
    if ($ProgressLabel) {
        Write-Host "`r$($spinner[0]) Measuring $ProgressLabel (0s)..." -NoNewline
    }
    try {
        $files = [System.IO.Directory]::EnumerateFiles($Path, '*', [System.IO.SearchOption]::AllDirectories)
        foreach ($file in $files) {
            try {
                $sum += (New-Object System.IO.FileInfo $file).Length
            }
            catch {
            }
            $count++
            $now = [datetime]::UtcNow
            if ($ProgressLabel -and ($lastSpin -eq [datetime]::MinValue -or ($now - $lastSpin).TotalMilliseconds -ge 200)) {
                $lastSpin = $now
                $spinIdx = ($spinIdx + 1) % 4
                $mb = [math]::Round($sum / 1MB, 0)
                $elapsed = Get-ReactiveBackupElapsedText -StartedUtc $startedUtc
                Write-Host ("`r{0} Measuring {1} ({2} files, {3} MB, {4})..." -f $spinner[$spinIdx], $ProgressLabel, $count, $mb, $elapsed) -NoNewline
            }
        }
    }
    catch {
        return [int64]0
    }

    return $sum
}

function Get-ReactiveBackupFolderSizeCached {
    param(
        $Dir,
        [hashtable]$SizeCache
    )

    $name = $Dir.Name
    $signature = Get-ReactiveBackupFolderSizeCacheSignature -Path $Dir.FullName
    $cached = $null
    if ($SizeCache -and $SizeCache.ContainsKey($name)) {
        $cached = $SizeCache[$name]
    }

    $fromCache = $false
    $size = [int64]0
    if ($cached -and [string]$cached.signature -eq $signature) {
        $size = [int64]$cached.bytes
        $fromCache = $true
    }
    else {
        $size = Get-ReactiveBackupFolderSizeBytes -Path $Dir.FullName -ProgressLabel $name
    }

    return [pscustomobject]@{
        Name      = $name
        Path      = $Dir.FullName
        signature = $signature
        bytes     = $size
        FromCache = $fromCache
    }
}

function Get-ReactiveBackupConfiguredBackupFolderNames {
    param(
        $Config,
        [string]$SolutionRoot = ''
    )

    $backupLevel = Get-ReactiveBackupConfigString -Config $Config -Name 'backupLevel'
    if ([string]::IsNullOrWhiteSpace($backupLevel)) {
        $backupLevel = 'repo'
    }

    $included = @(Get-ReactiveBackupConfigStringArray -Config $Config -Name 'includedRepoFolders')
    $excluded = @(Get-ReactiveBackupConfigStringArray -Config $Config -Name 'excludedRepoFolders')
    $codeRoot = Get-ReactiveBackupConfigString -Config $Config -Name 'rootCodeDirectory'
    $backupRoot = Get-ReactiveBackupConfigString -Config $Config -Name 'rootBackupDirectory'
    if ($SolutionRoot) {
        if ($codeRoot) {
            $codeRoot = Resolve-ReactiveBackupPath -Path $codeRoot -BasePath $SolutionRoot
        }
        if ($backupRoot) {
            $backupRoot = Resolve-ReactiveBackupPath -Path $backupRoot -BasePath $SolutionRoot
        }
    }

    if ($backupLevel -ne 'repo-parent') {
        if ([string]::IsNullOrWhiteSpace($codeRoot)) {
            return @()
        }
        return @(Split-Path -Path $codeRoot -Leaf)
    }

    if ($included.Count -gt 0) {
        return @($included)
    }

    $names = @()
    if ($codeRoot -and (Test-Path -LiteralPath $codeRoot)) {
        $backupLeaf = ''
        if ($backupRoot) {
            $backupLeaf = Split-Path -Path $backupRoot -Leaf
        }
        $names = @(Get-ChildItem -LiteralPath $codeRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $excluded -notcontains $_.Name -and $_.Name -ne $backupLeaf } |
            ForEach-Object { $_.Name })
    }

    return @($names)
}

function Invoke-ReactiveBackupWithConsoleSpinner {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Script,
        [object[]]$ArgumentList = @()
    )

    $ps = [PowerShell]::Create()
    try {
        [void]$ps.AddScript($Script.ToString())
        foreach ($argument in @($ArgumentList)) {
            [void]$ps.AddArgument($argument)
        }
        $handle = $ps.BeginInvoke()
        $spinner = @('|', '/', '-', '\')
        $spinIdx = 0
        $started = [datetime]::UtcNow
        while (-not $handle.IsCompleted) {
            $seconds = [int]([datetime]::UtcNow - $started).TotalSeconds
            Write-Host ("`r{0} {1} ({2}s)..." -f $spinner[$spinIdx], $Label, $seconds) -NoNewline
            $spinIdx = ($spinIdx + 1) % 4
            Start-Sleep -Milliseconds 200
        }
        $output = $ps.EndInvoke($handle)
        if ($ps.HadErrors -and $ps.Streams.Error.Count -gt 0) {
            throw $ps.Streams.Error[0].Exception
        }
        Write-Host ("`r{0}... Done.                    " -f $Label)
        if ($null -eq $output) {
            return $null
        }
        if ($output.Count -eq 1) {
            return $output[0]
        }
        return $output
    }
    finally {
        $ps.Dispose()
    }
}

function Get-ReactiveBackupSmtpStatus {
    param($Config)

    $hostName = Get-ReactiveBackupConfigString -Config $Config -Name 'smtpHost'
    $user = Get-ReactiveBackupConfigString -Config $Config -Name 'smtpUsername'
    $pass = (Get-ReactiveBackupConfigString -Config $Config -Name 'smtpPassword') -replace '\s', ''
    $to = Get-ReactiveBackupConfigString -Config $Config -Name 'alertEmail'
    $from = Get-ReactiveBackupConfigString -Config $Config -Name 'smtpFrom'

    $any = -not [string]::IsNullOrWhiteSpace($hostName) -or
        -not [string]::IsNullOrWhiteSpace($user) -or
        -not [string]::IsNullOrWhiteSpace($pass) -or
        -not [string]::IsNullOrWhiteSpace($to) -or
        -not [string]::IsNullOrWhiteSpace($from)

    $fromOrUser = if ($from) { $from } else { $user }
    $ready = -not [string]::IsNullOrWhiteSpace($hostName) -and
        -not [string]::IsNullOrWhiteSpace($user) -and
        -not [string]::IsNullOrWhiteSpace($pass) -and
        -not [string]::IsNullOrWhiteSpace($to) -and
        -not [string]::IsNullOrWhiteSpace($fromOrUser)

    if (-not $any) {
        return 'blank'
    }
    if (-not $ready) {
        return 'partial'
    }
    return 'ready'
}

function Get-ReactiveBackupThresholdFingerprint {
    param([string[]]$Names)

    return ((@($Names) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object) -join '|')
}

function Get-ReactiveBackupThresholdAlertDecision {
    param(
        [string[]]$ExceedingRepoNames,
        [int]$ThresholdMb,
        [int]$TotalThresholdMb = 0,
        [bool]$TotalExceeded = $false,
        $State,
        [datetime]$Now
    )

    $names = @($ExceedingRepoNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
    if ($TotalExceeded) {
        $names += '__TOTAL__'
        $names = @($names | Sort-Object -Unique)
    }
    $fingerprint = Get-ReactiveBackupThresholdFingerprint -Names $names
    $nowUtc = $Now.ToUniversalTime()

    if ($names.Count -eq 0) {
        return [pscustomobject]@{
            Send       = $false
            Step       = 0
            ClearState = $true
            State      = $null
        }
    }

    $reset = $false
    if ($null -eq $State) {
        $reset = $true
    }
    else {
        $previousThreshold = 0
        if ($State.PSObject.Properties.Name -contains 'thresholdMb') {
            $previousThreshold = [int]$State.thresholdMb
        }
        if ($previousThreshold -ne $ThresholdMb) {
            $reset = $true
        }

        $previousTotal = 0
        if ($State.PSObject.Properties.Name -contains 'totalThresholdMb') {
            $previousTotal = [int]$State.totalThresholdMb
        }
        if ($previousTotal -ne $TotalThresholdMb) {
            $reset = $true
        }

        $oldFingerprint = ''
        if ($State.PSObject.Properties.Name -contains 'fingerprint') {
            $oldFingerprint = [string]$State.fingerprint
        }
        $oldNames = @()
        if ($oldFingerprint) {
            $oldNames = @($oldFingerprint -split '\|' | Where-Object { $_ })
        }
        $added = @($names | Where-Object { $oldNames -notcontains $_ })
        if ($added.Count -gt 0) {
            $reset = $true
        }
    }

    $step = 0
    $firstSent = $null
    $sleeping = $false
    if (-not $reset -and $State) {
        if ($State.PSObject.Properties.Name -contains 'step') {
            $step = [int]$State.step
        }
        if ($State.PSObject.Properties.Name -contains 'sleeping') {
            $sleeping = [bool]$State.sleeping
        }
        if ($State.PSObject.Properties.Name -contains 'firstSentUtc' -and $State.firstSentUtc) {
            $firstSent = [datetime]$State.firstSentUtc
            if ($firstSent.Kind -eq [DateTimeKind]::Unspecified) {
                $firstSent = [datetime]::SpecifyKind($firstSent, [DateTimeKind]::Utc)
            }
            else {
                $firstSent = $firstSent.ToUniversalTime()
            }
        }
    }

    $send = $false
    $nextStep = $step
    if ($reset) {
        $send = $true
        $nextStep = 1
        $firstSent = $nowUtc
        $sleeping = $false
    }
    elseif ($sleeping -or $step -ge 3) {
        $send = $false
        $nextStep = 3
        $sleeping = $true
    }
    elseif ($step -eq 1) {
        if ($firstSent -and $nowUtc -ge $firstSent.AddDays(3)) {
            $send = $true
            $nextStep = 2
        }
    }
    elseif ($step -eq 2) {
        if ($firstSent -and $nowUtc -ge $firstSent.AddDays(7)) {
            $send = $true
            $nextStep = 3
            $sleeping = $true
        }
    }
    else {
        $send = $true
        $nextStep = 1
        $firstSent = $nowUtc
        $sleeping = $false
    }

    $newState = [pscustomobject]@{
        thresholdMb       = $ThresholdMb
        totalThresholdMb  = $TotalThresholdMb
        fingerprint       = $fingerprint
        step              = $nextStep
        firstSentUtc      = if ($firstSent) { $firstSent.ToString('o') } else { $null }
        sleeping          = $sleeping
    }

    return [pscustomobject]@{
        Send       = $send
        Step       = $nextStep
        ClearState = $false
        State      = $newState
    }
}

function New-ReactiveBackupThresholdAlertBody {
    param(
        [string]$MachineName,
        [int]$ThresholdMb,
        [int]$TotalThresholdMb = 0,
        [int]$Step,
        $ExceedingFolders,
        $TotalFolder = $null
    )

    $exceeding = @($ExceedingFolders)
    $hasRepos = $exceeding.Count -gt 0
    $hasTotal = $null -ne $TotalFolder

    $lines = @()
    $lines += 'Hello,'
    $lines += ''
    $lines += ('ReactiveBackup on {0} found backup sizes over your configured limit(s).' -f $MachineName)
    $lines += ''

    if ($hasRepos) {
        $thresholdGb = [math]::Round($ThresholdMb / 1024.0, 2)
        $lines += ('Configured repo folders over backupSizeThresholdMb of {0} MB ({1} GB):' -f $ThresholdMb, $thresholdGb)
        foreach ($folder in $exceeding) {
            $sizeMb = [math]::Round($folder.SizeBytes / 1MB, 1)
            $sizeGb = [math]::Round($folder.SizeBytes / 1GB, 2)
            $lines += ('* {0} - {1} MB ({2} GB) - {3}' -f $folder.Name, $sizeMb, $sizeGb, $folder.Path)
        }
        $lines += ''
    }

    if ($hasTotal) {
        $totalGb = [math]::Round($TotalThresholdMb / 1024.0, 2)
        $sizeMb = [math]::Round($TotalFolder.SizeBytes / 1MB, 1)
        $sizeGb = [math]::Round($TotalFolder.SizeBytes / 1GB, 2)
        $lines += ('Entire backup folder over totalBackupSizeThresholdMb of {0} MB ({1} GB):' -f $TotalThresholdMb, $totalGb)
        $lines += ('* {0} - {1} MB ({2} GB) - {3}' -f $TotalFolder.Name, $sizeMb, $sizeGb, $TotalFolder.Path)
        $lines += 'This total includes leftover backup folders that are not in your current include list.'
        $lines += ''
    }

    $lines += 'You can:'
    $lines += '* Exclude the repo(s) from backup (includedRepoFolders / excludedRepoFolders)'
    $lines += '* Delete old timestamp folders under those paths'
    $lines += '* Stop the scheduled task or cron job'
    $lines += '* Raise backupSizeThresholdMb or totalBackupSizeThresholdMb'
    $lines += '* Set sendBackupFolderThresholdExceededAlerts to false'
    $lines += ''
    if ($Step -le 1) {
        $lines += 'You will get two more reminders: one in 3 days, then a final one 4 days after that.'
        $lines += 'After the final reminder, these will not trigger another email unless they drop below the limit (or you change a threshold) and later go over again, or a different backup folder goes over the limit.'
    }
    elseif ($Step -eq 2) {
        $lines += 'This is reminder 2 of 3. You will get one more reminder in 4 days.'
    }
    else {
        $lines += 'This is the final reminder. You will not get another alert for these unless they are cleaned up or a threshold changes, or a new backup folder goes over the limit.'
    }

    return ($lines -join [Environment]::NewLine)
}

function Send-ReactiveBackupThresholdAlertEmail {
    param(
        $Config,
        [string]$Subject,
        [string]$Body
    )

    $hostName = Get-ReactiveBackupConfigString -Config $Config -Name 'smtpHost'
    $port = Get-ReactiveBackupConfigInt -Config $Config -Name 'smtpPort' -Default 587
    if ($port -le 0) {
        $port = 587
    }
    $user = Get-ReactiveBackupConfigString -Config $Config -Name 'smtpUsername'
    $pass = (Get-ReactiveBackupConfigString -Config $Config -Name 'smtpPassword') -replace '\s', ''
    $to = Get-ReactiveBackupConfigString -Config $Config -Name 'alertEmail'
    $from = Get-ReactiveBackupConfigString -Config $Config -Name 'smtpFrom'
    if ([string]::IsNullOrWhiteSpace($from)) {
        $from = $user
    }

    $client = $null
    $message = $null
    try {
        $client = New-Object System.Net.Mail.SmtpClient($hostName, $port)
        $client.EnableSsl = $true
        $client.Timeout = 30000
        $client.Credentials = New-Object System.Net.NetworkCredential($user, $pass)
        $message = New-Object System.Net.Mail.MailMessage
        $message.From = New-Object System.Net.Mail.MailAddress($from)
        $message.To.Add($to)
        $message.Subject = $Subject
        $message.Body = $Body
        $client.Send($message)
        return $true
    }
    finally {
        if ($message) {
            $message.Dispose()
        }
        if ($client) {
            $client.Dispose()
        }
    }
}

function Invoke-ReactiveBackupThresholdAlerts {
    param(
        $Config,
        [string]$BackupRoot,
        [string]$SolutionRoot,
        [datetime]$Now = [datetime]::UtcNow
    )

    $enabled = Get-ReactiveBackupConfigBool -Config $Config -Name 'sendBackupFolderThresholdExceededAlerts'
    if (-not $enabled) {
        return
    }

    $smtpStatus = Get-ReactiveBackupSmtpStatus -Config $Config
    if ($smtpStatus -eq 'blank') {
        Write-ReactiveBackupLog -Message 'sendBackupFolderThresholdExceededAlerts is true, but SMTP settings are empty. Skipping alerts.' -Level Error -Prefix '[ThresholdAlert] ' -Config $Config
        return
    }
    if ($smtpStatus -eq 'partial') {
        Write-ReactiveBackupLog -Message 'sendBackupFolderThresholdExceededAlerts is true, but SMTP settings are incomplete. Set smtpHost, smtpPort, smtpUsername, smtpPassword, and alertEmail (smtpFrom defaults to smtpUsername). Skipping alerts.' -Level Error -Prefix '[ThresholdAlert] ' -Config $Config
        return
    }

    $thresholdMb = Get-ReactiveBackupConfigInt -Config $Config -Name 'backupSizeThresholdMb'
    $totalThresholdMb = Get-ReactiveBackupConfigInt -Config $Config -Name 'totalBackupSizeThresholdMb'
    $includeUnconfigured = Get-ReactiveBackupConfigBool -Config $Config -Name 'includeUnconfiguredBackupFoldersInSizeAlerts'
    if ($thresholdMb -le 0 -and $totalThresholdMb -le 0) {
        Write-ReactiveBackupLog -Message 'sendBackupFolderThresholdExceededAlerts is true, but backupSizeThresholdMb and totalBackupSizeThresholdMb are missing or not greater than 0. Skipping alerts.' -Level Error -Prefix '[ThresholdAlert] ' -Config $Config
        return
    }

    if ([string]::IsNullOrWhiteSpace($BackupRoot) -or -not (Test-Path -LiteralPath $BackupRoot)) {
        return
    }

    $scanLeftovers = ($totalThresholdMb -gt 0) -and $includeUnconfigured

    $thresholdBytes = [int64]$thresholdMb * 1MB
    $totalThresholdBytes = [int64]$totalThresholdMb * 1MB
    $state = Read-ReactiveBackupThresholdAlertState -SolutionRoot $SolutionRoot
    $sizeCache = @{}
    if ($state -and ($state.PSObject.Properties.Name -contains 'folderSizeCache') -and $state.folderSizeCache) {
        foreach ($entry in @($state.folderSizeCache)) {
            if ($entry.Name -and $entry.signature) {
                $sizeCache[$entry.Name] = $entry
            }
        }
    }

    $configuredNames = @(Get-ReactiveBackupConfiguredBackupFolderNames -Config $Config -SolutionRoot $SolutionRoot)
    $configuredLookup = @{}
    foreach ($configuredName in $configuredNames) {
        $configuredLookup[$configuredName.ToLowerInvariant()] = $true
    }

    $allDirs = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue)
    $configuredDirs = @($allDirs | Where-Object { $configuredLookup.ContainsKey($_.Name.ToLowerInvariant()) })
    $otherDirs = @($allDirs | Where-Object { -not $configuredLookup.ContainsKey($_.Name.ToLowerInvariant()) })

    $measuredByName = @{}
    $cacheEntries = @()

    $configuredCount = @($configuredDirs).Count
    $leftoverCount = @($otherDirs).Count
    $dirCount = $configuredCount
    if ($scanLeftovers) {
        $dirCount += $leftoverCount
    }
    $dirIndex = 0

    Write-Host ""
    Write-Host ("Size alerts: checking {0} configured backup folder(s) first." -f $configuredCount) -ForegroundColor Cyan
    if ($configuredCount -eq 0) {
        Write-Host "  No configured backup folders found under the backup directory." -ForegroundColor Gray
    }
    foreach ($dir in $configuredDirs) {
        $dirIndex++
        $folderStarted = [datetime]::UtcNow
        Write-Host ("  [{0}/{1}] Configured: {2}" -f $dirIndex, $dirCount, $dir.Name) -ForegroundColor Gray
        $measured = Get-ReactiveBackupFolderSizeCached -Dir $dir -SizeCache $sizeCache
        if (-not $measured.FromCache) {
            Write-Host ""
        }
        $elapsed = Get-ReactiveBackupElapsedText -StartedUtc $folderStarted
        $cacheNote = if ($measured.FromCache) { ' (cached)' } else { '' }
        Write-Host ("  [{0}/{1}] Configured: {2} - {3}{4} [{5}]" -f $dirIndex, $dirCount, $dir.Name, (Format-ReactiveBackupByteSize -Bytes $measured.bytes), $cacheNote, $elapsed)
        $measuredByName[$dir.Name] = $measured
        $cacheEntries += [pscustomobject]@{
            Name      = $measured.Name
            signature = $measured.signature
            bytes     = $measured.bytes
        }
    }
    Write-Host "Size alerts: configured folders done." -ForegroundColor Green

    if ($scanLeftovers -and $leftoverCount -gt 0) {
        Write-Host ("Size alerts: checking {0} leftover backup folder(s) for total size. This can take a long time; a spinner means it is still working." -f $leftoverCount) -ForegroundColor Cyan
        foreach ($dir in $otherDirs) {
            $dirIndex++
            $folderStarted = [datetime]::UtcNow
            Write-Host ("  [{0}/{1}] Leftover: {2}" -f $dirIndex, $dirCount, $dir.Name) -ForegroundColor Gray
            $measured = Get-ReactiveBackupFolderSizeCached -Dir $dir -SizeCache $sizeCache
            if (-not $measured.FromCache) {
                Write-Host ""
            }
            $elapsed = Get-ReactiveBackupElapsedText -StartedUtc $folderStarted
            $cacheNote = if ($measured.FromCache) { ' (cached)' } else { '' }
            Write-Host ("  [{0}/{1}] Leftover: {2} - {3}{4} [{5}]" -f $dirIndex, $dirCount, $dir.Name, (Format-ReactiveBackupByteSize -Bytes $measured.bytes), $cacheNote, $elapsed)
            $measuredByName[$dir.Name] = $measured
            $cacheEntries += [pscustomobject]@{
                Name      = $measured.Name
                signature = $measured.signature
                bytes     = $measured.bytes
            }
        }
        Write-Host "Size alerts: leftover folders done." -ForegroundColor Green
    }
    elseif ($totalThresholdMb -gt 0 -and -not $includeUnconfigured) {
        Write-Host "Size alerts: skipping leftover backup folders (includeUnconfiguredBackupFoldersInSizeAlerts is false). Set it to true after testing to scan the rest of the backup directory." -ForegroundColor Yellow
        Write-ReactiveBackupLog -Message 'Skipping leftover backup folders because includeUnconfiguredBackupFoldersInSizeAlerts is false.' -Level Info -Prefix '[ThresholdAlert] ' -Config $Config
    }
    elseif ($leftoverCount -gt 0 -and $totalThresholdMb -le 0) {
        Write-Host "Size alerts: skipping leftover backup folders (totalBackupSizeThresholdMb is 0)." -ForegroundColor Gray
    }

    foreach ($cachedName in @($sizeCache.Keys)) {
        if (-not ($cacheEntries | Where-Object { $_.Name -eq $cachedName })) {
            $cacheEntries += $sizeCache[$cachedName]
        }
    }

    $exceeding = @()
    if ($thresholdMb -gt 0) {
        foreach ($dir in $configuredDirs) {
            $measured = $measuredByName[$dir.Name]
            if ($measured -and $measured.bytes -ge $thresholdBytes) {
                $exceeding += [pscustomobject]@{
                    Name      = $dir.Name
                    Path      = $dir.FullName
                    SizeBytes = $measured.bytes
                }
            }
        }
    }

    $totalBytes = [int64]0
    $totalExceeded = $false
    $totalFolder = $null
    if ($scanLeftovers) {
        foreach ($measured in $measuredByName.Values) {
            $totalBytes += [int64]$measured.bytes
        }
        if ($totalBytes -ge $totalThresholdBytes) {
            $totalExceeded = $true
            $totalFolder = [pscustomobject]@{
                Name      = (Split-Path -Path $BackupRoot -Leaf)
                Path      = $BackupRoot
                SizeBytes = $totalBytes
            }
        }
    }

    $names = @($exceeding | ForEach-Object { $_.Name })
    $decision = Get-ReactiveBackupThresholdAlertDecision -ExceedingRepoNames $names -ThresholdMb $thresholdMb -TotalThresholdMb $totalThresholdMb -TotalExceeded $totalExceeded -State $state -Now $Now

    $nextState = $decision.State
    if ($decision.ClearState -or -not $nextState) {
        $nextState = [pscustomobject]@{
            thresholdMb      = $thresholdMb
            totalThresholdMb = $totalThresholdMb
            fingerprint      = ''
            step             = 0
            sleeping         = $false
        }
    }
    $nextState | Add-Member -MemberType NoteProperty -Name 'folderSizeCache' -Value @($cacheEntries) -Force

    if ($decision.ClearState) {
        Write-ReactiveBackupThresholdAlertState -SolutionRoot $SolutionRoot -State $nextState
        return
    }

    if (-not $decision.Send) {
        Write-ReactiveBackupThresholdAlertState -SolutionRoot $SolutionRoot -State $nextState
        return
    }

    $machine = Get-ReactiveBackupMachineName
    $subject = "Backup size threshold exceeded on $machine"
    $body = New-ReactiveBackupThresholdAlertBody -MachineName $machine -ThresholdMb $thresholdMb -TotalThresholdMb $totalThresholdMb -Step $decision.Step -ExceedingFolders $exceeding -TotalFolder $totalFolder

    try {
        $commonDir = $script:ReactiveBackupCommonDirectory
        $sent = Invoke-ReactiveBackupWithConsoleSpinner -Label 'Sending threshold alert email' -Script {
            param($CommonDir, $Cfg, $Subj, $Bod)
            . (Join-Path $CommonDir 'ReactiveBackup.Common.ps1')
            Send-ReactiveBackupThresholdAlertEmail -Config $Cfg -Subject $Subj -Body $Bod
        } -ArgumentList @($commonDir, $Config, $subject, $body)
        if ($sent) {
            Write-ReactiveBackupLog -Message "Sent threshold alert (reminder $($decision.Step) of 3) for: $($names -join ', ')" -Level Info -Prefix '[ThresholdAlert] ' -Config $Config
            Write-ReactiveBackupThresholdAlertState -SolutionRoot $SolutionRoot -State $nextState
        }
    }
    catch {
        Write-Host ""
        Write-ReactiveBackupLog -Message "Failed to send threshold alert email: $($_.Exception.Message)" -Level Error -Prefix '[ThresholdAlert] ' -Config $Config
    }
}
