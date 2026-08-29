$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "ASSERTION FAILED: $Message. Expected '$Expected' but got '$Actual'."
    }
}

function Get-NormalizedRelativePath {
    param(
        [string]$Path,
        [string]$Root
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $rel = $full.Substring($rootFull.Length).TrimStart('\', '/')
    return $rel.Replace('\\', '/').Replace('\', '/')
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ReactiveBackup-change-detect-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $solutionDir = Join-Path $tempRoot 'solution'
    New-Item -ItemType Directory -Path $solutionDir -Force | Out-Null
    Copy-Item (Join-Path $root 'ReactiveBackup.ps1') $solutionDir
    Copy-Item (Join-Path $root 'ReactiveBackup.EvaluateAndRun.ps1') $solutionDir
    Copy-Item (Join-Path $root 'ReactiveBackup.Common.ps1') $solutionDir
    Copy-Item (Join-Path $root 'ReactiveBackup.config') $solutionDir

    $repoRoot = Join-Path $tempRoot 'repo'
    $backupRoot = Join-Path $tempRoot 'backups'
    $repoBackupRoot = Join-Path $backupRoot (Split-Path $repoRoot -Leaf)
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

    function Set-TestConfig {
        param(
            [string]$CodeRoot,
            [string]$BackupRoot,
            [string]$TimestampFormat = 'yyyyMMdd-HHmmss.fff'
        )

        $config = @{
            rootCodeDirectory = $CodeRoot
            rootBackupDirectory = $BackupRoot
            logLevel = 'error'
            backupLevel = 'repo'
            includeRootFiles = $true
            includedRepoFolders = @()
            excludedRepoFolders = @()
            includedRepoSubfolders = @()
            excludedRepoSubfolders = @('.git', 'node_modules', 'dist', 'logs')
            checkForCodeChangesIntervalMinutes = 15
            timestampFormat = $TimestampFormat
        }

        $configPath = Join-Path $solutionDir 'ReactiveBackup.config'
        $config | ConvertTo-Json -Depth 100 | Set-Content -Path $configPath -Encoding UTF8
    }

    function Invoke-RepoEvaluation {
        & (Join-Path $solutionDir 'ReactiveBackup.EvaluateAndRun.ps1') -ScheduledTask | Out-Null
    }

    function Get-BackupCount {
        if (-not (Test-Path $repoBackupRoot)) { return 0 }
        return @(Get-ChildItem -Path $repoBackupRoot -Directory -ErrorAction SilentlyContinue).Count
    }

    # helper: exclude .git/config, do not exclude .github/workflows
    Set-TestConfig -CodeRoot $repoRoot -BackupRoot $backupRoot
    $repoDotGitPath = Join-Path $repoRoot '.git'
    New-Item -ItemType Directory -Path $repoDotGitPath -Force | Out-Null
    $gitConfigPath = Join-Path $repoDotGitPath 'config'
    'git config text' | Set-Content -Path $gitConfigPath -Encoding UTF8
    $githubPath = Join-Path $repoRoot '.github'
    New-Item -ItemType Directory -Path (Join-Path $githubPath 'workflows') -Force | Out-Null
    'name: ci' | Set-Content -Path (Join-Path (Join-Path $githubPath 'workflows') 'ci.yml') -Encoding UTF8
    $tracked = @('tracked.txt', '.env', 'src/app.js', 'src/dist/bundle.js', '.github/workflows/ci.yml')
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'src\dist') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'app\node_modules\pkg') -Force | Out-Null
    'root file' | Set-Content -Path (Join-Path $repoRoot 'tracked.txt') -Encoding UTF8
    'app' | Set-Content -Path (Join-Path $repoRoot 'src/app.js') -Encoding UTF8
    'bundle' | Set-Content -Path (Join-Path $repoRoot 'src/dist/bundle.js') -Encoding UTF8
    'env' | Set-Content -Path (Join-Path $repoRoot '.env') -Encoding UTF8
    'ignore me' | Set-Content -Path (Join-Path $repoRoot 'app/node_modules/pkg/index.js') -Encoding UTF8

    # direct helper check using the same logic as the production code in the script under test
    $firstBackup = & (Join-Path $solutionDir 'ReactiveBackup.ps1') -SourceDirectory $repoRoot -DestinationDirectory $repoBackupRoot -LogLevel error -TimestampFormat 'yyyyMMdd-HHmmss.fff' 2>$null
    $initialCount = Get-BackupCount
    Assert-True ($initialCount -ge 1) 'first backup should be created'

    # unchanged repo should not create another backup
    $before = Get-BackupCount
    Invoke-RepoEvaluation
    $after = Get-BackupCount
    Assert-Equal $after $before 'unchanged repo should not create backup'

    # creating a file triggers backup
    'new file' | Set-Content -Path (Join-Path $repoRoot 'new-file.txt') -Encoding UTF8
    $before = Get-BackupCount
    Invoke-RepoEvaluation
    $after = Get-BackupCount
    Assert-True ($after -gt $before) 'creating a tracked file should trigger backup'

    # copy file preserving old timestamp should trigger backup
    $preservedFile = Join-Path $repoRoot 'old-mtime.txt'
    'old file' | Set-Content -Path $preservedFile -Encoding UTF8
    $copiedFile = Join-Path $repoRoot 'old-mtime-copy.txt'
    Copy-Item -Path $preservedFile -Destination $copiedFile -Force
    (Get-Item $copiedFile).LastWriteTime = (Get-Date).AddDays(-10)
    $before = Get-BackupCount
    Invoke-RepoEvaluation
    $after = Get-BackupCount
    Assert-True ($after -gt $before) 'copying file with preserved old mtime should trigger backup'

    # deleting a file triggers backup
    Remove-Item -Path $preservedFile -Force
    $before = Get-BackupCount
    Invoke-RepoEvaluation
    $after = Get-BackupCount
    Assert-True ($after -gt $before) 'deleting a file should trigger backup'

    # creating a Next.js-style file with [brackets] should copy and not retrigger
    $bracketDir = Join-Path $repoRoot 'src\[id]'
    [void][System.IO.Directory]::CreateDirectory($bracketDir)
    $bracketFile = Join-Path $bracketDir 'page.tsx'
    [System.IO.File]::WriteAllText($bracketFile, 'dynamic route')
    $before = Get-BackupCount
    Invoke-RepoEvaluation
    $after = Get-BackupCount
    Assert-True ($after -gt $before) 'creating a file whose path contains [brackets] should trigger backup'
    $latestWithBrackets = Get-ChildItem -Path $repoBackupRoot -Directory | Sort-Object CreationTimeUtc -Descending | Select-Object -First 1
    $copiedBracket = Join-Path $latestWithBrackets.FullName 'code\src\[id]\page.tsx'
    Assert-True ([System.IO.File]::Exists($copiedBracket)) 'backup should contain the file with [brackets] in its path'
    $before = Get-BackupCount
    Invoke-RepoEvaluation
    $after = Get-BackupCount
    Assert-Equal $after $before 'unchanged repo with [bracket] files should not create another backup'

    # modifying a file still triggers backup
    'updated content' | Set-Content -Path (Join-Path $repoRoot 'tracked.txt') -Encoding UTF8
    $before = Get-BackupCount
    Invoke-RepoEvaluation
    $after = Get-BackupCount
    Assert-True ($after -gt $before) 'editing a tracked file should trigger backup'

    # creating .env triggers backup
    '.env created' | Set-Content -Path (Join-Path $repoRoot '.env') -Encoding UTF8
    $before = Get-BackupCount
    Invoke-RepoEvaluation
    $after = Get-BackupCount
    Assert-True ($after -gt $before) 'creating .env should trigger backup'

    # changes under .git/node_modules do not trigger backup
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'node_modules') -Force | Out-Null
    'ignored' | Set-Content -Path (Join-Path $repoRoot 'node_modules\ignored.js') -Encoding UTF8
    $before = Get-BackupCount
    Invoke-RepoEvaluation
    $after = Get-BackupCount
    Assert-Equal $after $before 'changes under node_modules should not trigger backup'

    # logs (EvaluateAndRun output) should not trigger backup
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'logs') -Force | Out-Null
    'log line' | Set-Content -Path (Join-Path $repoRoot 'logs\ReactiveBackup.log') -Encoding UTF8
    $before = Get-BackupCount
    Invoke-RepoEvaluation
    $after = Get-BackupCount
    Assert-Equal $after $before 'changes under logs should not trigger backup'

    # .git and node_modules are not copied into backups
    $latestBackup = Get-ChildItem -Path $repoBackupRoot -Directory | Sort-Object CreationTimeUtc -Descending | Select-Object -First 1
    $copiedCodePath = Join-Path $latestBackup.FullName 'code'
    Assert-True (-not (Test-Path (Join-Path $copiedCodePath '.git'))) 'backup should omit .git'
    Assert-True (-not (Test-Path (Join-Path $copiedCodePath 'node_modules'))) 'backup should omit node_modules'
    Assert-True (Test-Path (Join-Path $copiedCodePath '.github\workflows\ci.yml')) '.github should still be backed up'

    Write-Host 'All change-detection tests passed.' -ForegroundColor Green
}
finally {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
