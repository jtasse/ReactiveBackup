# Table of Contents

- [What is it?](#what-is-it)
- [Rationale](#rationale)
- [Prerequisites](#prerequisites)
  - [Windows](#windows)
  - [MacOS](#macos)
  - [Linux](#linux)
- **[Configuration](#configuration)**
  - [Overriding the Default Config](#overriding-the-default-config)
  - [Syntax for drive letter paths](#syntax-for-drive-letter-paths)
  - [Settings](#settings)
- [Backup Output Structure](#backup-output-structure)
- [Logging](#logging)
- **[Usage](#usage)**
  - **[Getting Started](#getting-started)**
  - [Running a Backup Manually (Ad Hoc)](#running-a-backup-manually-ad-hoc)
    - [Supplying a Backup Message (OPTIONAL)](#supplying-a-backup-message-optional)
    - [Modifying Default Behavior](#modifying-default-behavior)
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

Configuration is handled via `ReactiveBackup.config` at the root of the repo.

## Overriding the Default Config

You can also create a `ReactiveBackup.actual.config` file in the same directory to override the configuration locally. This file replaces the default config entirely, so ensure all required keys are present.

> **Example use case**: you want to submit a pull request for this solution but would like to continue testing using your own configuration)

## Syntax for drive letter paths

For settings involving drive letter paths, you may use any of the following syntaxes:

| Syntax        | Example           |
| ------------- | ----------------- |
| Escaped       | `C:\\dev\\github` |
| Unescaped     | `C:\dev\github`   |
| Forward Slash | `C:/dev/github`   |

## Settings

| Setting                              | Description                                                                                                                                                                                                                                                                                                  |
| :----------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `rootCodeDirectory`                  | This is the drive letter path to the code folder you want to back up. Example: "C:\\dev\\github\\my-repo"                                                                                                                                                                                                    |
| `rootBackupDirectory`                | This is the folder where each backups will be placed in a subfolder. Example: "C:\\dev\\github\\\_BACKUPS\\my-repo"                                                                                                                                                                                          |
| `backupLevel`                        | Determines the scope of the backup.<br>• "repo" (default): Treats `rootCodeDirectory` as a single repository.<br>• "repo-parent": Treats `rootCodeDirectory` as a parent folder containing multiple repositories.                                                                                            |
| `includeRootFiles`                   | Indicates whether files directly in the root of your target folder will be backed up. Defaults to true.                                                                                                                                                                                                      |
| `includedRepoSubfolders`             | This takes an array of 0 to n subfolders (of your rootCodeDirectory) that you would like to back up. Any subfolders not in this list will be ignored.<br>> **NOTE**: specify only the folder names here (e.g. - ["src", "test"] and NOT ["C:\\dev\\github\\my-repo\\src", "C:\\dev\\github\\my-repo\\test"]) |
| `excludedRepoSubfolders`             | Array of subfolders to exclude from the backup. (Ignored if `includedRepoSubfolders` is populated).                                                                                                                                                                                                          |
| `includedRepoFolders`                | (Used when backupLevel is "repo-parent") Specific repository folder names to include.                                                                                                                                                                                                                        |
| `excludedRepoFolders`                | (Used when backupLevel is "repo-parent") Specific repository folder names to exclude.                                                                                                                                                                                                                        |
| `checkForCodeChangesIntervalMinutes` | The time interval (in minutes) at which the solution will check whether it is time to make a backup.<br>> **NOTE**: use the JSON number syntax of `15` and NOT "15"                                                                                                                                          |
| `timestampFormat`                    | Determines the timestamp format of how backup folders will be named. For example, `yyyyMMdd - hh:mm tt` would yield a backup folder named `20251223 03.14 PM`                                                                                                                                                |
| `logLevel`                           | Controls logging verbosity. Options are "info" or "error".                                                                                                                                                                                                                                                   |

# Backup Output Structure

When a backup runs, it creates a folder in your `rootBackupDirectory` named with the timestamp (and optional description). Inside that folder:

- `code`: Contains the backed-up source files.
- `backup data`: Contains metadata and logs specific to that backup operation.

# Logging

The solution generates logs (based on the `logLevel` setting in [configuration](#configuration)) in a `ReactiveBackup.log` file in the `logs` folder at the root of the ReactiveBackup solution directory.

# Usage

## Getting Started

1. **Download the Solution**: Clone the repository or download the source code to a local folder on your machine.
2. **Configure**: Open the `ReactiveBackup.config` file in a text editor.
   - Update `rootCodeDirectory` to point to the folder containing the code you want to back up.
   - Update `rootBackupDirectory` to point to the folder where you want backups to be stored.
   - (Optional) Adjust other settings like `backupLevel` or `checkForCodeChangesIntervalMinutes` as needed.
3. **Run a Test**: Open PowerShell, navigate to the solution folder, and run the manual backup script to ensure everything is working:
   ```powershell
   .\ReactiveBackup.ps1
   ```
4. **Verify**: Check your configured `rootBackupDirectory`. You should see a new folder with the current timestamp containing your code.

If something goes wrong, check the log within the `logs` folder within the `ReactiveBackup` directory for any errors.

## Running a Backup Manually (Ad Hoc)

You can run a backup manually by executing the `ReactiveBackup.ps1` script in PowerShell.

```powershell
.\ReactiveBackup.ps1
```

### Supplying a Backup Message (OPTIONAL)

If you would like the ad hoc backup folder to have a custom description, you can add one by using the `-m` or `--message` parameter.

For example, if you made a backup call to `.\ReactiveBackup.ps1` at 11:42AM on 01/09/2026 using the following syntax:

```
.\ReactiveBackup.ps1 -m "Here is my backup description"
```

...the result would be a backup folder with a name like:

`20260109 - 11.42 AM - Here is my backup description`

> **NOTE**: actual backup folder names may vary on account of timestamp configuration

### Modifying Default Behavior

By default, the script uses the settings in `ReactiveBackup.config`. You can also override these settings using parameters:

```powershell
.\ReactiveBackup.ps1 -SourceDirectory "C:\MyCode" -DestinationDirectory "D:\Backups" -LogLevel "Info"
```

### Specifying Repositories to Back Up (OPTIONAL - repo-parent mode only)

When using `repo-parent` backup mode, you can optionally specify which repositories to back up using the `-r` or `--repos` parameter. This is particularly useful when providing a backup message that is specific to one or more repositories.

#### Supported Syntax Options

| Use Case                   | Syntax                             | Example                                                     |
| -------------------------- | ---------------------------------- | ----------------------------------------------------------- |
| Single repository          | `-r <repo>`                        | `.\ReactiveBackup.ps1 -r jtt`                               |
| Multiple repos (clean)     | `-r <repo1>, <repo2>, ...`         | `.\ReactiveBackup.ps1 -r jtt, animated-logo`                |
| Repos with spaces in names | `-r <repo1>, "<repo with spaces>"` | `.\ReactiveBackup.ps1 -r jtt, "apple cinnamon"`             |
| Bracket syntax (flexible)  | `-r '[<repo1>, "<repo>"]'`         | `.\ReactiveBackup.ps1 -r '[jtt, "apple cinnamon"]'`         |
| Quoted list                | `-r '<repo1>, <repo2>, ...'`       | `.\ReactiveBackup.ps1 -r 'jtt, animated-logo'`              |
| With message               | `-r <repos> -m "<message>"`        | `.\ReactiveBackup.ps1 -r jtt, animated-logo -m "Feature X"` |

#### Recommendations

- **Best for most cases**: Use PowerShell array syntax without brackets
  ```powershell
  .\ReactiveBackup.ps1 -r jtt, animated-logo -m "Your message"
  ```
- **For repos with spaces**: Quote individual repo names

  ```powershell
  .\ReactiveBackup.ps1 -r jtt, "apple cinnamon", "user dashboard"
  ```

- **Alternative with bracket syntax**: Quote the entire value
  ```powershell
  .\ReactiveBackup.ps1 -r '[jtt, "apple cinnamon"]'
  ```

#### Behavior

- Only the specified repositories are backed up (config `includedRepoFolders` and `excludedRepoFolders` are ignored)
- Non-existent repositories are skipped with a warning message
- Repository names are case-sensitive and matched exactly against directory names

## Running Backups Conditionally

If you want to conditionally (i.e. - based on the `checkForCodeChangesIntervalMinutes` setting) run one or more backups, you can execute the `ReactiveBackup.EvaluateAndRun.ps1` script.

```powershell
.\ReactiveBackup.EvaluateAndRun.ps1
```

This script has 2 modes: `Run Once` and `Run Continuously`:

![Evaluation Script Choice](readme-images\eval-script-choice.png)

### Run Once

To run the script only once, enter `1` to have the script check the configured `checkForCodeChangesIntervalMinutes` and run a backup conditionally based on that value.

### Run Continuously

Enter `2` at the prompt to put the script in a mode that will run scheduled backups continuously based on the configuration (including `checkForCodeChangesIntervalMinutes`).

To stop this process, press enter `Ctrl+C` on your keyboard or click the `x` on the PowerShell window.

### Backing up via Task Scheduler (Windows only)

For Windows users, you can use the `ReactiveBackup.Create-Edit-Scheduled-Task.ps1` script to create a scheduled task.

#### Creating the Scheduled Task

1. Run PowerShell as an administrator and navigate to the folder containing the ReactiveBackup solution.
2. Run the script:
   ```powershell
   .\ReactiveBackup.Create-Edit-Scheduled-Task.ps1
   ```
3. Follow the prompts:
   - If the task does not exist, you will be asked if you want to create it.
   - If the task exists, you can choose to **Start**, **Stop**, or **Delete** it.

The scheduled task runs `ReactiveBackup.EvaluateAndRun.ps1` in the background at the configured interval defined in `checkForCodeChangesIntervalMinutes`. It checks if files have changed since the last backup before creating a new one.

# Reporting Issues

This is a vibe-coded solution. Although I have been running it pretty much continually since I created it, I fully expect there to be issues.

Accordingly, please add an item to the [issues](https://github.com/jtasse/ReactiveBackup/issues) page if you find a problem.
