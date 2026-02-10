# Testing Guide for ReactiveBackup

## Quick Test: Parse-RepositoryList Function

The Parse-RepositoryList function handles all input parsing for the `-r` parameter. To test this function in isolation:

### Using VS Code Tasks

1. Open VS Code at the ReactiveBackup folder
2. Press `Ctrl+Shift+P` to open the command palette
3. Type "Run Task" and select "Tasks: Run Task"
4. Select "Test: Parse-RepositoryList Function"

This will run a comprehensive test suite that validates:

- Single repositories
- Multiple repositories
- Bracket syntax
- Quoted names with spaces
- Mixed quoting styles

All tests are marked as PASS or FAIL with green and red colors respectively.

### Running Directly

You can also run the test file directly from PowerShell:

```powershell
cd C:\dev\github\ReactiveBackup
.\test-parse.ps1
```

## Integration Tests: Full Script Execution

To test the full script with the `-r` parameter, available VS Code tasks are:

- **Test: Single repo -r jtt**
- **Test: Multiple repos -r 'jtt, aardvark'**
- **Test: Bracket syntax -r '[jtt, aardvark]'**
- **Test: Quoted name -r '[jtt, "apple cinnamon"]'**

Each task runs the ReactiveBackup script and displays:

- The exact command being executed
- Which repositories were parsed
- Which repositories were found
- Warnings for any repositories not found
- Backup progress and status

### Recommended Syntaxes for Manual Testing

```powershell
# Single repo
.\ReactiveBackup.ps1 -r jtt -m "Test single"

# Multiple repos (cleanest - no quoting needed)
.\ReactiveBackup.ps1 -r jtt, aardvark -m "Test multiple"

# Multiple repos with spaces (use quotes per repo)
.\ReactiveBackup.ps1 -r jtt, "apple cinnamon" -m "Test spaces"

# Bracket syntax with quoted repo names
.\ReactiveBackup.ps1 -r '[jtt, "apple cinnamon"]' -m "Test bracket"
```

## Debugging

If tests fail:

1. Check that directories `C:\dev\github\jtt`, `C:\dev\github\aardvark`, and `C:\dev\github\apple cinnamon` exist
2. Verify `ReactiveBackup.actual.config` has:
   - `"backupLevel": "repo-parent"`
   - `"rootCodeDirectory": "C:/dev/github"` (or similar)
3. Check the output in the VS Code task panel for error messages

## Manual Testing

You can also manually test by running:

```powershell
.\ReactiveBackup.ps1 -r jtt -m "Test message"
```

Replace `jtt` and `"Test message"` with your own values.
