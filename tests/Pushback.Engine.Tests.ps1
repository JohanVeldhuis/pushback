#requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for src/Pushback.Engine.psm1.

.DESCRIPTION
    Covers the critical invariants required by the spec:
      * Dry-run mutates no file content and no file mtimes.
      * Counter aggregation: Changed + WouldChange + Unchanged + Errors == Entries.Count.
      * Existing .bak files block real runs (PushbackEngine.BackupCollision).
      * -OverwriteExistingBackups overrides the block.
      * Disable -> Restore round-trips files to byte-identical originals.
      * RestoreBackups recreates the .cfg if it was deleted.

    Written in Pester 3-compatible syntax for the Pester 3.4 that ships
    with Windows PowerShell.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot       = Split-Path -Path $PSScriptRoot -Parent
$moduleUnderTest = Join-Path $repoRoot 'src\Pushback.Engine.psm1'
$fixtureRoot    = Join-Path $PSScriptRoot 'fixtures\Community'

Import-Module $moduleUnderTest -Force

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function New-TempDir {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("pushback-engine-tests-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

function Copy-FixtureTree {
    <#
    .SYNOPSIS
        Snapshot tests/fixtures/Community into a fresh temp directory so
        each test runs against pristine input.
    #>
    $dest = New-TempDir
    Copy-Item -LiteralPath $fixtureRoot -Destination $dest -Recurse -Force
    return (Join-Path $dest 'Community')
}

function Get-AircraftCfgFiles {
    param([string]$Root)
    return Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'aircraft.cfg'
}

function Get-BakFiles {
    param([string]$Root)
    return Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'aircraft.cfg.bak' -ErrorAction SilentlyContinue
}

function Get-FileFingerprint {
    <#
    .SYNOPSIS
        Capture path, mtime and SHA256 for every aircraft.cfg in $Root.
    #>
    param([string]$Root)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($f in (Get-AircraftCfgFiles -Root $Root)) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $hash  = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
            $list.Add([pscustomobject]@{
                FullPath = $f.FullName
                Length   = $bytes.Length
                Mtime    = $f.LastWriteTimeUtc
                Hash     = $hash
            }) | Out-Null
        }
        return $list
    } finally { $sha.Dispose() }
}

function Test-CounterInvariant {
    param($Result)
    $sum = $Result.Counts.Changed + $Result.Counts.WouldChange + $Result.Counts.Unchanged + $Result.Counts.Errors
    return ($sum -eq $Result.Entries.Count)
}

$script:tempPaths = New-Object System.Collections.Generic.List[string]
function Track-Temp([string]$Path) {
    if ($Path) { $script:tempPaths.Add($Path) | Out-Null }
    return $Path
}
function Clear-Temps {
    foreach ($p in $script:tempPaths) {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $script:tempPaths.Clear()
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

Describe 'Invoke-PushbackEngine: DryRun is non-destructive' {

    AfterEach { Clear-Temps }

    It 'never modifies file content or mtimes' {
        $community = Copy-FixtureTree
        Track-Temp ([System.IO.Path]::GetDirectoryName($community)) | Out-Null
        $log = Track-Temp (Join-Path (New-TempDir) 'pushback.log')

        $before = Get-FileFingerprint -Root $community
        $bakBefore = (Get-BakFiles -Root $community | Measure-Object).Count

        $result = Invoke-PushbackEngine -CommunityFolder $community -Action DryRun -LogPath $log

        $after  = Get-FileFingerprint -Root $community

        $after.Count | Should Be $before.Count
        for ($i = 0; $i -lt $before.Count; $i++) {
            $after[$i].FullPath | Should Be $before[$i].FullPath
            $after[$i].Hash     | Should Be $before[$i].Hash
            $after[$i].Length   | Should Be $before[$i].Length
            $after[$i].Mtime    | Should Be $before[$i].Mtime
        }

        # And no NEW .bak files appeared (fixture has one pre-existing .bak).
        $bakAfter = (Get-BakFiles -Root $community | Measure-Object).Count
        $bakAfter | Should Be $bakBefore

        # Counter invariant.
        Test-CounterInvariant -Result $result | Should Be $true

        # Fixture has 4 aircraft.cfg files: A (PUSHBACK=1), B (PUSHBACK=0),
        # C (no PUSHBACK line), D (PUSHBACK=1 plus pre-existing .bak).
        # DryRun previews Disable, so A + D = 2 WouldChange.
        $result.Counts.WouldChange | Should Be 2
        $result.Counts.Unchanged   | Should Be 2
        $result.Counts.Changed     | Should Be 0
        $result.Counts.Errors      | Should Be 0
    }
}

Describe 'Invoke-PushbackEngine: backup collision' {

    AfterEach { Clear-Temps }

    It 'throws PushbackEngine.BackupCollision when a .bak already exists' {
        $community = Copy-FixtureTree
        Track-Temp ([System.IO.Path]::GetDirectoryName($community)) | Out-Null
        $log = Track-Temp (Join-Path (New-TempDir) 'pushback.log')

        # AircraftD ships with a pre-existing .bak.
        (Get-BakFiles -Root $community | Measure-Object).Count | Should BeGreaterThan 0

        $threw = $false
        $errorId = $null
        try {
            Invoke-PushbackEngine -CommunityFolder $community -Action DisablePushback -LogPath $log
        } catch {
            $threw = $true
            $errorId = $_.FullyQualifiedErrorId
        }

        $threw   | Should Be $true
        $errorId | Should Match 'PushbackEngine\.BackupCollision'
    }

    It 'proceeds when -OverwriteExistingBackups is set' {
        $community = Copy-FixtureTree
        Track-Temp ([System.IO.Path]::GetDirectoryName($community)) | Out-Null
        $log = Track-Temp (Join-Path (New-TempDir) 'pushback.log')

        $result = Invoke-PushbackEngine -CommunityFolder $community -Action DisablePushback `
            -LogPath $log -OverwriteExistingBackups

        $result.OverwroteExistingBackups | Should Be $true
        $result.Counts.Errors            | Should Be 0
        Test-CounterInvariant -Result $result | Should Be $true
    }
}

Describe 'Invoke-PushbackEngine: Disable then Restore round-trip' {

    AfterEach { Clear-Temps }

    It 'restores every aircraft.cfg to its pre-Disable byte content' {
        $community = Copy-FixtureTree
        Track-Temp ([System.IO.Path]::GetDirectoryName($community)) | Out-Null
        $log = Track-Temp (Join-Path (New-TempDir) 'pushback.log')

        $original = Get-FileFingerprint -Root $community

        $disable = Invoke-PushbackEngine -CommunityFolder $community -Action DisablePushback `
            -LogPath $log -OverwriteExistingBackups

        $disable.Counts.Errors | Should Be 0
        Test-CounterInvariant -Result $disable | Should Be $true

        # Confirm something actually changed (AircraftA and AircraftD).
        $disable.Counts.Changed | Should Be 2

        # Now restore.
        $restore = Invoke-PushbackEngine -CommunityFolder $community -Action RestoreBackups -LogPath $log
        $restore.Counts.Errors | Should Be 0
        Test-CounterInvariant -Result $restore | Should Be $true

        $restored = Get-FileFingerprint -Root $community
        $restored.Count | Should Be $original.Count
        # Build path -> hash lookups for stable comparison regardless of order.
        $origMap = @{}; foreach ($f in $original) { $origMap[$f.FullPath] = $f.Hash }
        $restMap = @{}; foreach ($f in $restored) { $restMap[$f.FullPath] = $f.Hash }
        foreach ($k in $origMap.Keys) {
            $restMap.ContainsKey($k) | Should Be $true
            $restMap[$k]             | Should Be $origMap[$k]
        }
    }
}

Describe 'Invoke-PushbackEngine: RestoreBackups recreates deleted .cfg files' {

    AfterEach { Clear-Temps }

    It 'copies the .bak back into place when the .cfg has been deleted' {
        $community = Copy-FixtureTree
        Track-Temp ([System.IO.Path]::GetDirectoryName($community)) | Out-Null
        $log = Track-Temp (Join-Path (New-TempDir) 'pushback.log')

        $aircraftD = Join-Path $community 'AircraftD\aircraft.cfg'
        $bakD      = "$aircraftD.bak"
        Test-Path -LiteralPath $bakD | Should Be $true

        Remove-Item -LiteralPath $aircraftD -Force
        Test-Path -LiteralPath $aircraftD | Should Be $false

        $result = Invoke-PushbackEngine -CommunityFolder $community -Action RestoreBackups -LogPath $log
        $result.Counts.Errors | Should Be 0
        Test-CounterInvariant -Result $result | Should Be $true

        Test-Path -LiteralPath $aircraftD | Should Be $true
        $bakBytes    = [System.IO.File]::ReadAllBytes($bakD)
        $targetBytes = [System.IO.File]::ReadAllBytes($aircraftD)
        $targetBytes.Length | Should Be $bakBytes.Length
    }
}

Describe 'Invoke-PushbackEngine: cancellation' {

    AfterEach { Clear-Temps }

    It 'stops processing when CancelFlag.Value flips to $true mid-run' {
        $community = Copy-FixtureTree
        Track-Temp ([System.IO.Path]::GetDirectoryName($community)) | Out-Null
        $log = Track-Temp (Join-Path (New-TempDir) 'pushback.log')

        $cancel = [pscustomobject]@{ Value = $false }
        # Flip after the first file via the progress callback.
        $cb = { param($processed, $total, $entry) if ($processed -ge 1) { $cancel.Value = $true } }

        $result = Invoke-PushbackEngine -CommunityFolder $community -Action DryRun `
            -LogPath $log -CancelFlag $cancel -ProgressCallback $cb

        $result.CancelledByUser | Should Be $true
        # We should have processed strictly fewer than all 4 files.
        $result.Entries.Count | Should BeLessThan 4
        # Invariant still holds.
        Test-CounterInvariant -Result $result | Should Be $true
    }
}

Describe 'Invoke-PushbackEngine: log file' {

    AfterEach { Clear-Temps }

    It 'writes start and finish markers and one entry per processed file' {
        $community = Copy-FixtureTree
        Track-Temp ([System.IO.Path]::GetDirectoryName($community)) | Out-Null
        $log = Track-Temp (Join-Path (New-TempDir) 'pushback.log')

        $result = Invoke-PushbackEngine -CommunityFolder $community -Action DryRun -LogPath $log

        Test-Path -LiteralPath $log | Should Be $true
        $content = Get-Content -LiteralPath $log -Raw
        $content | Should Match '--- Script started:'
        $content | Should Match '--- Script finished:'
        $startCount  = ([regex]::Matches($content, '--- Script started:')).Count
        $finishCount = ([regex]::Matches($content, '--- Script finished:')).Count
        $startCount  | Should Be 1
        $finishCount | Should Be 1

        # One log line per processed file (state + path), in addition to start/finish.
        $lines = (Get-Content -LiteralPath $log)
        $entryLines = $lines | Where-Object { $_ -match '^(CHANGED|WOULD CHANGE|NO CHANGE|ERROR):' }
        $entryLines.Count | Should Be $result.Entries.Count
    }
}

Describe 'Test-PushbackCommunityFolder' {

    AfterEach { Clear-Temps }

    It 'returns $true for a folder containing aircraft.cfg files' {
        $community = Copy-FixtureTree
        Track-Temp ([System.IO.Path]::GetDirectoryName($community)) | Out-Null
        Test-PushbackCommunityFolder -Path $community | Should Be $true
    }

    It 'returns $false for an empty folder' {
        $empty = Track-Temp (New-TempDir)
        Test-PushbackCommunityFolder -Path $empty | Should Be $false
    }

    It 'returns $false for a path that does not exist' {
        $bogus = Join-Path ([System.IO.Path]::GetTempPath()) ("pushback-does-not-exist-" + [Guid]::NewGuid().ToString('N'))
        Test-PushbackCommunityFolder -Path $bogus | Should Be $false
    }
}
