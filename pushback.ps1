#requires -Version 5.1
<#
.SYNOPSIS
    CLI entry point for the Pushback engine.

.DESCRIPTION
    Thin wrapper around src/Pushback.Engine.psm1. Provides backward
    compatibility for the original single-file workflow while routing
    all real logic through the shared engine module so the CLI and the
    GUI behave identically.

.EXAMPLE
    .\pushback.ps1 -CommunityFolder 'C:\MSFS\Community' -Action DryRun

.EXAMPLE
    .\pushback.ps1 -CommunityFolder 'C:\MSFS\Community' -Action DisablePushback

.NOTES
    Default -Action is DryRun so running the script with no destructive
    flags never mutates files (constitution Principle III).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $CommunityFolder,

    [ValidateSet('DisablePushback','EnablePushback','DryRun','RestoreBackups')]
    [string] $Action = 'DryRun',

    [string] $LogPath = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Pushback\pushback.log'),

    [switch] $OverwriteExistingBackups
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\Pushback.Engine.psm1') -Force

$progress = {
    param($processed, $total, $entry)
    if ($entry) {
        Write-Host ("Processing: {0}" -f $entry.FullPath)
    }
}

$run = Invoke-PushbackEngine `
    -CommunityFolder $CommunityFolder `
    -Action $Action `
    -LogPath $LogPath `
    -ProgressCallback $progress `
    -OverwriteExistingBackups:$OverwriteExistingBackups

Write-Host ''
Write-Host ("Done. Action={0}  Changed={1}  WouldChange={2}  Unchanged={3}  Errors={4}" -f `
    $Action, $run.Counts.Changed, $run.Counts.WouldChange, $run.Counts.Unchanged, $run.Counts.Errors)
Write-Host ("Log: {0}" -f $run.LogPath)

# Emit the run object to the success stream so power users can pipe it.
$run