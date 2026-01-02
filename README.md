# Intro

This solution allows the user to configure and run local code backups.

# Prerequisites

- As of right now the only requirement for the solution to run is that you have a Windows machine. (I tested it on a Windows 11 machine, but I suspect it would work on Windows 10).

# Configuration

All configuration is handled via `ReactiveBackup.config`, which lives at the root of the ReactiveBackup repo. Key settings:

- rootCodeDirectory: This is the drive letter path to the code folder you want to back up. Example: "C:\\dev\\github\\my-repo"
- rootBackupDirectory: This is the folder where each backups will be placed in a subfolder. Example: "C:\\dev\\github\\\_BACKUPS\\my-repo",
- backupLevel: Determines the scope of the backup.
  - "repo" (default): Treats `rootCodeDirectory` as a single repository.
  - "repo-parent": Treats `rootCodeDirectory` as a parent folder containing multiple repositories.
- includeRootFiles: indicates whether files directly in the root of your target folder will be backed up. Defaults to true.
- includedRepoSubfolders: this takes an array of 0 to n subfolders (of your rootCodeDirectory) that you would like to back up. Any subfolders not in this list will be ignored.
  > NOTE: specify only the folder names here (e.g. - ["src", "test"] and NOT ["C:\\dev\\github\\my-repo\\src", "C:\\dev\\github\\my-repo\\test"])
- excludedRepoSubfolders: Array of subfolders to exclude from the backup.
- includedRepoFolders: (Used when backupLevel is "repo-parent") Specific repository folder names to include.
- excludedRepoFolders: (Used when backupLevel is "repo-parent") Specific repository folder names to exclude.
- checkForCodeChangesIntervalMinutes: the time interval (in minutes) at which the solution will check whether it is time to make a backup.
  > NOTE: use the JSON number syntax of `15` and NOT "15"
- timestampFormat: Determines the timestamp format of how backup folders will be named. For example, `yyyyMMdd - hh:mm tt` would yield a backup folder named `20251223 03.14 PM`
- logLevel: Controls logging verbosity. Options are "info" or "error".

# Running a Backup (Ad Hoc)

You can run a backup manually by executing the `ReactiveBackup.ps1` script in PowerShell.

```powershell
.\ReactiveBackup.ps1
```

By default, it uses the settings in `ReactiveBackup.config`. You can also override settings using parameters:

```powershell
.\ReactiveBackup.ps1 -SourceDirectory "C:\MyCode" -DestinationDirectory "D:\Backups" -LogLevel "Info"
```

# Running Backups Conditionally

If you want to conditionally (i.e. - based on the `checkForCodeChangesIntervalMinutes` setting) run one or more backups, you can execute the `ReactiveBackup.EvaluateAndRun.ps1` script.

```powershell
.\ReactiveBackup.EvaluateAndRun.ps1
```

This script has 2 modes: `Run Once` and `Run Continuously`:

![Evaluation Script Choice](readme-images\eval-script-choice.png)

## Run Once

To run the script only once, enter `1` to have the script check the configured `checkForCodeChangesIntervalMinutes` and run a backup conditionally based on that value.

## Run Continuously

Enter `2` at the prompt to put the script in a mode that will run scheduled backups continuously based on the configuration (including `checkForCodeChangesIntervalMinutes`).

To stop this process, press enter `Ctrl+C` on your keyboard or click the `x` on the PowerShell window.

# Running Backups via Task Scheduler (Windows only)

For Windows users, you can use the `ReactiveBackup.Create-Edit-Scheduled-Task.ps1` script to create a scheduled task that will

1. Open PowerShell (Run as Administrator is recommended for Task Scheduler operations).
2. Run the script:
   ```powershell
   .\ReactiveBackup.Create-Edit-Scheduled-Task.ps1
   ```
3. Follow the prompts:
   - If the task does not exist, you will be asked if you want to create it.
   - If the task exists, you can choose to **Start**, **Stop**, or **Delete** it.

The scheduled task runs `ReactiveBackup.EvaluateAndRun.ps1` in the background at the configured interval defined in `checkForCodeChangesIntervalMinutes`. It checks if files have changed since the last backup before creating a new one.
