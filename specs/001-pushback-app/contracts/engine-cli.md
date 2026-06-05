# Contract: Engine CLI / Module Surface

**Module**: `src/Pushback.Engine.psm1` · **Consumers**: `pushback.ps1` (CLI
entry), `src/Pushback.Gui.ps1` (WPF GUI), `tests/Pushback.Engine.Tests.ps1`.

This contract is **stable** in the sense that any breaking change requires
a constitution amendment per Principle II (test impact) and Principle III
(log/UX impact).

## Exported functions

### `Invoke-PushbackEngine`

The single entry point for all four user actions. The GUI calls this on a
background Runspace; `pushback.ps1` calls it directly.

```powershell
function Invoke-PushbackEngine {
    [CmdletBinding()]
    [OutputType([pscustomobject])] # shape: RunResult (see data-model.md)
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string] $CommunityFolder,

        [Parameter(Mandatory)]
        [ValidateSet('DisablePushback','EnablePushback','DryRun','RestoreBackups')]
        [string] $Action,

        [string] $TargetLineOn  = 'PUSHBACK = 1',
        [string] $TargetLineOff = 'PUSHBACK = 0',

        [string] $LogPath = (Join-Path $env:LOCALAPPDATA 'Pushback\pushback.log'),

        [switch] $OverwriteExistingBackups,

        [ref]         $CancelFlag       = $null,   # [ref][bool]
        [scriptblock] $ProgressCallback = $null    # receives ($processed, $total, $entry)
    )
}
```

#### Behaviour by `Action`

| Action | Reads | Writes | Backups | Counts populated |
|---|---|---|---|---|
| `DisablePushback` | each `aircraft.cfg` once | replaces `TargetLineOn` → `TargetLineOff` | `.bak` before any write | `Changed`, `Unchanged`, `Errors` |
| `EnablePushback`  | each `aircraft.cfg` once | replaces `TargetLineOff` → `TargetLineOn` | `.bak` before any write | `Changed`, `Unchanged`, `Errors` |
| `DryRun`          | each `aircraft.cfg` once | nothing except the log | none | `WouldChange`, `Unchanged`, `Errors` |
| `RestoreBackups`  | each `*.cfg.bak` once | overwrites sibling `aircraft.cfg` with the `.bak` contents | none created (existing `.bak` is kept after restore) | `Changed`, `Unchanged`, `Errors` |

#### Pre-conditions

- `CommunityFolder` MUST be an existing directory.
- For `DisablePushback` / `EnablePushback`: when at least one
  `aircraft.cfg.bak` exists in the tree and `-OverwriteExistingBackups` is
  **not** present, the function MUST throw a terminating error
  `PushbackEngine.BackupCollision` before writing any file. (Implements
  Principle II + FR-016.)

#### Post-conditions

- Returns exactly one `RunResult` object (see [data-model.md](../data-model.md)).
- The log file at `LogPath` MUST contain the start marker, exactly one
  entry per file processed, and the finish marker (per
  [log-format.md](log-format.md)).
- The number of files modified equals `Counts.Changed` exactly.
- If `$CancelFlag.Value -eq $true` is observed between two files, the
  function MUST stop, set `RunResult.CancelledByUser = $true`, write the
  finish marker, and return normally (no partial-file writes).

#### Error model

- **Validation errors** (bad `CommunityFolder`, backup collision without
  opt-in) → terminating error with a `FullyQualifiedErrorId` of
  `PushbackEngine.<Kind>`.
- **Per-file errors** (locked file, I/O error, encoding) → caught, logged
  as `ERROR: <reason>`, counted in `Counts.Errors`, processing continues.
  A single locked file MUST NOT abort the run (spec Edge Cases + SC-005).

#### Performance contract

- Enumeration MUST stream:
  `Get-ChildItem -Recurse -File -Filter aircraft.cfg | ForEach-Object`. No
  intermediate array materialisation.
- Each file MUST be read at most once and written at most once per call.
- Log writes MUST use `Add-Content -Encoding utf8` (or the equivalent
  append-mode call) — never `Set-Content` of the cumulative log.

---

### `Get-SimulatorInstallation` *(re-exported from `Pushback.SimDetect.psm1`)*

```powershell
function Get-SimulatorInstallation {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])] # shape: SimulatorInstallation[]
    param(
        [string] $LocalAppData = $env:LOCALAPPDATA
    )
}
```

- Returns exactly **two** records (one per known sim), in this order:
  `MSFS2020`, `MSFS2024`. Order is part of the contract because the GUI
  binds to indexes.
- A sim that is not installed yields a record with `Status = NotInstalled`,
  not `$null`. Callers can filter with `Where-Object Status -eq 'Detected'`.
- `$LocalAppData` is overridable to enable test fixtures pointing at
  `tests/fixtures/`.

---

### `Test-PushbackCommunityFolder`

```powershell
function Test-PushbackCommunityFolder {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Path)
}
```

Returns `$true` if `Path` is an existing directory containing at least one
`aircraft.cfg` somewhere below it (used by the GUI's manual-Browse flow,
US4 / FR-010). Returns `$false` otherwise. Does not write anywhere and
does not throw on missing paths.

---

## Non-exported helpers (informative)

The module also defines internal helpers; these are **not** part of the
contract and may change without a version bump:

- `ConvertTo-NormalizedPath`
- `Get-AircraftConfigState`
- `Write-LogEntry`
- `Invoke-FileLineReplace`

If a test directly exercises one of these, the test file MUST `Import-Module`
the `.psm1` and call them — they are not made public.

---

## CLI entry: `pushback.ps1`

The repository-root `pushback.ps1` becomes a thin wrapper that imports the
engine module and forwards its parameters. The legacy `$dryRun = $false`
variable at the top of the file is replaced by an explicit
`-Action DryRun` switch so the behaviour is no longer a global mutable.

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CommunityFolder,
    [ValidateSet('DisablePushback','EnablePushback','DryRun','RestoreBackups')]
    [string] $Action = 'DryRun',                # safe default per Principle III
    [string] $LogPath,
    [switch] $OverwriteExistingBackups
)
```

Invocation example (replaces the old "edit the script and run" workflow):

```powershell
.\pushback.ps1 -CommunityFolder 'C:\MSFS\Community' -Action DisablePushback
```

The CLI is preserved primarily for power users and CI smoke tests. The
default action is `DryRun` so accidentally running the script with no
arguments never mutates files.
