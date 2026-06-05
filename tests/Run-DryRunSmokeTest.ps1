#requires -Version 5.1
<#
.SYNOPSIS
    Mandatory PR-evidence smoke test (constitution Principle II).

.DESCRIPTION
    Runs Invoke-PushbackEngine in DryRun mode against the fixture
    Community tree, records each file's pre-run modification timestamp,
    asserts NO file mtime changed after the run, prints the run summary,
    and exits with code 0 on success / non-zero on failure.

    Paste or link the produced log into your PR description.
#>

[CmdletBinding()]
param(
    [string]$LogPath = (Join-Path $env:TEMP ("pushback-smoke-{0}.log" -f ([Guid]::NewGuid().ToString('N'))))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot       = Split-Path -Parent $PSScriptRoot
$enginePath     = Join-Path $repoRoot 'src\Pushback.Engine.psm1'
$fixtureRoot    = Join-Path $repoRoot 'tests\fixtures\Community'

if (-not (Test-Path -LiteralPath $fixtureRoot -PathType Container)) {
    throw "Fixture community folder not found: $fixtureRoot"
}

Import-Module $enginePath -Force

# Snapshot every aircraft.cfg mtime before the run.
$snapshot = @{}
Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File -Filter 'aircraft.cfg' |
    ForEach-Object { $snapshot[$_.FullName] = $_.LastWriteTimeUtc }

Write-Host "Running DryRun smoke test against $fixtureRoot"
Write-Host "Log: $LogPath"
Write-Host ''

$progress = {
    param($processed, $total, $entry)
    if ($entry) { Write-Host ("Processing: {0}" -f $entry.FullPath) }
}

$run = Invoke-PushbackEngine `
    -CommunityFolder $fixtureRoot `
    -Action DryRun `
    -LogPath $LogPath `
    -ProgressCallback $progress `
    -OverwriteExistingBackups   # tolerate pre-existing .bak from fixture AircraftD

Write-Host ''
Write-Host '=== Summary ==='
Write-Host ("Changed     : {0}" -f $run.Counts.Changed)
Write-Host ("WouldChange : {0}" -f $run.Counts.WouldChange)
Write-Host ("Unchanged   : {0}" -f $run.Counts.Unchanged)
Write-Host ("Errors      : {0}" -f $run.Counts.Errors)

# Assertions.
$failures = New-Object System.Collections.Generic.List[string]

if ($run.Counts.Changed -ne 0) {
    $failures.Add("DryRun produced Changed=$($run.Counts.Changed); expected 0.")
}

# Verify counters add up to entries.
$total = $run.Counts.Changed + $run.Counts.WouldChange + $run.Counts.Unchanged + $run.Counts.Errors
if ($total -ne $run.Entries.Count) {
    $failures.Add("Counters ($total) != entries ($($run.Entries.Count)).")
}

# Verify no aircraft.cfg mtime changed.
foreach ($kvp in $snapshot.GetEnumerator()) {
    $now = (Get-Item -LiteralPath $kvp.Key).LastWriteTimeUtc
    if ($now -ne $kvp.Value) {
        $failures.Add("DryRun mutated file mtime: $($kvp.Key)")
    }
}

# Verify log structure.
$logLines = Get-Content -LiteralPath $LogPath
if (-not ($logLines | Select-Object -First 1) -match '^--- Script started: .* ---$') {
    $failures.Add('Log start marker missing or malformed.')
}
if (-not ($logLines | Select-Object -Last 1) -match '^--- Script finished: .* ---$') {
    $failures.Add('Log finish marker missing or malformed.')
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host 'FAIL:' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}

Write-Host 'PASS — DryRun is non-destructive and counts/log are consistent.' -ForegroundColor Green
exit 0
