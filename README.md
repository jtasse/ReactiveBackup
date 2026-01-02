# Table of Contents

- [What is it?](#what-is-it)
- [Rationale](#rationale)
- [Prerequisites](#prerequisites)
  - [Windows](#windows)
  - [MacOS](#macos)
  - [Linux](#linux)
- [Configuration](#configuration)
- [Backup Output Structure](#backup-output-structure)
- [Logging](#logging)
- [Running a Backup Manually (Ad Hoc)](#running-a-backup-manually-ad-hoc)
- [Running Backups Conditionally](#running-backups-conditionally)
  - [Run Once](#run-once)
  - [Run Continuously](#run-continuously)
  - [Running Backups via Task Scheduler (Windows only)](#running-backups-via-task-scheduler-windows-only)
- [Reporting Issues](#reporting-issues)

# What Is It?

This solution allows the user to configure and run local code backups.

# Rationale

I can hear it already: "You're using Git. Why not just commit and push your changes or stash them?". This is a totally valid question! I would say that if you're comfortable with the amount of redundancy Git provides on its own, then you don't need this solution.

However, if you're like me and you still get into some gnarly situations despite Git's feature set, then it might give you some of that warm and fuzzy comfort. Here are a few use cases where you might find this solution useful:

- You want to push "meaty" commits that contain a full feature, bugfix, etc. rather than lots of little commits (see also: squashing commits is a pain :p)
- You're using multiple coding assistants (e.g. - Gemini, Claude, etc.) and are afraid of them fighting with each other
- You don't know what you don't know, and just want the comfort of being able to manually revert files if something gets borked

# Prerequisites

All solution functionality is fully supported in Windows.

For MacOs and Linux you can use everything except Windows Scheduled Tasks. For these users, if you want to automate backups, you can either use the [Run Continuously](#run-continuously) functionality in the `ReactiveBackup.EvaluateAndRun.ps1` script; or follow the instructions in the [MacOS](#macos) and [Linux](#linux) sections below.

## Windows

- If you have a Windows 10 or 11 machine, you shouldn't need to do anything before using the solution.

> **NOTE**: I tested it on a Windows 11 machine, but I am not aware of any reason it wouldn't work on Windows 10.

## MacOS

1. **Install PowerShell**: You will need to install PowerShell for MacOS. The easiest way is via Homebrew:
   ```bash
   brew install powershell/tap/powershell
   ```
2. **Running Scripts**: Execute the scripts using `pwsh`.

   ```bash
   pwsh ./ReactiveBackup.ps1
   ```

   > NOTE: Ensure your `ReactiveBackup.config` uses valid MacOS paths (e.g., `/Users/username/code`).

3. **Scheduling**: The scheduled task script provided is for Windows. On MacOS, use `cron`.
   ```bash
   crontab -e
   # Add a line to run every 15 minutes (example)
   */15 * * * * pwsh /path/to/ReactiveBackup.EvaluateAndRun.ps1 -ScheduledTask
   ```

## Linux

1. **Install PowerShell**: Follow the instructions for your specific distribution (e.g., Ubuntu, Alpine, etc.) from the Microsoft documentation.
2. **Running Scripts**: Execute the scripts using `pwsh`.

   ```bash
   pwsh ./ReactiveBackup.ps1
   ```

   > NOTE: Ensure your `ReactiveBackup.config` uses valid Linux paths (e.g., `/home/username/code`).

3. **Scheduling**: The scheduled task script provided is for Windows. On Linux, use `cron`.
   ```bash
   crontab -e
   # Add a line to run every 15 minutes (example)
   */15 * * * * pwsh /path/to/ReactiveBackup.EvaluateAndRun.ps1 -ScheduledTask
   ```

# Configuration

Configuration is handled via `ReactiveBackup.config` at the root of the repo. You can also create a `ReactiveBackup.actual.config` file in the same directory to override the configuration locally (note: this file replaces the default config entirely, so ensure all required keys are present). Key settings:

| Setting                              | Description                                                                                                                                                                                                                                                                                                  |
| :----------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `rootCodeDirectory`                  | This is the drive letter path to the code folder you want to back up. Example: "C:\\dev\\github\\my-repo"                                                                                                                                                                                                    |
| `rootBackupDirectory`                | This is the folder where each backups will be placed in a subfolder. Example: "C:\\dev\\github\\\_BACKUPS\\my-repo"                                                                                                                                                                                          |
| `backupLevel`                        | Determines the scope of the backup.<br>• "repo" (default): Treats `rootCodeDirectory` as a single repository.<br>• "repo-parent": Treats `rootCodeDirectory` as a parent folder containing multiple repositories.                                                                                            |
| `includeRootFiles`                   | Indicates whether files directly in the root of your target folder will be backed up. Defaults to true.                                                                                                                                                                                                      |
| `includedRepoSubfolders`             | This takes an array of 0 to n subfolders (of your rootCodeDirectory) that you would like to back up. Any subfolders not in this list will be ignored.<br>> **NOTE**: specify only the folder names here (e.g. - ["src", "test"] and NOT ["C:\\dev\\github\\my-repo\\src", "C:\\dev\\github\\my-repo\\test"]) |
| `excludedRepoSubfolders`             | Array of subfolders to exclude from the backup.                                                                                                                                                                                                                                                              |
| `includedRepoFolders`                | (Used when backupLevel is "repo-parent") Specific repository folder names to include.                                                                                                                                                                                                                        |
| `excludedRepoFolders`                | (Used when backupLevel is "repo-parent") Specific repository folder names to exclude.                                                                                                                                                                                                                        |
| `checkForCodeChangesIntervalMinutes` | The time interval (in minutes) at which the solution will check whether it is time to make a backup.<br>> **NOTE**: use the JSON number syntax of `15` and NOT "15"                                                                                                                                          |
| `timestampFormat`                    | Determines the timestamp format of how backup folders will be named. For example, `yyyyMMdd - hh:mm tt` would yield a backup folder named `20251223 03.14 PM`                                                                                                                                                |
| `logLevel`                           | Controls logging verbosity. Options are "info" or "error".                                                                                                                                                                                                                                                   |

# Backup Output Structure

When a backup runs, it creates a folder in your `rootBackupDirectory` named with the timestamp. Inside that folder:

- `code`: Contains the backed-up source files.
- `backup data`: Contains metadata and logs specific to that backup operation.

# Logging

The solution generates logs (based on the `logLevel` setting in [configuration](#configuration)) in a `ReactiveBackup.log` file in the `logs` folder at the root of the ReactiveBackup solution directory.

# Running a Backup Manually (Ad Hoc)

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

## Running Backups via Task Scheduler (Windows only)

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

> **NOTE**: when Task Scheduler runs the script, a PowerShell window will appear, execute the script, and then disappear. While this can be annoying, it does not seem to pull mouse/keyboard focus, which would be _super_ annoying :)

# Reporting Issues

This is a vibe-coded solution. Although I have been running it pretty much continually since I created it, I fully expect there to be issues.

Accordingly, please add an item to the [issues](https://github.com/jtasse/ReactiveBackup/issues) page if you find a problem.
