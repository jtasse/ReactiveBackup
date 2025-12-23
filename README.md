# Intro
This solution allows the user to configure and run local code backups.

# Prerequisites
* As of right now the only requirement for the solution to run is that you have a Windows machine. (I tested it on a Windows 11 machine, but I suspect it would work on Windows 10).

# Configuration
All configuration is handled via `ReactiveBackup.config`, which lives at the root of the ReactiveBackup repo. Key settings:
* rootCodeDirectory: This is the drive letter path to the code folder you want to back up. Example: "C:\\dev\\github\\my-repo"
* includeRootFiles: indicates whether files directly in the root of your target folder will be backed up. Defaults to true.
* includedSubdirectories: this takes an array of 0 to n subfolders (of your rootCodeDirectory) that you would like to back up. Any subfolders not in this list will be ignored
  > NOTE: specify only the folder names here (e.g. - ["src", "test"] and NOT ["C:\\dev\\github\\my-repo\\src", "C:\\dev\\github\\my-repo\\test"])
* backupRootDirectory: This is the folder where each backups will be placed in a subfolder. Example: "C:\\dev\\github\\_BACKUPS\\my-repo",
* checkForCodeChangesIntervalMinutes: the time interval (in minutes) at which the solution will check whether it is time to make a backup.
  > NOTE: use the JSON number syntax of `15` and NOT "15"
* timestampFormat: Determines the timestamp format of how backup folders will be named. For example, `yyyyMMdd - hh:mm tt` would yield a backup folder named `20251223 03.14 PM`

* Running a Backup (Ad Hoc)
  TODO

* Creating a Scheduled Task for Backups
  TODO
