#!/usr/bin/env pwsh

# Simple test runner
cd C:\dev\github\ReactiveBackup

Write-Host "Test 1: Single repo `"jtt`""
& ./ReactiveBackup.ps1 -r jtt -m "Test single"

Write-Host ""
Write-Host "Test 2: Multiple repos `"jtt, aardvark`""
& ./ReactiveBackup.ps1 -r "jtt, aardvark" -m "Test multiple"

Write-Host ""
Write-Host "Test 3: Bracket syntax `"[jtt, aardvark]`""
& ./ReactiveBackup.ps1 -r "[jtt, aardvark]" -m "Test brackets"

Write-Host ""
Write-Host "Test 4: Quoted name `"[jtt, `"apple cinnamon`"]`""
& ./ReactiveBackup.ps1 -r '[jtt, "apple cinnamon"]' -m "Test quoted"
