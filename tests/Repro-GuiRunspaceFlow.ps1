#requires -Version 5.1
# Headless reproduction of the GUI's runspace+EndInvoke flow without
# actually showing a window. Mirrors Start-EngineAction / Complete-EngineAction.

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$enginePath = Join-Path $repoRoot 'src\Pushback.Engine.psm1'

$folder       = Join-Path $repoRoot 'tests\fixtures\Community'
$logPath      = [IO.Path]::Combine($env:TEMP, "pushback-reproc-$(Get-Random).log")
$overwriteBak = $true
$simLabel     = 'Repro'

$cancelHolder   = [pscustomobject]@{ Value = $false }
$progressHolder = [hashtable]::Synchronized(@{ Processed = 0 })

$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'STA'
$rs.ThreadOptions  = 'ReuseThread'
$rs.Open()
$rs.SessionStateProxy.SetVariable('EnginePath',     $enginePath)
$rs.SessionStateProxy.SetVariable('Folder',         $folder)
$rs.SessionStateProxy.SetVariable('Action',         'DryRun')
$rs.SessionStateProxy.SetVariable('LogPath',        $logPath)
$rs.SessionStateProxy.SetVariable('Overwrite',      $overwriteBak)
$rs.SessionStateProxy.SetVariable('Cancel',         $cancelHolder)
$rs.SessionStateProxy.SetVariable('ProgressHolder', $progressHolder)
$rs.SessionStateProxy.SetVariable('SimLabel',       $simLabel)

$ps = [powershell]::Create()
$ps.Runspace = $rs
[void]$ps.AddScript({
    Import-Module $EnginePath -Force
    $progressCb = {
        param($processed, $total, $entry)
        $ProgressHolder.Processed = $processed
    }.GetNewClosure()
    try {
        $r = Invoke-PushbackEngine `
            -CommunityFolder $Folder `
            -Action $Action `
            -LogPath $LogPath `
            -TargetSim $SimLabel `
            -CancelFlag $Cancel `
            -ProgressCallback $progressCb `
            -OverwriteExistingBackups:$Overwrite
        return @{ Ok = $true; Run = $r }
    } catch {
        return @{ Ok = $false; ErrorId = $_.FullyQualifiedErrorId; Message = $_.Exception.Message }
    }
})

$handle = $ps.BeginInvoke()

# Wait for completion (poll like the DispatcherTimer would).
while (-not $handle.IsCompleted) { Start-Sleep -Milliseconds 50 }

Write-Host "Handle.IsCompleted = $($handle.IsCompleted)"
Write-Host "ProgressHolder.Processed = $($progressHolder.Processed)"

$results = $ps.EndInvoke($handle)
Write-Host "EndInvoke returned type: $($results.GetType().FullName)  Count=$($results.Count)"
for ($i = 0; $i -lt $results.Count; $i++) {
    $item = $results[$i]
    Write-Host "  [$i] type=$($item.GetType().FullName)"
    if ($item -is [hashtable]) {
        Write-Host "      Ok=$($item.Ok)  Has Run=$($null -ne $item.Run)"
        if ($item.Run) {
            Write-Host "      Run.LogPath=$($item.Run.LogPath)"
            Write-Host "      Run.Counts.Changed=$($item.Run.Counts.Changed) WouldChange=$($item.Run.Counts.WouldChange)"
            Write-Host "      Run.Entries.Count=$($item.Run.Entries.Count)"
            Write-Host "      Run.Entries[0].State=$($item.Run.Entries[0].State)"
            Write-Host "      Run.Entries[0].FullPath=$($item.Run.Entries[0].FullPath)"
        }
    }
}

$outcome = $results | Select-Object -First 1
Write-Host ""
Write-Host "Select-Object outcome type: $($outcome.GetType().FullName)"
Write-Host "outcome.Ok = $($outcome.Ok)"
$run = $outcome.Run
Write-Host "run type: $($run.GetType().FullName)"
Write-Host "run.LogPath = $($run.LogPath)"
Write-Host "run.Counts.Errors = $($run.Counts.Errors)"
foreach ($entry in $run.Entries) {
    Write-Host "  Entry: $($entry.State) $($entry.FullPath)"
}

$ps.Dispose()
$rs.Close()
$rs.Dispose()
Remove-Item $logPath -ErrorAction SilentlyContinue
Write-Host "DONE - no crash"
