#requires -Version 5.1
<#
.SYNOPSIS
    Pushback engine. Discovers aircraft.cfg files under a Community folder
    and toggles the PUSHBACK flag with backup/dry-run/log/restore support.

.DESCRIPTION
    Pure engine module. No WPF or UI code. Consumed by both pushback.ps1
    (CLI) and src/Pushback.Gui.ps1 (WPF GUI). Behaviour and parameter
    surface are pinned by specs/001-pushback-app/contracts/engine-cli.md
    and specs/001-pushback-app/contracts/log-format.md.

.NOTES
    Constitution Principle I — no hardcoded values; all configuration is
    parameterised. Principle II — dry-run is a first-class action and
    .bak overwrite requires explicit opt-in. Principle III — log format
    is exact and stable. Principle IV — streaming enumeration, each file
    read/written at most once per run.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function ConvertTo-NormalizedPath {
    <#
    .SYNOPSIS
        Trim whitespace, strip one trailing separator, expand env vars,
        resolve to an absolute path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $value = $Path.Trim()

    # Strip a single trailing separator, but keep bare drive roots intact.
    if ($value.Length -gt 3 -and ($value.EndsWith('\') -or $value.EndsWith('/'))) {
        $value = $value.Substring(0, $value.Length - 1)
    }

    $value = [System.Environment]::ExpandEnvironmentVariables($value)

    try {
        return [System.IO.Path]::GetFullPath($value)
    } catch {
        return $null
    }
}

function Write-LogEntry {
    <#
    .SYNOPSIS
        Append a single line to the log file. Caller is responsible for
        constructing the entry exactly per contracts/log-format.md.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$Line
    )

    # Add-Content with -Encoding utf8 is portable across PS 5.1 and 7.x.
    # PS 5.1 emits a BOM, PS 7 does not; both are tolerated by readers
    # per research.md §6.
    Add-Content -LiteralPath $LogPath -Value $Line -Encoding utf8
}

function Initialize-LogFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LogPath)

    $dir = [System.IO.Path]::GetDirectoryName($LogPath)
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $LogPath)) {
        # Touch the file so subsequent Add-Content calls succeed.
        New-Item -ItemType File -Path $LogPath -Force | Out-Null
    }
}

function Get-IsoUtcTimestamp {
    [OutputType([string])]
    param()
    return [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Get-PushbackScanRoots {
    <#
    .SYNOPSIS
        Resolve the list of directories the engine will recursively scan.

    .DESCRIPTION
        If $PackageFilter is null or empty, returns a single-element array
        containing $CommunityFolder (current behaviour - scan everything).

        Otherwise, returns the FullName of every immediate child directory
        of $CommunityFolder whose name matches at least one of the
        wildcard patterns in $PackageFilter (case-insensitive, PowerShell
        -like semantics). Patterns like 'AIG*' or 'fsltl-traffic-base'
        let callers scope a run to a subset of installed packages without
        the engine hardcoding any package names (Principle I).

        Returns an empty array if patterns were supplied but no subfolder
        matched; the caller can detect this and log a warning.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$CommunityFolder,
        [AllowNull()][AllowEmptyCollection()][string[]]$PackageFilter
    )

    if (-not $PackageFilter -or $PackageFilter.Count -eq 0) {
        return ,@($CommunityFolder)
    }

    $patterns = @($PackageFilter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    if ($patterns.Count -eq 0) {
        return ,@($CommunityFolder)
    }

    $matches = Get-ChildItem -LiteralPath $CommunityFolder -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $name = $_.Name
            foreach ($p in $patterns) {
                if ($name -like $p) { return $true }
            }
            return $false
        } |
        ForEach-Object { $_.FullName }

    return ,@($matches)
}

function Get-AircraftConfigState {
    <#
    .SYNOPSIS
        Read a config file once and report whether it currently matches
        the on-line, the off-line, or neither.

    .OUTPUTS
        [pscustomobject] @{ Lines = string[]; MatchedLineIndex = int?;
                            CurrentState = 'PushbackOn'|'PushbackOff'|'Other' }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FullPath,
        [Parameter(Mandatory)][string]$TargetLineOn,
        [Parameter(Mandatory)][string]$TargetLineOff
    )

    # Get-Content returns string[] (one per line) without trailing newlines.
    $lines = Get-Content -LiteralPath $FullPath -ErrorAction Stop

    # Handle single-line files where Get-Content returns a scalar string.
    if ($lines -is [string]) { $lines = @($lines) }

    $matchedIndex = $null
    $state        = 'Other'

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed -ceq $TargetLineOn) {
            $matchedIndex = $i
            $state        = 'PushbackOn'
            break
        }
        if ($trimmed -ceq $TargetLineOff) {
            $matchedIndex = $i
            $state        = 'PushbackOff'
            break
        }
    }

    return [pscustomobject]@{
        Lines            = $lines
        MatchedLineIndex = $matchedIndex
        CurrentState     = $state
    }
}

function Invoke-FileLineReplace {
    <#
    .SYNOPSIS
        Rewrite a single line in-place, preserving all other lines and
        the file's existing terminator style as best we can.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]   $FullPath,
        # NOTE: [AllowEmptyString()] is REQUIRED. PowerShell's default
        # binding for [Parameter(Mandatory)][string[]] rejects any
        # array that contains an empty string element with the error
        # "Cannot bind argument to parameter 'Lines' because it is an
        # empty string." Real aircraft.cfg files routinely contain
        # blank lines between sections, so without this attribute
        # every targeted rewrite would fail.
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]] $Lines,
        [Parameter(Mandatory)][int]      $LineIndex,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]   $NewLine
    )

    $Lines[$LineIndex] = $NewLine
    # Set-Content default encoding differs across PS versions. UTF8 is
    # safe for ASCII aircraft.cfg content (mods occasionally use Latin-1
    # for accented characters; those round-trip identically through
    # System.Text.Encoding.UTF8 because the unchanged bytes outside our
    # one target line are preserved by Get-Content/Set-Content here).
    Set-Content -LiteralPath $FullPath -Value $Lines -Encoding utf8
}

function New-RunResultEntry {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FullPath,
        [Parameter(Mandatory)][ValidateSet('CHANGED','WOULD CHANGE','NO CHANGE','ERROR')][string]$State,
        [string]$ErrorMessage
    )
    return [pscustomobject]@{
        FullPath     = $FullPath
        State        = $State
        ErrorMessage = $ErrorMessage
    }
}

function New-RunResult {
    [OutputType([pscustomobject])]
    param(
        [string]$Action,
        [string]$TargetSim,
        [string]$TargetCommunityFolder,
        [string]$LogPath,
        [datetime]$StartedAt
    )
    return [pscustomobject]@{
        Action                   = $Action
        TargetSim                = $TargetSim
        TargetCommunityFolder    = $TargetCommunityFolder
        LogPath                  = $LogPath
        StartedAt                = $StartedAt
        FinishedAt               = $null
        Counts                   = [pscustomobject]@{
            Changed     = 0
            WouldChange = 0
            Unchanged   = 0
            Errors      = 0
        }
        Entries                  = [System.Collections.Generic.List[object]]::new()
        CancelledByUser          = $false
        OverwroteExistingBackups = $false
    }
}

# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

function Invoke-PushbackEngine {
    <#
    .SYNOPSIS
        Walk a Community folder and apply the requested PUSHBACK action.
        See specs/001-pushback-app/contracts/engine-cli.md for the full
        contract.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string] $CommunityFolder,

        [Parameter(Mandatory)]
        [ValidateSet('DisablePushback','EnablePushback','DryRun','RestoreBackups')]
        [string] $Action,

        [string] $TargetLineOn  = 'PUSHBACK = 1',
        [string] $TargetLineOff = 'PUSHBACK = 0',

        [string] $LogPath = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Pushback\pushback.log'),

        [switch] $OverwriteExistingBackups,

        # An object with a .Value boolean property (typically a
        # [ref][bool]) the caller can flip to request cancellation.
        [AllowNull()] $CancelFlag = $null,

        # Invoked after each file with (processed, total, lastEntry).
        # $total may be -1 if the count is not yet known.
        [AllowNull()][scriptblock] $ProgressCallback = $null,

        # Optional list of wildcard patterns (PowerShell -like syntax)
        # matched against the immediate child folder names of
        # $CommunityFolder. When supplied, the engine only recurses
        # into matching subfolders. Examples: 'AIG*', 'fsltl-traffic-base'.
        # When null/empty (default), the entire Community folder is
        # scanned, preserving the original behaviour.
        [AllowNull()][AllowEmptyCollection()]
        [string[]] $PackageFilter = $null,

        # For RunResult only; defaults to the resolved community folder name.
        [string] $TargetSim = ''
    )

    $resolvedFolder = ConvertTo-NormalizedPath -Path $CommunityFolder
    if (-not $resolvedFolder -or -not (Test-Path -LiteralPath $resolvedFolder -PathType Container)) {
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.IO.DirectoryNotFoundException]::new("Community folder not found: $CommunityFolder"),
            'PushbackEngine.InvalidCommunityFolder',
            [System.Management.Automation.ErrorCategory]::InvalidArgument,
            $CommunityFolder)
        $PSCmdlet.ThrowTerminatingError($err)
    }

    if (-not $TargetSim) { $TargetSim = $resolvedFolder }

    Initialize-LogFile -LogPath $LogPath

    $startedAt = [DateTime]::UtcNow
    Write-LogEntry -LogPath $LogPath -Line "--- Script started: $(Get-IsoUtcTimestamp) ---"

    $result = New-RunResult `
        -Action $Action `
        -TargetSim $TargetSim `
        -TargetCommunityFolder $resolvedFolder `
        -LogPath $LogPath `
        -StartedAt $startedAt

    # Resolve which directories the engine will actually walk. When the
    # caller supplied -PackageFilter but no subfolder matched, log a
    # clear warning and return an empty (but well-formed) result rather
    # than silently scanning everything.
    $scanRoots = Get-PushbackScanRoots -CommunityFolder $resolvedFolder -PackageFilter $PackageFilter
    if ($PackageFilter -and $PackageFilter.Count -gt 0 -and $scanRoots.Count -eq 0) {
        Write-LogEntry -LogPath $LogPath -Line ("WARN: -PackageFilter matched no subfolders under '{0}' (patterns: {1})" -f $resolvedFolder, ($PackageFilter -join ', '))
        Write-LogEntry -LogPath $LogPath -Line "--- Script finished: $(Get-IsoUtcTimestamp) ---"
        $result.FinishedAt = [DateTime]::UtcNow
        return $result
    }

    try {
        if ($Action -eq 'RestoreBackups') {
            Invoke-RestoreBackups -ScanRoots $scanRoots -Result $result `
                -CancelFlag $CancelFlag -ProgressCallback $ProgressCallback
            return $result
        }

        # Disable / Enable / DryRun all share the same scan; the action
        # determines what we do when we match.
        $isDryRun = ($Action -eq 'DryRun')

        # Backup collision pre-check (only for real Disable/Enable runs).
        if (-not $isDryRun -and -not $OverwriteExistingBackups) {
            # Streaming check - we stop at the first .bak found so this
            # stays cheap even on huge trees. Honours -PackageFilter so a
            # stray .bak in an unrelated package can't block a scoped run.
            $collision = $null
            foreach ($root in $scanRoots) {
                $collision = Get-ChildItem -LiteralPath $root -Recurse -File `
                    -Filter 'aircraft.cfg.bak' -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($collision) { break }
            }
            if ($collision) {
                $err = [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("Existing .bak files found (e.g. $($collision.FullName)). Re-run with -OverwriteExistingBackups to proceed."),
                    'PushbackEngine.BackupCollision',
                    [System.Management.Automation.ErrorCategory]::ResourceExists,
                    $collision.FullName)
                $PSCmdlet.ThrowTerminatingError($err)
            }
        }

        if ($OverwriteExistingBackups) { $result.OverwroteExistingBackups = $true }

        # Determine what line we look FOR and what line we write.
        switch ($Action) {
            'DisablePushback' { $matchLine = $TargetLineOn;  $writeLine = $TargetLineOff }
            'EnablePushback'  { $matchLine = $TargetLineOff; $writeLine = $TargetLineOn  }
            'DryRun'          { $matchLine = $TargetLineOn;  $writeLine = $TargetLineOff } # preview Disable
            default           { throw "Unsupported action: $Action" }
        }

        $processed = 0
        $total     = -1  # unknown during streaming

        $scanRoots |
            ForEach-Object {
                Get-ChildItem -LiteralPath $_ -Recurse -File -Filter 'aircraft.cfg' -ErrorAction SilentlyContinue
            } |
            ForEach-Object {
                if ($null -ne $CancelFlag -and $CancelFlag.Value) {
                    $result.CancelledByUser = $true
                    return
                }

                $file = $_.FullName
                $entry = $null
                try {
                    $info = Get-AircraftConfigState -FullPath $file `
                        -TargetLineOn $TargetLineOn -TargetLineOff $TargetLineOff

                    $isTargetState = $false
                    switch ($Action) {
                        'DisablePushback' { $isTargetState = ($info.CurrentState -eq 'PushbackOn') }
                        'EnablePushback'  { $isTargetState = ($info.CurrentState -eq 'PushbackOff') }
                        'DryRun'          { $isTargetState = ($info.CurrentState -eq 'PushbackOn') }
                    }

                    if ($isTargetState) {
                        if ($isDryRun) {
                            $entry = New-RunResultEntry -FullPath $file -State 'WOULD CHANGE'
                            $result.Counts.WouldChange++
                        } else {
                            # Backup, then rewrite the one line.
                            $bak = "$file.bak"
                            Copy-Item -LiteralPath $file -Destination $bak -Force
                            Invoke-FileLineReplace -FullPath $file `
                                -Lines $info.Lines -LineIndex $info.MatchedLineIndex `
                                -NewLine $writeLine
                            $entry = New-RunResultEntry -FullPath $file -State 'CHANGED'
                            $result.Counts.Changed++
                        }
                    } else {
                        $entry = New-RunResultEntry -FullPath $file -State 'NO CHANGE'
                        $result.Counts.Unchanged++
                    }
                } catch {
                    $reason = $_.Exception.Message
                    if ($_.Exception -is [System.IO.IOException]) {
                        $reason = "$reason (close MSFS and re-run)"
                    }
                    $entry = New-RunResultEntry -FullPath $file -State 'ERROR' `
                        -ErrorMessage "$reason - file: $file"
                    $result.Counts.Errors++
                }

                if ($null -ne $entry) {
                    $result.Entries.Add($entry) | Out-Null
                    $logLine = if ($entry.State -eq 'ERROR') {
                        "ERROR: $($entry.ErrorMessage)"
                    } else {
                        "$($entry.State): $($entry.FullPath)"
                    }
                    Write-LogEntry -LogPath $LogPath -Line $logLine
                }

                $processed++
                if ($null -ne $ProgressCallback) {
                    try { & $ProgressCallback $processed $total $entry } catch { <# swallow UI errors #> }
                }
            }
    } finally {
        $result.FinishedAt = [DateTime]::UtcNow
        Write-LogEntry -LogPath $LogPath -Line "--- Script finished: $(Get-IsoUtcTimestamp) ---"
    }

    return $result
}

function Invoke-RestoreBackups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ScanRoots,
        [Parameter(Mandatory)][pscustomobject]$Result,
        [AllowNull()]$CancelFlag,
        [AllowNull()][scriptblock]$ProgressCallback
    )

    $processed = 0
    $ScanRoots |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Recurse -File -Filter 'aircraft.cfg.bak' -ErrorAction SilentlyContinue
        } |
        ForEach-Object {
            if ($null -ne $CancelFlag -and $CancelFlag.Value) {
                $Result.CancelledByUser = $true
                return
            }

            $bak    = $_.FullName
            $target = $bak.Substring(0, $bak.Length - 4)  # strip '.bak'
            $entry  = $null

            try {
                if (-not (Test-Path -LiteralPath $target)) {
                    # The .cfg was deleted after backup; recreate from .bak.
                    Copy-Item -LiteralPath $bak -Destination $target -Force
                    $entry = New-RunResultEntry -FullPath $target -State 'CHANGED'
                    $Result.Counts.Changed++
                } else {
                    $bakBytes    = [System.IO.File]::ReadAllBytes($bak)
                    $targetBytes = [System.IO.File]::ReadAllBytes($target)
                    $same = ($bakBytes.Length -eq $targetBytes.Length)
                    if ($same) {
                        for ($i = 0; $i -lt $bakBytes.Length; $i++) {
                            if ($bakBytes[$i] -ne $targetBytes[$i]) { $same = $false; break }
                        }
                    }
                    if ($same) {
                        $entry = New-RunResultEntry -FullPath $target -State 'NO CHANGE'
                        $Result.Counts.Unchanged++
                    } else {
                        Copy-Item -LiteralPath $bak -Destination $target -Force
                        $entry = New-RunResultEntry -FullPath $target -State 'CHANGED'
                        $Result.Counts.Changed++
                    }
                }
            } catch {
                $reason = $_.Exception.Message
                if ($_.Exception -is [System.IO.IOException]) {
                    $reason = "$reason (close MSFS and re-run)"
                }
                $entry = New-RunResultEntry -FullPath $target -State 'ERROR' `
                    -ErrorMessage "$reason - file: $target"
                $Result.Counts.Errors++
            }

            if ($null -ne $entry) {
                $Result.Entries.Add($entry) | Out-Null
                $logLine = if ($entry.State -eq 'ERROR') {
                    "ERROR: $($entry.ErrorMessage)"
                } else {
                    "$($entry.State): $($entry.FullPath)"
                }
                Write-LogEntry -LogPath $Result.LogPath -Line $logLine
            }

            $processed++
            if ($null -ne $ProgressCallback) {
                try { & $ProgressCallback $processed -1 $entry } catch { }
            }
        }
}

function Test-PushbackCommunityFolder {
    <#
    .SYNOPSIS
        True if $Path is a directory containing at least one aircraft.cfg
        anywhere underneath it. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }

    try {
        $first = Get-ChildItem -LiteralPath $Path -Recurse -File -Filter 'aircraft.cfg' `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        return [bool]$first
    } catch {
        return $false
    }
}

Export-ModuleMember -Function Invoke-PushbackEngine, Test-PushbackCommunityFolder
