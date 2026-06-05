# Contract: GUI Actions

**Producer**: `src/Pushback.Gui.ps1` + `src/MainWindow.xaml`.
**Consumer**: `src/Pushback.Engine.psm1` (via `Invoke-PushbackEngine`).

This contract documents what each visible GUI control does, in terms the
spec's user stories and FRs can be traced to. The XAML names listed
below are normative — they are the public surface the back-end script
binds to.

## Window-level

| Concern | Behaviour |
|---|---|
| Window title | `Pushback` |
| Initial size | 720 × 520 logical pixels, resizable, min 600 × 420. |
| Theme | System default (no custom skin) to stay dependency-free. |
| Startup actions | Run `Get-SimulatorInstallation`, populate the sim list, log nothing yet. |
| Shutdown | If a run is in progress when the user closes the window, prompt "Cancel current run and quit?". Closing without a running task is silent. |

## Controls (XAML names → behaviour)

### Sim chooser — `cmbSim`

A `ComboBox` (or two `RadioButton`s, implementation choice) bound to the
list of `SimulatorInstallation` records returned by detection.

| Detection state | Visible UI | Action buttons |
|---|---|---|
| Both sims `Detected` | Both shown, **no selection** | Disabled until the user picks one (FR-008) |
| One sim `Detected`, other `NotInstalled` / `Misconfigured` | Detected sim pre-selected, other shown greyed with tooltip = `StatusDetail` | Enabled (FR-009) |
| Neither sim `Detected` | Combo hidden, message banner shown, only `btnBrowse` is enabled (FR-010) |

### Folder display — `txtCommunityFolder`

Read-only `TextBox` showing the absolute path that will be processed.
Updates whenever sim selection changes or `btnBrowse` succeeds.

### Browse… — `btnBrowse`

Opens a folder picker (`Microsoft.Win32.OpenFolderDialog` on PS 7 +
.NET 8; `System.Windows.Forms.FolderBrowserDialog` on PS 5.1 — both
shipped with Windows). On success, the chosen path is validated by
`Test-PushbackCommunityFolder`. Valid → `txtCommunityFolder` updates,
action buttons enable. Invalid → message displayed, buttons stay
disabled (FR-010 + US4).

### Disable pushback — `btnDisable`

Calls `Invoke-PushbackEngine -Action DisablePushback` on the background
Runspace. Maps to spec **US1 / FR-011 / FR-013**.

### Enable pushback — `btnEnable`

Same as above, `Action = EnablePushback`. Maps to **US1 acceptance #3**.

### Dry-run preview — `btnDryRun`

Same as above, `Action = DryRun`. Maps to **US3 / FR-018**. This button
MUST be visually distinct from the destructive actions (e.g. a different
accent colour, or grouped under a "Preview" header) so users learn to
reach for it first.

### Restore backups — `btnRestore`

Pops a confirmation: "Restore every `aircraft.cfg` from its `.bak` under
`<folder>`?  This will undo your last Disable/Enable run." On confirm,
calls `Invoke-PushbackEngine -Action RestoreBackups`. Maps to **US5**.

### Cancel — `btnCancel`

Visible only while a run is in progress. Sets `$cancelFlag.Value = $true`.
The engine polls the flag between files and stops cleanly (FR-014).

### Open log — `btnOpenLog`

Calls `Start-Process -FilePath $RunResult.LogPath`. If no run has
completed yet, opens the default log path if it exists; otherwise shows
"No log yet — run an action first."

### Progress bar — `prgProgress`

Bound `Value` / `Maximum` updated from the engine's `ProgressCallback`
via `Dispatcher.Invoke`. Indeterminate until the total file count is
known (which happens after the first streaming pass starts — the engine
sends `total = -1` on the first callback if the count is not yet
finalised).

### Results pane — `lstResults`

`TabControl` or `Expander` group with four sections:
**Changed / Would change / Unchanged / Errors**. Each section shows the
count in its header and an `ItemsControl` of file paths inside. Empty
sections are still visible (count = 0) so users can verify the run
processed something.

### Overwrite-existing-backups opt-in — `chkOverwriteBak`

A `CheckBox` placed under an `Expander` labelled "Advanced". Default
unchecked. When unchecked and the engine throws
`PushbackEngine.BackupCollision`, the GUI shows a dialog: "Some `.bak`
files already exist. Tick 'Overwrite existing backups' under Advanced to
proceed, or move/delete the existing `.bak` files first."

This satisfies the FR-016 "explicit opt-in" requirement without making
the common case noisier.

## Action-button traceability

| FR / US | Control | Engine call |
|---|---|---|
| US1, FR-011 | `btnDisable` | `Invoke-PushbackEngine -Action DisablePushback` |
| US1 #3 | `btnEnable` | `Invoke-PushbackEngine -Action EnablePushback` |
| US3, FR-018 | `btnDryRun` | `Invoke-PushbackEngine -Action DryRun` |
| US5 | `btnRestore` | `Invoke-PushbackEngine -Action RestoreBackups` |
| US4, FR-010 | `btnBrowse` | (validation only — `Test-PushbackCommunityFolder`) |
| FR-014 | `btnCancel` | sets `$cancelFlag.Value = $true` |
| US5 | `btnOpenLog` | `Start-Process` |

## Threading rules

1. **UI thread**: handles XAML, dialogs, control updates.
2. **Runspace thread**: runs `Invoke-PushbackEngine`. Never touches WPF
   controls directly.
3. **Bridge**: the engine's `ProgressCallback` and completion handler
   marshal via `$window.Dispatcher.Invoke({ ... })` to update controls.

Violating any of these three rules causes WPF to throw
`InvalidOperationException: The calling thread cannot access this
object…` — that's the contract enforcement mechanism.

## Out of scope for v1

- Saving a "preferred sim" across launches (Assumption in spec.md).
- Localisation (Assumption in spec.md).
- Diff preview of an individual `aircraft.cfg` change (could be added in
  a future story without changing this contract).
- Auto-update / version-check UI (would require a network call → forbidden).
