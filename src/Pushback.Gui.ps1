#requires -Version 5.1
<#
.SYNOPSIS
    Pushback WPF GUI host. Loads MainWindow.xaml, wires controls to the
    engine module, and runs engine work on a background Runspace so the
    UI stays responsive.

.NOTES
    Contracts: specs/001-pushback-app/contracts/gui-actions.md
               specs/001-pushback-app/contracts/engine-cli.md
    Threading rules: research.md §2.
#>

[CmdletBinding()]
param()

# Strict mode is intentionally NOT enabled here: WPF dynamic objects
# (e.g. $window.FindName) return $null for missing names, and strict
# mode would block legitimate "control not present yet" checks.
$ErrorActionPreference = 'Stop'

# --- CONFIGURATION ---
$script:LogPathDefault = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Pushback\pushback.log'
$script:IsDebugBuild   = -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\RELEASE'))

# Load WPF assemblies.
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

# Import engine + detection modules from the script's own directory.
Import-Module (Join-Path $PSScriptRoot 'Pushback.Engine.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'Pushback.SimDetect.psm1') -Force

# ---------------------------------------------------------------------------
# Load XAML
# ---------------------------------------------------------------------------
$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -Raw -LiteralPath $xamlPath
$reader    = [System.Xml.XmlNodeReader]::new($xaml)
$window    = [System.Windows.Markup.XamlReader]::Load($reader)

# Bind named controls onto convenient script-scope variables.
$controlNames = @(
    'cmbSim','txtCommunityFolder','bannerNoSim','btnBrowse',
    'btnDryRun','btnDisable','btnEnable','btnRestore',
    'btnCancel','prgProgress',
    'lstResults','tabChanged','tabWouldChange','tabUnchanged','tabErrors',
    'lstChanged','lstWouldChange','lstUnchanged','lstErrors',
    'chkOverwriteBak','txtStatus','btnOpenLog',
    'lstPackages','btnPkgSelectAll','btnPkgClear','btnPkgRefresh',
    'txtPkgSearch','txtPkgCount','btnPkgPresetFSLTL','btnPkgPresetAIG',
    'txtScopeSummary','txtScopeDetails','btnPkgSearchClear','btnScopeAcknowledge'
)
$ctl = @{}
foreach ($name in $controlNames) {
    $ctl[$name] = $window.FindName($name)
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:lastLogPath  = $null
$script:currentRun   = $null    # PSObject: @{ Runspace=...; PowerShell=...; Handle=...; CancelFlag=[ref][bool] }
$script:isRunning    = $false
$script:sims         = @()      # full Get-SimulatorInstallation result (both records)
$script:detectedSims = @()      # subset shown in cmbSim, index-aligned with cmbSim.Items
$script:customFolder = $null    # set by btnBrowse
$script:pollTimer    = $null    # DispatcherTimer for runspace polling (script-scoped so Add_Tick can see it)
$script:diagLogPath  = Join-Path $env:TEMP 'pushback-gui-diag.log'
$script:packageNamesByKey = @{} # key: normalized community folder -> [string[]] package names
$script:packagePickByKey  = @{} # key: normalized community folder -> hashtable(name -> [bool])
$script:pkgSearchPlaceholder = 'Filter packages...'
$script:allScopeRiskAcknowledged = $false

function Write-DiagLog {
    param([string]$Message, [System.Management.Automation.ErrorRecord]$ErrorRecord)
    $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $line = "[$ts] $Message"
    if ($ErrorRecord) {
        $line += "`r`n  Error: $($ErrorRecord.Exception.Message)"
        $line += "`r`n  FQEI:  $($ErrorRecord.FullyQualifiedErrorId)"
        $line += "`r`n  At:    $($ErrorRecord.InvocationInfo.PositionMessage)"
        $line += "`r`n  Stack: $($ErrorRecord.ScriptStackTrace)"
    }
    try { Add-Content -LiteralPath $script:diagLogPath -Value $line -Encoding utf8 } catch { }
}

function Invoke-UiSafely {
    # Run a UI callback with try/catch + log; never let exceptions escape
    # into the WPF Dispatcher (which would tear down ShowDialog).
    param([Parameter(Mandatory)][scriptblock]$Action, [string]$Tag)
    try {
        & $Action
    } catch {
        Write-DiagLog -Message "UI callback failed in [$Tag]" -ErrorRecord $_
        try {
            [System.Windows.MessageBox]::Show(
                "$Tag failed:`n`n$($_.Exception.Message)`n`nSee $script:diagLogPath for the full trace.",
                'Addon Pushback Manager — internal error', 'OK', 'Error') | Out-Null
        } catch { }
    }
}

# ---------------------------------------------------------------------------
# UI helpers (all called on the UI thread)
# ---------------------------------------------------------------------------
function Set-Status { param([string]$Text) $ctl.txtStatus.Text = $Text }

function Get-EffectiveCommunityFolder {
    if ($script:customFolder) { return $script:customFolder }
    $sim = Get-SelectedSim
    if ($null -ne $sim) { return $sim.CommunityFolder }
    return $null
}

function Get-EffectiveSimLabel {
    if ($script:customFolder) { return 'Custom' }
    $sim = Get-SelectedSim
    if ($null -ne $sim) { return $sim.DisplayName }
    return ''
}

function Get-SelectedSim {
    # cmbSim items are plain strings (display labels). The matching
    # SimulatorInstallation record lives in $script:detectedSims at
    # the same index. Returns $null if nothing is selected.
    $idx = $ctl.cmbSim.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $script:detectedSims.Count) { return $null }
    return $script:detectedSims[$idx]
}

function Update-ActionButtonsEnabled {
    $hasTarget = [bool](Get-EffectiveCommunityFolder)
    $enable    = ($hasTarget -and -not $script:isRunning)

    # DryRun/Restore are always available when a target exists.
    foreach ($b in @('btnDryRun','btnRestore')) {
        $ctl[$b].IsEnabled = $enable
    }

    # Disable/Enable require one-time all-scope acknowledgement when no
    # package filter is selected.
    $hasPackageFilter = [bool](Get-SelectedPackageFilter)
    $destructiveAllowed = $enable -and ($hasPackageFilter -or $script:allScopeRiskAcknowledged)
    foreach ($b in @('btnDisable','btnEnable')) {
        $ctl[$b].IsEnabled = $destructiveAllowed
    }
    $ctl.btnBrowse.IsEnabled = -not $script:isRunning
    $ctl.btnOpenLog.IsEnabled = -not $script:isRunning
    foreach ($b in @('btnPkgSelectAll','btnPkgClear','btnPkgRefresh','btnPkgPresetFSLTL','btnPkgPresetAIG','btnPkgSearchClear')) {
        $ctl[$b].IsEnabled = (-not $script:isRunning) -and $hasTarget
    }
    $ctl.txtPkgSearch.IsEnabled = (-not $script:isRunning) -and $hasTarget
    $ctl.lstPackages.IsEnabled = -not $script:isRunning
}

function Get-PackageSelectionKey {
    $folder = Get-EffectiveCommunityFolder
    if ([string]::IsNullOrWhiteSpace($folder)) { return $null }
    try {
        return ([System.IO.Path]::GetFullPath($folder)).ToLowerInvariant()
    } catch {
        return $folder.ToLowerInvariant()
    }
}

function Ensure-PackageSelectionMap {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string[]]$Names
    )

    if (-not $script:packagePickByKey.ContainsKey($Key)) {
        $script:packagePickByKey[$Key] = @{}
    }
    $map = $script:packagePickByKey[$Key]

    # Drop selections for packages that no longer exist in this folder.
    foreach ($existing in @($map.Keys)) {
        if ($existing -notin $Names) { $map.Remove($existing) | Out-Null }
    }
    # Seed new package names as unticked.
    foreach ($n in $Names) {
        if (-not $map.ContainsKey($n)) { $map[$n] = $false }
    }
}

function Get-SelectedPackageFilter {
    <#
    .SYNOPSIS
        Returns a string[] of selected package names, or $null if no
        package is selected (meaning "scan everything").
    #>
    $key = Get-PackageSelectionKey
    if (-not $key) { return $null }
    if (-not $script:packagePickByKey.ContainsKey($key)) { return $null }

    $selected = @()
    $map = $script:packagePickByKey[$key]
    foreach ($n in @($map.Keys)) {
        if ($map[$n]) { $selected += [string]$n }
    }
    if ($selected.Count -eq 0) { return $null }
    return ,@($selected | Sort-Object)
}

function Update-PackageScopeSummary {
    $key = Get-PackageSelectionKey
    if (-not $key -or -not $script:packageNamesByKey.ContainsKey($key)) {
        $ctl.txtPkgCount.Text = '0 selected of 0 packages'
        $ctl.txtScopeSummary.Text = 'Scope: All packages'
        $ctl.txtScopeSummary.Foreground = '#8A5A00'
        $ctl.txtScopeSummary.Background = '#FFF4CE'
        $ctl.txtScopeSummary.TextTrimming = 'CharacterEllipsis'
        $ctl.txtScopeSummary.Padding = '8,2'
        if ($script:allScopeRiskAcknowledged) {
            $ctl.txtScopeDetails.Text = 'No package filter selected (acknowledged for this session)'
            $ctl.btnScopeAcknowledge.Visibility = 'Collapsed'
        } else {
            $ctl.txtScopeDetails.Text = 'Disable/Enable locked until you acknowledge this scope'
            $ctl.btnScopeAcknowledge.Visibility = 'Visible'
        }
        Update-ActionButtonsEnabled
        return
    }

    $allNames = @($script:packageNamesByKey[$key])
    $total = $allNames.Count

    $selectedCount = 0
    if ($script:packagePickByKey.ContainsKey($key)) {
        $map = $script:packagePickByKey[$key]
        foreach ($n in $allNames) {
            if ($map.ContainsKey($n) -and $map[$n]) { $selectedCount++ }
        }
    }

    $ctl.txtPkgCount.Text = "{0} selected of {1} packages" -f $selectedCount, $total
    $selectedNames = @()
    if ($selectedCount -gt 0) {
        foreach ($n in $allNames) {
            if ($map.ContainsKey($n) -and $map[$n]) { $selectedNames += $n }
        }
    }
    if ($selectedCount -eq 0) {
        $ctl.txtScopeSummary.Text = 'Scope: All packages'
        $ctl.txtScopeSummary.Foreground = '#8A5A00'
        $ctl.txtScopeSummary.Background = '#FFF4CE'
        if ($script:allScopeRiskAcknowledged) {
            $ctl.txtScopeDetails.Text = 'No package filter selected (acknowledged for this session)'
            $ctl.btnScopeAcknowledge.Visibility = 'Collapsed'
        } else {
            $ctl.txtScopeDetails.Text = 'Disable/Enable locked until you acknowledge this scope'
            $ctl.btnScopeAcknowledge.Visibility = 'Visible'
        }
    } else {
        $ctl.txtScopeSummary.Text = "Scope: {0} selected" -f $selectedCount
        $ctl.txtScopeSummary.Foreground = '#1E6D2D'
        $ctl.txtScopeSummary.Background = '#DFF6DD'
        $ctl.btnScopeAcknowledge.Visibility = 'Collapsed'
        $preview = @($selectedNames | Select-Object -First 2)
        if ($selectedNames.Count -le 2) {
            $ctl.txtScopeDetails.Text = ($preview -join ', ')
        } else {
            $ctl.txtScopeDetails.Text = "{0}, {1} (+{2} more)" -f $preview[0], $preview[1], ($selectedNames.Count - 2)
        }
    }
    Update-ActionButtonsEnabled
}

function Get-PackageSearchQuery {
    $q = [string]$ctl.txtPkgSearch.Text
    if (-not $q) { return '' }
    if ($q -eq $script:pkgSearchPlaceholder) { return '' }
    return $q.Trim()
}

function Set-PackageSearchPlaceholder {
    if ([string]::IsNullOrWhiteSpace([string]$ctl.txtPkgSearch.Text)) {
        $ctl.txtPkgSearch.Text = $script:pkgSearchPlaceholder
        $ctl.txtPkgSearch.Foreground = 'Gray'
    }
}

function Render-PackageChecklist {
    $ctl.lstPackages.Items.Clear()

    $key = Get-PackageSelectionKey
    if (-not $key -or -not $script:packageNamesByKey.ContainsKey($key)) {
        Update-PackageScopeSummary
        return
    }

    $names = @($script:packageNamesByKey[$key])
    Ensure-PackageSelectionMap -Key $key -Names $names

    $query = Get-PackageSearchQuery

    $idx = 0
    foreach ($n in $names) {
        if ($query -and ($n -notlike "*$query*")) { continue }

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $n
        $cb.Tag     = $n
        $cb.Margin  = '0,1,0,1'
        $cb.Padding = '2,2,2,2'
        if (($idx % 2) -eq 1) { $cb.Background = '#F7F7F7' }
        $cb.IsChecked = [bool]$script:packagePickByKey[$key][$n]

        $pkgName = $n
        $cb.Add_Checked({
            $k = Get-PackageSelectionKey
            if ($k -and $script:packagePickByKey.ContainsKey($k)) {
                $script:packagePickByKey[$k][$pkgName] = $true
                Update-PackageScopeSummary
            }
        }.GetNewClosure())
        $cb.Add_Unchecked({
            $k = Get-PackageSelectionKey
            if ($k -and $script:packagePickByKey.ContainsKey($k)) {
                $script:packagePickByKey[$k][$pkgName] = $false
                Update-PackageScopeSummary
            }
        }.GetNewClosure())

        [void]$ctl.lstPackages.Items.Add($cb)
        $idx++
    }

    Update-PackageScopeSummary
}

function Refresh-PackageList {
    <#
    .SYNOPSIS
        Re-enumerate immediate child folders for the current Community
        folder and rebuild the package checklist view.
    #>
    $ctl.lstPackages.Items.Clear()
    $folder = Get-EffectiveCommunityFolder
    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
        Update-PackageScopeSummary
        return
    }

    try {
        $names = @(
            Get-ChildItem -LiteralPath $folder -Directory -ErrorAction Stop |
                Sort-Object Name |
                ForEach-Object { $_.Name }
        )
    } catch {
        Write-DiagLog -Message "Refresh-PackageList: failed to enumerate '$folder'" -ErrorRecord $_
        Update-PackageScopeSummary
        return
    }

    $key = Get-PackageSelectionKey
    if (-not $key) {
        Update-PackageScopeSummary
        return
    }

    $script:packageNamesByKey[$key] = $names
    Ensure-PackageSelectionMap -Key $key -Names $names
    Render-PackageChecklist
}

function Select-PackagesByPattern {
    param([Parameter(Mandatory)][string]$Pattern)

    $key = Get-PackageSelectionKey
    if (-not $key -or -not $script:packageNamesByKey.ContainsKey($key)) { return }

    $names = @($script:packageNamesByKey[$key])
    Ensure-PackageSelectionMap -Key $key -Names $names

    foreach ($n in $names) {
        $script:packagePickByKey[$key][$n] = ($n -like $Pattern)
    }
    Render-PackageChecklist
}

function Get-PackageImpactEstimate {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Folder)

    $pkgCount = 0
    $cfgCount = -1

    try {
        $pkgCount = @(Get-ChildItem -LiteralPath $Folder -Directory -ErrorAction Stop).Count
    } catch { }

    try {
        $cfgCount = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Filter 'aircraft.cfg' -ErrorAction SilentlyContinue).Count
    } catch { }

    return [pscustomobject]@{
        PackageCount = $pkgCount
        AircraftCfgCount = $cfgCount
    }
}

function Reset-ResultsPane {
    foreach ($listName in @('lstChanged','lstWouldChange','lstUnchanged','lstErrors')) {
        $ctl[$listName].Items.Clear()
    }
    $ctl.tabChanged.Header     = 'Changed (0)'
    $ctl.tabWouldChange.Header = 'Would change (0)'
    $ctl.tabUnchanged.Header   = 'Unchanged (0)'
    $ctl.tabErrors.Header      = 'Errors (0)'
    $ctl.prgProgress.Value     = 0
    $ctl.prgProgress.Maximum   = 1
    $ctl.prgProgress.IsIndeterminate = $false
}

function Populate-ResultsFromRun {
    param([pscustomobject]$Run)

    Reset-ResultsPane

    foreach ($entry in $Run.Entries) {
        switch ($entry.State) {
            'CHANGED'      { [void]$ctl.lstChanged.Items.Add($entry.FullPath) }
            'WOULD CHANGE' { [void]$ctl.lstWouldChange.Items.Add($entry.FullPath) }
            'NO CHANGE'    { [void]$ctl.lstUnchanged.Items.Add($entry.FullPath) }
            'ERROR'        { [void]$ctl.lstErrors.Items.Add($entry.ErrorMessage) }
        }
    }
    $ctl.tabChanged.Header     = "Changed ($($Run.Counts.Changed))"
    $ctl.tabWouldChange.Header = "Would change ($($Run.Counts.WouldChange))"
    $ctl.tabUnchanged.Header   = "Unchanged ($($Run.Counts.Unchanged))"
    $ctl.tabErrors.Header      = "Errors ($($Run.Counts.Errors))"

    # Auto-select the most informative tab.
    if ($Run.Counts.Errors -gt 0) { $ctl.lstResults.SelectedItem = $ctl.tabErrors }
    elseif ($Run.Counts.Changed -gt 0) { $ctl.lstResults.SelectedItem = $ctl.tabChanged }
    elseif ($Run.Counts.WouldChange -gt 0) { $ctl.lstResults.SelectedItem = $ctl.tabWouldChange }
    else { $ctl.lstResults.SelectedItem = $ctl.tabUnchanged }
}

# ---------------------------------------------------------------------------
# Sim detection / chooser
# ---------------------------------------------------------------------------
function Refresh-Detection {
    # Get-SimulatorInstallation uses `return ,@($results)` so direct
    # callers receive a real array even when there's only one record.
    # Wrapping it AGAIN in @() here would nest the array, so we cast
    # to [object[]] instead. Subsequent .Count and indexing then work
    # reliably.
    $script:sims        = [object[]](Get-SimulatorInstallation)
    $script:detectedSims = [object[]]($script:sims | Where-Object { $_.Status -eq 'Detected' })
    $detCount           = $script:detectedSims.Count

    # Only list sims that are actually installed AND have a working
    # Community folder. Misconfigured / NotInstalled sims would be
    # picks the user can't act on, so they're surfaced via the banner
    # and the Browse… flow instead of cluttering the dropdown.
    #
    # Each ComboBox entry is a plain string. The matching sim record
    # is looked up by SelectedIndex against $script:detectedSims — see
    # Get-SelectedSim. We use an indexed for-loop (not foreach) to
    # sidestep any PowerShell array-unrolling surprises that could
    # collapse two items into one.
    $ctl.cmbSim.Items.Clear()
    for ($i = 0; $i -lt $detCount; $i++) {
        $label = [string]$script:detectedSims[$i].DisplayName
        [void]$ctl.cmbSim.Items.Add($label)
    }

    if ($detCount -eq 0) {
        # No sim detected — surface manual override path (US4).
        # Build a helpful banner that mentions any Misconfigured sims so
        # the user knows WHY auto-detection didn't pick them up.
        $misconfigured = @($script:sims | Where-Object { $_.Status -eq 'Misconfigured' })
        if ($misconfigured.Count -gt 0) {
            $details = ($misconfigured | ForEach-Object { "$($_.DisplayName): $($_.StatusDetail)" }) -join '   |   '
            $ctl.bannerNoSim.Text = "No usable MSFS installation detected ($details). Click Browse… to select your Community folder manually."
        } else {
            $ctl.bannerNoSim.Text = 'No MSFS installation detected. Click Browse… to select your Community folder manually.'
        }
        $ctl.bannerNoSim.Visibility   = 'Visible'
        $ctl.cmbSim.IsEnabled         = $false
        $ctl.cmbSim.SelectedIndex     = -1
        $ctl.txtCommunityFolder.Text  = ''
    } elseif ($detCount -eq 1) {
        $ctl.bannerNoSim.Visibility = 'Collapsed'
        $ctl.cmbSim.IsEnabled       = $true
        # Pre-select the only detected sim (FR-009).
        $ctl.cmbSim.SelectedIndex   = 0
    } else {
        # Both detected — require explicit pick (FR-008 / US2).
        $ctl.bannerNoSim.Visibility  = 'Collapsed'
        $ctl.cmbSim.IsEnabled        = $true
        $ctl.cmbSim.SelectedIndex    = -1
        $ctl.txtCommunityFolder.Text = ''
        Set-Status 'Both MSFS 2020 and MSFS 2024 detected. Pick one above to continue.'
    }

    Update-ActionButtonsEnabled
}

# ---------------------------------------------------------------------------
# Background run / progress / completion
# ---------------------------------------------------------------------------
function Start-EngineAction {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DisablePushback','EnablePushback','DryRun','RestoreBackups')]
        [string]$Action
    )

    if ($script:isRunning) { return }

    $folder = Get-EffectiveCommunityFolder
    if (-not $folder) {
        [System.Windows.MessageBox]::Show(
            'No Community folder selected. Pick a sim above or use Browse…',
            'Addon Pushback Manager', 'OK', 'Warning') | Out-Null
        return
    }

    if ($Action -eq 'RestoreBackups') {
        $res = [System.Windows.MessageBox]::Show(
            "Restore every aircraft.cfg from its .bak under`n$folder?`n`nThis will undo your last Disable/Enable run.",
            'Restore backups', 'OKCancel', 'Question')
        if ($res -ne 'OK') { return }
    }

    # Resolve the package filter (or $null = scan everything).
    $packageFilter = Get-SelectedPackageFilter
    $scopeText = if ($packageFilter) {
        "{0} selected package(s)" -f $packageFilter.Count
    } else {
        'All packages'
    }

    # If the user is about to mutate files and hasn't scoped the run
    # via the Packages checkboxes, warn that the scan will touch every
    # add-on under the Community folder. DryRun is read-only so it
    # skips this confirmation. RestoreBackups already has its own
    # confirmation above.
    if (-not $packageFilter -and ($Action -eq 'DisablePushback' -or $Action -eq 'EnablePushback')) {
        if ($ctl.lstPackages.Items.Count -gt 0) {
            $verb = if ($Action -eq 'DisablePushback') { 'disable' } else { 'enable' }
            $impact = Get-PackageImpactEstimate -Folder $folder
            $impactLine = if ($impact.AircraftCfgCount -ge 0) {
                "Estimated impact: {0} package(s), {1} aircraft.cfg file(s)." -f $impact.PackageCount, $impact.AircraftCfgCount
            } else {
                "Estimated impact: {0} package(s)." -f $impact.PackageCount
            }
            $msg  = ("No packages are ticked. This will {0} pushback in EVERY add-on under`n{1}`n`n{2}`n`n" +
                     "If you only want to affect specific packages (e.g. fsltl-traffic-base or AIG*), " +
                     "tick them in the Packages list first.`n`nContinue anyway?") -f $verb, $folder, $impactLine
            $res = [System.Windows.MessageBox]::Show(
                $msg, 'Addon Pushback Manager — no package filter selected', 'OKCancel', 'Warning')
            if ($res -ne 'OK') { return }
        }
    }

    Reset-ResultsPane
    $script:isRunning = $true
    Update-ActionButtonsEnabled
    $ctl.btnCancel.Visibility   = 'Visible'
    $ctl.prgProgress.IsIndeterminate = $true
    Set-Status ("Running {0} against {1} (Scope: {2}) …" -f $Action, $folder, $scopeText)

    # Cancellation handle (shared object with .Value flipped from UI).
    $cancelHolder = [pscustomobject]@{ Value = $false }
    # Shared progress holder. The runspace writes to .Processed; the
    # UI's DispatcherTimer reads it. Plain hashtable + synchronized
    # wrapper so reads/writes don't tear.
    $progressHolder = [hashtable]::Synchronized(@{ Processed = 0 })
    $logPath      = $script:LogPathDefault
    $overwriteBak = [bool]$ctl.chkOverwriteBak.IsChecked
    $simLabel     = Get-EffectiveSimLabel

    # --- Runspace ---
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    # NB: Do NOT pass scriptblocks from this session state into the
    # runspace. A scriptblock captures its origin session state, and
    # when the runspace later closes while still holding that
    # reference, PowerShell throws "Global scope cannot be removed."
    # Instead, we publish progress via a shared synchronized hashtable
    # and let the DispatcherTimer pull it on the UI thread.
    $rs.SessionStateProxy.SetVariable('EnginePath',     (Join-Path $PSScriptRoot 'Pushback.Engine.psm1'))
    $rs.SessionStateProxy.SetVariable('Folder',         $folder)
    $rs.SessionStateProxy.SetVariable('Action',         $Action)
    $rs.SessionStateProxy.SetVariable('LogPath',        $logPath)
    $rs.SessionStateProxy.SetVariable('Overwrite',      $overwriteBak)
    $rs.SessionStateProxy.SetVariable('Cancel',         $cancelHolder)
    $rs.SessionStateProxy.SetVariable('ProgressHolder', $progressHolder)
    $rs.SessionStateProxy.SetVariable('SimLabel',       $simLabel)
    $rs.SessionStateProxy.SetVariable('PackageFilter',  $packageFilter)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        Import-Module $EnginePath -Force
        # Build the progress callback INSIDE this runspace so it has no
        # cross-session-state closure to a foreign scope.
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
                -PackageFilter $PackageFilter `
                -OverwriteExistingBackups:$Overwrite
            return @{ Ok = $true; Run = $r }
        } catch {
            return @{ Ok = $false; ErrorId = $_.FullyQualifiedErrorId; Message = $_.Exception.Message }
        }
    })

    $handle = $ps.BeginInvoke()

    $script:currentRun = [pscustomobject]@{
        Runspace       = $rs
        PowerShell     = $ps
        Handle         = $handle
        CancelFlag     = $cancelHolder
        ProgressHolder = $progressHolder
        LogPath        = $logPath
        Action         = $Action
        ScopeText      = $scopeText
    }

    # Poll completion AND progress via a DispatcherTimer on the UI
    # thread so we never block and Cancel remains responsive.
    #
    # IMPORTANT: stash the timer in script scope. The Add_Tick
    # scriptblock looks up free variables LAZILY (no closure), so a
    # function-local $timer would be $null by the time the tick fires
    # — calling $timer.Stop() would then throw "You cannot call a
    # method on a null-valued expression".
    if ($script:pollTimer) { try { $script:pollTimer.Stop() } catch { } }
    $script:pollTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:pollTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:pollTimer.Add_Tick({
        Invoke-UiSafely -Tag 'DispatcherTimer.Tick' -Action {
            if ($null -eq $script:currentRun) {
                if ($script:pollTimer) { $script:pollTimer.Stop() }
                return
            }
            # Update progress display.
            $proc = [int]$script:currentRun.ProgressHolder.Processed
            if ($proc -gt 0) {
                $ctl.prgProgress.IsIndeterminate = $false
                $ctl.prgProgress.Maximum = [Math]::Max($proc, 1)
                $ctl.prgProgress.Value   = $proc
                Set-Status ("Processed {0} files…" -f $proc)
            }
            if ($script:currentRun.Handle.IsCompleted) {
                $script:pollTimer.Stop()
                Complete-EngineAction
            }
        }
    })
    $script:pollTimer.Start()
}

function Complete-EngineAction {
    Invoke-UiSafely -Tag 'Complete-EngineAction' -Action {
        if (-not $script:currentRun) { return }

        $ps     = $script:currentRun.PowerShell
        $h      = $script:currentRun.Handle
        $action = $script:currentRun.Action
        $scope  = $script:currentRun.ScopeText

        $outcome = $null
        try {
            $results = $ps.EndInvoke($h)
            Write-DiagLog "EndInvoke OK: returned $($results.Count) item(s)"
            if ($results.Count -gt 0) { $outcome = $results[0] }
        } catch {
            Write-DiagLog -Message 'EndInvoke threw' -ErrorRecord $_
            $outcome = @{ Ok = $false; ErrorId = 'GuiHost.RunspaceFailure'; Message = $_.Exception.Message }
        } finally {
            try { $ps.Dispose() } catch { Write-DiagLog -Message 'ps.Dispose failed' -ErrorRecord $_ }
            try { $script:currentRun.Runspace.Close()   } catch { Write-DiagLog -Message 'rs.Close failed'   -ErrorRecord $_ }
            try { $script:currentRun.Runspace.Dispose() } catch { Write-DiagLog -Message 'rs.Dispose failed' -ErrorRecord $_ }
        }

        $script:currentRun = $null
        $script:isRunning  = $false
        $ctl.btnCancel.Visibility        = 'Collapsed'
        $ctl.prgProgress.IsIndeterminate = $false
        Update-ActionButtonsEnabled

        if ($null -eq $outcome) {
            Set-Status 'Run produced no result.'
            return
        }

        if (-not $outcome.Ok) {
            if ($outcome.ErrorId -like 'PushbackEngine.BackupCollision*') {
                Set-Status 'Backup files already exist — see dialog.'
                [System.Windows.MessageBox]::Show(
                    "Some .bak files already exist under the target folder.`n`nTick 'Overwrite existing .bak files' under Advanced to proceed, or move/delete the existing .bak files first.",
                    'Existing backups found', 'OK', 'Warning') | Out-Null
            } else {
                Set-Status "Run failed: $($outcome.Message)"
                [System.Windows.MessageBox]::Show(
                    $outcome.Message, 'Addon Pushback Manager — error', 'OK', 'Error') | Out-Null
            }
            return
        }

        $run = $outcome.Run
        if ($null -eq $run) {
            Write-DiagLog 'outcome.Ok was true but outcome.Run was null'
            Set-Status 'Run completed but returned no data.'
            return
        }
        $script:lastLogPath = $run.LogPath
        Populate-ResultsFromRun -Run $run

        $verb = if ($run.CancelledByUser) { 'Cancelled' } else { 'Done' }
        Set-Status ("{0}. {1} ({2}): Changed={3} WouldChange={4} Unchanged={5} Errors={6}." -f `
            $verb, $action, $scope, $run.Counts.Changed, $run.Counts.WouldChange, $run.Counts.Unchanged, $run.Counts.Errors)
    }
}

# ---------------------------------------------------------------------------
# Browse… (manual folder override)
# ---------------------------------------------------------------------------
function Invoke-BrowseFolder {
    $picked = $null
    # Use WinForms FolderBrowserDialog for maximum cross-version
    # compatibility (PS 5.1 has no Microsoft.Win32.OpenFolderDialog).
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select your MSFS Community folder'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -eq 'OK') { $picked = $dlg.SelectedPath }
    $dlg.Dispose()

    if (-not $picked) { return }

    if (Test-PushbackCommunityFolder -Path $picked) {
        $script:customFolder = $picked
        $ctl.txtCommunityFolder.Text = $picked
        $ctl.cmbSim.SelectedIndex = -1
        Set-Status "Using custom folder: $picked"
        Refresh-PackageList
    } else {
        [System.Windows.MessageBox]::Show(
            "The selected folder doesn't contain any aircraft.cfg files.`n`n$picked",
            'Addon Pushback Manager', 'OK', 'Warning') | Out-Null
    }

    Update-ActionButtonsEnabled
}

# ---------------------------------------------------------------------------
# Wire events
# ---------------------------------------------------------------------------
$ctl.cmbSim.Add_SelectionChanged({
    $sim = Get-SelectedSim
    if ($null -eq $sim) {
        # No sim picked (e.g. both detected, user hasn't chosen yet, or
        # the user just browsed to a custom folder).
        $ctl.txtCommunityFolder.Text = if ($script:customFolder) { $script:customFolder } else { '' }
    } else {
        # Only Detected sims are ever added to the dropdown, so any
        # selection here is actionable.
        $script:customFolder = $null
        $ctl.txtCommunityFolder.Text = $sim.CommunityFolder
        Set-Status "Selected $($sim.DisplayName)."
        Reset-ResultsPane
    }
    Refresh-PackageList
    Update-ActionButtonsEnabled
})

$ctl.btnBrowse.Add_Click({ Invoke-BrowseFolder })

$ctl.btnDryRun.Add_Click({  Start-EngineAction -Action DryRun })
$ctl.btnDisable.Add_Click({ Start-EngineAction -Action DisablePushback })
$ctl.btnEnable.Add_Click({  Start-EngineAction -Action EnablePushback })
$ctl.btnRestore.Add_Click({ Start-EngineAction -Action RestoreBackups })

$ctl.btnPkgRefresh.Add_Click({ Refresh-PackageList })
$ctl.btnPkgSelectAll.Add_Click({
    $key = Get-PackageSelectionKey
    if ($key -and $script:packageNamesByKey.ContainsKey($key)) {
        foreach ($n in $script:packageNamesByKey[$key]) { $script:packagePickByKey[$key][$n] = $true }
        Render-PackageChecklist
    }
})
$ctl.btnPkgClear.Add_Click({
    $key = Get-PackageSelectionKey
    if ($key -and $script:packageNamesByKey.ContainsKey($key)) {
        foreach ($n in $script:packageNamesByKey[$key]) { $script:packagePickByKey[$key][$n] = $false }
        Render-PackageChecklist
    }
})
$ctl.btnPkgPresetAIG.Add_Click({ Select-PackagesByPattern -Pattern 'AIG*' })
$ctl.btnPkgPresetFSLTL.Add_Click({ Select-PackagesByPattern -Pattern 'fsltl-traffic-base' })
$ctl.btnScopeAcknowledge.Add_Click({
    $script:allScopeRiskAcknowledged = $true
    Set-Status 'All-packages risk acknowledged for this session. Disable/Enable unlocked when no package filter is selected.'
    Update-PackageScopeSummary
})
$ctl.btnPkgSearchClear.Add_Click({
    $ctl.txtPkgSearch.Text = ''
    Set-PackageSearchPlaceholder
    Render-PackageChecklist
})
$ctl.txtPkgSearch.Add_GotFocus({
    if ($ctl.txtPkgSearch.Text -eq $script:pkgSearchPlaceholder) {
        $ctl.txtPkgSearch.Text = ''
        $ctl.txtPkgSearch.Foreground = 'Black'
    }
})
$ctl.txtPkgSearch.Add_LostFocus({ Set-PackageSearchPlaceholder })
$ctl.txtPkgSearch.Add_TextChanged({
    if ($ctl.txtPkgSearch.Text -eq $script:pkgSearchPlaceholder) { return }
    $ctl.txtPkgSearch.Foreground = 'Black'
    Render-PackageChecklist
})

$ctl.btnCancel.Add_Click({
    if ($script:currentRun) {
        $script:currentRun.CancelFlag.Value = $true
        Set-Status 'Cancelling…'
    }
})

$ctl.btnOpenLog.Add_Click({
    $path = if ($script:lastLogPath) { $script:lastLogPath } else { $script:LogPathDefault }
    if (Test-Path -LiteralPath $path) {
        Start-Process -FilePath $path
    } else {
        [System.Windows.MessageBox]::Show(
            "No log yet — run an action first.`n`nExpected at:`n$path",
            'Addon Pushback Manager', 'OK', 'Information') | Out-Null
    }
})

$window.Add_Closing({
    if ($script:isRunning) {
        $res = [System.Windows.MessageBox]::Show(
            'A run is in progress. Cancel and quit?',
            'Addon Pushback Manager', 'OKCancel', 'Question')
        if ($res -ne 'OK') {
            $_.Cancel = $true
            return
        }
        if ($script:currentRun) { $script:currentRun.CancelFlag.Value = $true }
    }
})

# Initial state
Refresh-Detection
Set-PackageSearchPlaceholder
Refresh-PackageList
if ($script:IsDebugBuild) {
    # Preselect dry-run focus in debug builds (FR-019).
    $ctl.btnDryRun.Focus() | Out-Null
}

# Hook Dispatcher's unhandled exception so we capture WPF event-handler
# crashes that would otherwise just tear down ShowDialog with a vague
# "You cannot call a method on a null-valued expression."
$window.Dispatcher.add_UnhandledException({
    param($s, $e)
    Write-DiagLog -Message "Dispatcher.UnhandledException: $($e.Exception.Message)`r`n$($e.Exception.StackTrace)"
    try {
        [System.Windows.MessageBox]::Show(
            "An unhandled UI error occurred:`n`n$($e.Exception.Message)`n`nSee $script:diagLogPath",
            'Addon Pushback Manager — internal error', 'OK', 'Error') | Out-Null
    } catch { }
    $e.Handled = $true
})

Write-DiagLog 'GUI starting'
try {
    [void]$window.ShowDialog()
} catch {
    Write-DiagLog -Message 'ShowDialog threw' -ErrorRecord $_
    throw
}
Write-DiagLog 'GUI exited normally'
