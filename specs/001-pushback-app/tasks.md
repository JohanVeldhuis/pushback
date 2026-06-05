---

description: "Task list for Pushback App feature implementation"
---

# Tasks: Pushback App

**Input**: Design documents from [`/specs/001-pushback-app/`](.)

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: Pester unit tests are MANDATORY for the engine and parser per the constitution (Principle II) — they are real tasks below, not optional.

**Organization**: Tasks are grouped by user story so each story can be implemented, tested, and demoed independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]** = can run in parallel (different files, no dependencies)
- **[Story]** = which user story this task belongs to (US1…US5)
- Paths are repository-root-relative

## Path conventions

Single-project layout per [plan.md → Project Structure](plan.md#project-structure):

- Engine + GUI: `src/`
- Tests + fixtures: `tests/`
- Launcher: `launcher/`
- CLI entry: `pushback.ps1` (repo root)

---

## Phase 1: Setup

**Purpose**: Project scaffolding (directories, ignore files).

- [X] T001 Create directories: `src/`, `tests/`, `tests/fixtures/`, `tests/fixtures/Community/`, `launcher/`
- [X] T002 [P] Create `.gitignore` with PowerShell-appropriate patterns: `*.bak`, `pushback.log`, `tests/fixtures/Community/**/*.bak`, `.vscode/*.log`, `*.tmp`, `*.swp`, `.DS_Store`, `Thumbs.db`

---

## Phase 2: Foundational (Engine + Sim Detection)

**Purpose**: The pure modules every user story depends on. No GUI code in this phase.

**⚠️ CRITICAL**: All user stories block on this phase. None of the engine logic touches WPF; the GUI in Phase 3 will simply call into it.

### Engine module

- [X] T003 Create `src/Pushback.Engine.psm1` skeleton: `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, `Export-ModuleMember` for `Invoke-PushbackEngine`, `Test-PushbackCommunityFolder`, `Get-SimulatorInstallation`
- [X] T004 Implement private helper `ConvertTo-NormalizedPath` in `src/Pushback.Engine.psm1`: trim, strip trailing separator, `ExpandEnvironmentVariables`, `[IO.Path]::GetFullPath`
- [X] T005 Implement private helper `Write-LogEntry` in `src/Pushback.Engine.psm1`: UTF-8 `Add-Content`, ISO-8601 UTC timestamps, exact `--- Script started/finished ---` markers per [contracts/log-format.md](contracts/log-format.md)
- [X] T006 Implement private helper `Get-AircraftConfigState` in `src/Pushback.Engine.psm1`: single-pass read, returns `PushbackOn`/`PushbackOff`/`Other` + matched line index
- [X] T007 Implement private helper `Invoke-FileLineReplace` in `src/Pushback.Engine.psm1`: rewrite exactly one line, preserve every other byte
- [X] T008 Implement public `Invoke-PushbackEngine` in `src/Pushback.Engine.psm1` per [contracts/engine-cli.md](contracts/engine-cli.md): streaming `Get-ChildItem`, dispatch by `Action`, `.bak` creation with collision check (`PushbackEngine.BackupCollision`), per-file error capture into `ERROR:` entries, cancellation polling, `ProgressCallback` invocation, returns `RunResult` `[pscustomobject]`
- [X] T009 Implement public `Test-PushbackCommunityFolder` in `src/Pushback.Engine.psm1`: returns `[bool]`, never throws, validates directory + ≥1 `aircraft.cfg` under it

### Sim detection module

- [X] T010 [P] Create `src/Pushback.SimDetect.psm1` with `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, `Export-ModuleMember -Function Get-SimulatorInstallation`
- [X] T011 [P] Implement `Get-SimulatorInstallation` in `src/Pushback.SimDetect.psm1`: probes both known `UserCfg.opt` paths under `$LocalAppData`, parses with the regex from [contracts/usercfg-parser.md](contracts/usercfg-parser.md), classifies into `Detected`/`NotInstalled`/`Misconfigured`, returns exactly two records in `MSFS2020`, `MSFS2024` order

### Test fixtures

- [X] T012 [P] Create `tests/fixtures/UserCfg.msfs2020.opt` with quoted `InstalledPackagesPath` pointing at `<fixtures>/Community`'s parent
- [X] T013 [P] Create `tests/fixtures/UserCfg.msfs2024.opt` with unquoted `InstalledPackagesPath`
- [X] T014 [P] Create `tests/fixtures/UserCfg.malformed.opt` with the key commented out
- [X] T015 [P] Create `tests/fixtures/Community/` tree containing 4 `aircraft.cfg` files: one with `PUSHBACK = 1`, one with `PUSHBACK = 0`, one with neither line, one with `PUSHBACK = 1` plus a pre-existing `.bak` sibling

**Checkpoint**: Engine and detector can be imported and called from a plain PowerShell prompt; GUI work in Phase 3 can begin.

---

## Phase 3: User Story 1 — Toggle pushback for one detected sim via the GUI (P1) 🎯 MVP

**Goal**: A user with one MSFS install double-clicks the launcher, sees the detected folder, clicks **Disable pushback**, and the engine runs end-to-end.

**Independent Test**: Launch app on a single-sim system → run **Disable pushback** → verify summary counts equal log entries and on-disk result matches a CLI call to the engine with the same args.

- [X] T016 [US1] Create `launcher/Pushback.cmd` shim per [research.md §5](research.md): prefers `pwsh.exe`, falls back to `powershell.exe`, runs with `-NoProfile -ExecutionPolicy Bypass -File`
- [X] T017 [US1] Create `src/MainWindow.xaml` with all controls named in [contracts/gui-actions.md](contracts/gui-actions.md): `cmbSim`, `txtCommunityFolder`, `btnBrowse`, `btnDisable`, `btnEnable`, `btnDryRun`, `btnRestore`, `btnCancel`, `btnOpenLog`, `prgProgress`, `lstResults` (TabControl with four sections), `chkOverwriteBak` under an Advanced expander
- [X] T018 [US1] Create `src/Pushback.Gui.ps1`: load WPF assemblies, `XamlReader.Load` MainWindow.xaml, import both engine modules, run `Get-SimulatorInstallation` on startup, populate `cmbSim` and `txtCommunityFolder`, set initial enabled/disabled button states per detection outcome
- [X] T019 [US1] Wire `btnDisable` + `btnEnable` in `src/Pushback.Gui.ps1`: build `EngineOptions`, spin up background Runspace, call `Invoke-PushbackEngine`, marshal completion back via `$window.Dispatcher.Invoke`, populate `lstResults` and counts. Reject double-clicks while a run is in progress
- [X] T020 [US1] Wire progress reporting in `src/Pushback.Gui.ps1`: `ProgressCallback` updates `prgProgress.Value`/`Maximum` via `Dispatcher.Invoke`
- [X] T021 [US1] Wire `btnCancel` in `src/Pushback.Gui.ps1`: sets `[ref]$cancelFlag.Value = $true`; hides while idle, shows during runs
- [X] T022 [US1] Wire the `PushbackEngine.BackupCollision` error path in `src/Pushback.Gui.ps1`: catch from the Runspace result, show the dialog described in [contracts/gui-actions.md → chkOverwriteBak](contracts/gui-actions.md#overwrite-existing-backups-opt-in--chkoverwritebak), do NOT auto-retry
- [X] T023 [US1] Refactor `pushback.ps1` (repository root) into a thin CLI wrapper per [contracts/engine-cli.md → CLI entry](contracts/engine-cli.md#cli-entry-pushbackps1): `param(-CommunityFolder, -Action, -LogPath, -OverwriteExistingBackups)`, imports `src/Pushback.Engine.psm1`, default `-Action DryRun`

**Checkpoint**: US1 fully functional — single-sim user can run any of the four actions from the GUI. Counts in the summary match log entries (SC-004 invariant).

---

## Phase 4: User Story 2 — Choose which sim to target when both are installed (P1)

**Goal**: When both sims are detected, the user must pick one before any action button is enabled.

**Independent Test**: Configure both `UserCfg.opt` fixtures to point at distinct folders, launch GUI → verify action buttons stay disabled until selection, verify chosen sim alone is mutated.

- [X] T024 [US2] In `src/Pushback.Gui.ps1`, implement two-sim handling: when both `Status -eq 'Detected'`, leave `cmbSim.SelectedIndex = -1` and keep `btnDisable`/`btnEnable`/`btnDryRun`/`btnRestore` disabled until `cmbSim.SelectionChanged` fires with a valid index
- [X] T025 [US2] In `src/Pushback.Gui.ps1`, implement sim-switch mid-session: changing `cmbSim` selection updates `txtCommunityFolder` and resets the results pane (no leftover counts from the previous sim)

**Checkpoint**: US2 acceptance scenarios pass; a run targeting MSFS 2020 leaves the MSFS 2024 fixture folder byte-identical (SC-003).

---

## Phase 5: User Story 3 — Dry-run preview before any change (P1)

**Goal**: User can preview the impact of an action without mutating any file.

**Independent Test**: Run dry-run against the fixture Community tree → no `aircraft.cfg` modification timestamp changes → log contains `WOULD CHANGE` / `NO CHANGE` entries only.

Engine support for `DryRun` is already built in T008. This phase wires the GUI-side affordances and the mandatory smoke harness.

- [X] T026 [US3] In `src/MainWindow.xaml`, give `btnDryRun` a visually distinct style (e.g. accent colour or "Preview" group header) so users learn to reach for it first
- [X] T027 [US3] In `src/Pushback.Gui.ps1`, when the build is debug/pre-release (detect via env var `PUSHBACK_DEBUG=1` or absence of a `RELEASE` marker file), preselect the dry-run button focus on window open, per FR-019
- [X] T028 [US3] Create `tests/Run-DryRunSmokeTest.ps1`: imports the engine, runs `Invoke-PushbackEngine -Action DryRun -CommunityFolder tests/fixtures/Community -LogPath <temp>`, asserts every file mtime is unchanged, prints summary, exits non-zero on any mismatch — this is the mandatory PR evidence script per constitution Principle II

**Checkpoint**: US3 acceptance scenarios pass; smoke script returns 0 and produces a reviewable log.

---

## Phase 6: User Story 4 — Manual folder override when auto-detection fails (P2)

**Goal**: When neither sim is detected (or detection returns invalid), the user can browse to their own Community folder.

**Independent Test**: Point `$LocalAppData` at an empty dir (or rename `UserCfg.opt` files) → launch GUI → only **Browse…** is enabled → pick fixture Community folder → buttons enable.

- [X] T029 [US4] In `src/Pushback.Gui.ps1`, implement the no-sim-detected state: hide/disable `cmbSim`, show a banner message ("No MSFS installation detected. Click Browse… to select your Community folder manually."), enable only `btnBrowse` and `btnOpenLog`
- [X] T030 [US4] In `src/Pushback.Gui.ps1`, implement `btnBrowse` click handler: pick folder picker by PS version (`Microsoft.Win32.OpenFolderDialog` on PS 7 ≥ 8.0; `System.Windows.Forms.FolderBrowserDialog` on PS 5.1), validate result with `Test-PushbackCommunityFolder`, on success update `txtCommunityFolder` + enable action buttons, on failure show inline message and keep buttons disabled
- [X] T031 [US4] In `src/Pushback.Gui.ps1`, ensure that selecting a `Misconfigured` sim from `cmbSim` ALSO presents `btnBrowse` (so the user can recover without restarting)

**Checkpoint**: US4 acceptance scenarios pass.

---

## Phase 7: User Story 5 — View results, log, and undo via restored backups (P3)

**Goal**: User can open the log file and one-click restore from `.bak` siblings.

**Independent Test**: Run **Disable pushback** then **Restore backups** → every `aircraft.cfg` is byte-identical to its pre-run state; `.bak` files are still present (kept, per Assumptions).

Engine support for `RestoreBackups` is already built in T008.

- [X] T032 [US5] In `src/Pushback.Gui.ps1`, wire `btnOpenLog`: `Start-Process -FilePath $script:lastLogPath` (or default log path if no run yet); show friendly message when the file doesn't exist
- [X] T033 [US5] In `src/Pushback.Gui.ps1`, wire `btnRestore`: show confirmation dialog, then call `Invoke-PushbackEngine -Action RestoreBackups` on the Runspace, populate results pane with same invariants as US1

**Checkpoint**: US5 acceptance scenarios pass.

---

## Phase 8: Pester Tests (NON-NEGOTIABLE per constitution)

**Purpose**: Unit-test the pure functions so behaviour changes can't ship unnoticed.

- [X] T034 [P] Create `tests/Pushback.SimDetect.Tests.ps1` covering every example in [contracts/usercfg-parser.md → Examples](contracts/usercfg-parser.md#examples-with-expected-outcomes): quoted-with-spaces-and-trailing-slash, unquoted, env-var expansion, commented-out, mixed-with-other-keys. One `It` block per example.
- [X] T035 [P] Create `tests/Pushback.Engine.Tests.ps1` covering: line-rewrite preserves all other bytes; counter aggregation (`Changed + Unchanged + Errors == Entries.Count`); dry-run mutates no file mtimes; `PushbackEngine.BackupCollision` is thrown without `-OverwriteExistingBackups`; `-OverwriteExistingBackups` overrides; restore makes files byte-identical to pre-run state

---

## Phase 9: Polish & Validation

- [X] T036 Run quickstart Validation Flow 1 ([quickstart.md → Smoke test](quickstart.md#validation-flow-1--smoke-test-on-the-fixture-tree-no-msfs-install-needed)) and capture the resulting log
- [X] T037 Run quickstart Validation Flow 4 ([quickstart.md → Unit tests](quickstart.md#validation-flow-4--unit-tests)) on PowerShell 7.x (PS 5.1 left to release time)
- [X] T038 [P] Verify GUI launches and reaches a usable state via manual smoke (Flow 3, partial — full real-folder runs left to user / release)

---

## Dependencies & Execution Order

```text
Setup (T001-T002)
   │
   ▼
Foundational (T003-T015)
   │
   ├─► US1 (T016-T023)  ──► US2 (T024-T025) ──► US3 (T026-T028) ──┐
   │                                                                ├─► Tests (T034-T035) ──► Polish (T036-T038)
   ├─► US4 (T029-T031)  ─────────────────────────────────────────────┤
   └─► US5 (T032-T033)  ─────────────────────────────────────────────┘
```

US2-US5 each depend on US1 (they all build on `Pushback.Gui.ps1`).

### Parallelisable groups

- T002 can run alongside T001.
- T010-T015 (`SimDetect` module + fixtures) parallel with T003-T009 (`Engine` module) — different files.
- T012-T015 (fixture files) parallel with each other.
- T034-T035 (Pester suites) parallel with each other — different files.

### File-conflict-driven sequencing

All tasks targeting `src/Pushback.Engine.psm1` (T003-T009) MUST run sequentially. All tasks targeting `src/Pushback.Gui.ps1` (T018-T022, T024-T025, T027, T029-T033) MUST run sequentially.

---

## Notes

- `[P]` = different file, no dependency on a sibling task in the same phase.
- Every behaviour-changing task on the engine MUST be followed by re-running `tests/Run-DryRunSmokeTest.ps1` per constitution Principle II.
- The CLI (`pushback.ps1`) is preserved as a regression safety net — if the GUI breaks, the engine is still usable from a prompt (FR-002).

