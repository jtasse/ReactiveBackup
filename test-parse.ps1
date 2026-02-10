# Standalone Test for Parse-RepositoryList Function

function Parse-RepositoryList {
    param([string]$RepositoryInput)
    
    if ([string]::IsNullOrWhiteSpace($RepositoryInput)) {
        return @()
    }
    
    $input = $RepositoryInput.Trim()
    
    # Remove outer brackets if present: [repo1, repo2] -> repo1, repo2
    if ($input -match '^\[(.*)\]$') {
        $input = $matches[1].Trim()
    }
    
    $repos = @()
    
    # Split by comma and process each entry
    $parts = $input -split ','
    
    foreach ($part in $parts) {
        $part = $part.Trim()
        
        if ([string]::IsNullOrEmpty($part)) {
            continue
        }
        
        # Handle quoted strings (remove surrounding quotes)
        if ($part -match '^"(.+)"$') {
            $part = $matches[1]
        }
        elseif ($part -match "^'(.+)'$") {
            $part = $matches[1]
        }
        
        $part = $part.Trim()
        if ($part) {
            $repos += $part
        }
    }
    
    return ,$repos
}

Write-Host "======================================"
Write-Host "Parse-RepositoryList Test Suite"
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# Test 1: Single repo, no brackets
Write-Host "Test 1: Single repo, no brackets"
Write-Host "  Input:    `"jtt`""
$result = Parse-RepositoryList 'jtt'
Write-Host "  Output:   $($result -join ', ')"
Write-Host "  Expected: jtt"
Write-Host "  Status:   $(if ($result.Count -eq 1 -and $result[0] -eq 'jtt') { 'PASS' } else { 'FAIL' })" -ForegroundColor $(if ($result.Count -eq 1 -and $result[0] -eq 'jtt') { 'Green' } else { 'Red' })
Write-Host ""

# Test 2: Multiple repos, no brackets
Write-Host "Test 2: Multiple repos, no brackets"
Write-Host "  Input:    `"jtt, aardvark`""
$result = Parse-RepositoryList 'jtt, aardvark'
Write-Host "  Output:   $($result -join ', ')"
Write-Host "  Expected: jtt, aardvark"
Write-Host "  Status:   $(if ($result.Count -eq 2 -and $result[0] -eq 'jtt' -and $result[1] -eq 'aardvark') { 'PASS' } else { 'FAIL' })" -ForegroundColor $(if ($result.Count -eq 2 -and $result[0] -eq 'jtt' -and $result[1] -eq 'aardvark') { 'Green' } else { 'Red' })
Write-Host ""

# Test 3: Multiple repos with brackets
Write-Host "Test 3: Multiple repos with brackets"
Write-Host "  Input:    `"[jtt, aardvark]`""
$result = Parse-RepositoryList '[jtt, aardvark]'
Write-Host "  Output:   $($result -join ', ')"
Write-Host "  Expected: jtt, aardvark"
Write-Host "  Status:   $(if ($result.Count -eq 2 -and $result[0] -eq 'jtt' -and $result[1] -eq 'aardvark') { 'PASS' } else { 'FAIL' })" -ForegroundColor $(if ($result.Count -eq 2 -and $result[0] -eq 'jtt' -and $result[1] -eq 'aardvark') { 'Green' } else { 'Red' })
Write-Host ""

# Test 4: Quoted name with space
Write-Host "Test 4: Quoted name with space"
Write-Host "  Input:    `"[jtt, `"apple cinnamon`"]`""
$result = Parse-RepositoryList '[jtt, "apple cinnamon"]'
Write-Host "  Output:   $($result -join ', ')"
Write-Host "  Expected: jtt, apple cinnamon"
Write-Host "  Status:   $(if ($result.Count -eq 2 -and $result[0] -eq 'jtt' -and $result[1] -eq 'apple cinnamon') { 'PASS' } else { 'FAIL' })" -ForegroundColor $(if ($result.Count -eq 2 -and $result[0] -eq 'jtt' -and $result[1] -eq 'apple cinnamon') { 'Green' } else { 'Red' })
Write-Host ""

# Test 5: Quoted name first
Write-Host "Test 5: Quoted name first"
Write-Host "  Input:    `"[`"apple cinnamon`", jtt]`""
$result = Parse-RepositoryList '["apple cinnamon", jtt]'
Write-Host "  Output:   $($result -join ', ')"
Write-Host "  Expected: apple cinnamon, jtt"
Write-Host "  Status:   $(if ($result.Count -eq 2 -and $result[0] -eq 'apple cinnamon' -and $result[1] -eq 'jtt') { 'PASS' } else { 'FAIL' })" -ForegroundColor $(if ($result.Count -eq 2 -and $result[0] -eq 'apple cinnamon' -and $result[1] -eq 'jtt') { 'Green' } else { 'Red' })
Write-Host ""

# Test 6: Three repos with mixed quoting
Write-Host "Test 6: Three repos with mixed quoting"
Write-Host "  Input:    `"jtt, `"apple cinnamon`", aardvark`""
$result = Parse-RepositoryList 'jtt, "apple cinnamon", aardvark'
Write-Host "  Output:   $($result -join ', ')"
Write-Host "  Expected: jtt, apple cinnamon, aardvark"
Write-Host "  Status:   $(if ($result.Count -eq 3 -and $result[0] -eq 'jtt' -and $result[1] -eq 'apple cinnamon' -and $result[2] -eq 'aardvark') { 'PASS' } else { 'FAIL' })" -ForegroundColor $(if ($result.Count -eq 3 -and $result[0] -eq 'jtt' -and $result[1] -eq 'apple cinnamon' -and $result[2] -eq 'aardvark') { 'Green' } else { 'Red' })
Write-Host ""

Write-Host "======================================"
Write-Host "Test Suite Complete" -ForegroundColor Cyan
Write-Host "======================================"

