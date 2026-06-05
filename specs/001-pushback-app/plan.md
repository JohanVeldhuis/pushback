# Implementation Plan: Pushback App

**Branch**: `001-pushback-app` | **Date**: 2026-06-05 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from [`/specs/001-pushback-app/spec.md`](spec.md)

## Summary

Turn the existing `pushback.ps1` one-shot script into a small, dependency-free
Windows desktop **application** that any flight-sim user can run without
touching PowerShell. The app:

1. **Optimizes the engine** — moves every hardcoded value into a parameter
   block, splits discovery / transformation / logging / backup into a
   reusable module, and preserves the streaming I/O pattern.
2. **Auto-detects the MSFS 2020 and MSFS 2024 Community folders** by parsing
   the `InstalledPackagesPath` value out of each sim's `UserCfg.opt`, with a
   manual **Browse…** fallback when neither sim is found.
3. **Wraps everything in a native WPF GUI** loaded from XAML via PowerShell's
   built-in `System.Xaml` / `PresentationFramework` assemblies — no external
   modules, no compiled binaries, no installer. A `.cmd` shim bypasses
   execution policy on first launch so the user can just double-click.

User-provided constraint for this plan: **the application is implemented in
PowerShell only and uses native WPF for the GUI** — no C#, no XAML compilers,
no third-party UI frameworks, no PowerShell Gallery modules.

## Technical Context

**Language/Version**: PowerShell — must run on Windows PowerShell 5.1
(preinstalled on Windows 10/11) and PowerShell 7.x on Windows.

**Primary Dependencies**: WPF assemblies shipped with Windows
(`PresentationFramework`, `PresentationCore`, `WindowsBase`, `System.Xaml`)
loaded via `Add-Type -AssemblyName`. No PowerShell Gallery modules. No
external binaries.

**Storage**: Local filesystem only. Inputs: each sim's
`%LOCALAPPDATA%\Packages\<sim-package>\LocalCache\UserCfg.opt` and every
`aircraft.cfg` under the resolved `InstalledPackagesPath\Community`.
Outputs: in-place rewrites of `aircraft.cfg`, sibling `.bak` files, and a
UTF-8 log file (path configurable, default
`%LOCALAPPDATA%\Pushback\pushback.log`).

**Testing**: Manual **dry-run smoke tests** against a fixture tree of
`aircraft.cfg` files (per constitution Principle II — NON-NEGOTIABLE). A
small Pester suite under `tests/` covers the pure functions (UserCfg.opt
parsing, line-rewrite logic, count aggregation). Pester ships with
PowerShell and counts as a built-in, not a Gallery dependency.

**Target Platform**: Windows 10 (1809+) and Windows 11, x64. Both
PowerShell 5.1 and 7.x. WPF requires an interactive desktop session.

**Project Type**: Desktop application (PowerShell script + WPF UI). Single
project layout — no separate backend/frontend split.

**Performance Goals** (per constitution Principle IV and spec SC-002 / SC-006):
- Dry-run pass over the reference dataset: < 30 s on SSD.
- Real run on ≤ 5 000 aircraft: < 60 s.
- GUI remains responsive (Cancel reacts in < 1 s) on ≥ 10 000 aircraft.

**Constraints**:
- Dependency-free at runtime (constitution Operational Constraints).
- No network calls — no telemetry, no auto-update (constitution + FR-020).
- Streaming file enumeration only (Principle IV).
- Must not overwrite an existing `.bak` without explicit user opt-in
  (Principle II + FR-016).
- All long-running work must run off the WPF UI thread (FR-014).

**Scale/Scope**:
- Single user, single machine.
- Typical Community folders: 500–5 000 aircraft; design target 10 000.
- Single executable surface (a `.cmd` launcher + a handful of `.ps1` /
  `.psm1` / `.xaml` files); estimated total < 1 500 LOC of PowerShell.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The repo's constitution defines four principles plus operational
constraints. Each is mapped to the plan below; **no violations require
justification**.

| Principle | How this plan satisfies it |
|---|---|
| **I. Code Quality & Maintainability** | All hardcoded values from `pushback.ps1` move into a `param()` block on `Pushback.Engine.psm1`'s public functions and a single `# --- CONFIGURATION ---` block at the top of the GUI launcher. Full cmdlet names and named parameters throughout. `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'` enabled in the engine module (which is non-trivial). |
| **II. Testing Standards (NON-NEGOTIABLE)** | Dry-run is a first-class GUI action (US3). The engine emits the exact `WOULD CHANGE` / `NO CHANGE` / `ERROR` tags required by the constitution. `.bak` creation is mandatory before any write; overwriting an existing `.bak` requires an explicit GUI opt-in (FR-016). PR template will require dry-run evidence for any behavior-changing diff. |
| **III. User Experience Consistency** | Console (when launched verbosely) keeps the `Processing: <path>` line contract. Log file is UTF-8 with the required `--- Script started/finished ---` markers and one entry per file. GUI defaults to **dry-run** for any pre-release / debug build (FR-019). Error messages name file + operation + remediation (FR-022). |
| **IV. Performance & Resource Efficiency** | `Get-ChildItem … \| ForEach-Object` streaming preserved; never `\| ...` into an array before processing. Each file read once and written at most once per run. Log opened with `-Append` and not held exclusively. Long work runs on a background `Runspace` so the UI thread stays responsive (Principle IV + FR-014). |
| **Operational Constraints (Platform / Deps / Filesystem / Logging / Telemetry)** | Targets PS 5.1 and 7.x explicitly. Zero Gallery modules; only Windows-bundled WPF assemblies. Filesystem scope is whatever the user detected or explicitly picked — no silent `C:\` or `%USERPROFILE%` fallback (FR-021). Log path is configurable and defaults to a non-elevated location. Zero network calls (FR-020). |

**Result**: Constitution Check **PASSES** before Phase 0. Re-check below
after Phase 1.

## Project Structure

### Documentation (this feature)

```text
specs/001-pushback-app/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output (validation/run guide)
├── contracts/           # Phase 1 output
│   ├── engine-cli.md       # Engine module public surface
│   ├── usercfg-parser.md   # UserCfg.opt input format & parsing rules
│   ├── log-format.md       # Exact log line grammar
│   └── gui-actions.md      # GUI button → engine call mapping
├── checklists/
│   └── requirements.md  # Spec quality checklist (already exists)
└── tasks.md             # Phase 2 output (NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
pushback.ps1                # Thin CLI entry — delegates to the engine module.
                            # Preserved for backward compatibility with the
                            # original one-file workflow.

src/
├── Pushback.Engine.psm1    # Pure engine: discovery, parse, transform,
│                           # backup, log, restore. No UI code.
├── Pushback.SimDetect.psm1 # UserCfg.opt discovery + InstalledPackagesPath
│                           # parsing for MSFS 2020 and MSFS 2024.
├── Pushback.Gui.ps1        # WPF host: loads MainWindow.xaml, wires buttons
│                           # to engine calls, runs work on a Runspace.
└── MainWindow.xaml         # Declarative UI layout (XAML).

launcher/
└── Pushback.cmd            # Double-clickable shim. Calls pwsh / powershell
                            # with -ExecutionPolicy Bypass -File ..\src\Pushback.Gui.ps1

tests/
├── fixtures/
│   ├── UserCfg.msfs2020.opt    # Sample with InstalledPackagesPath quoted
│   ├── UserCfg.msfs2024.opt    # Sample with InstalledPackagesPath unquoted
│   ├── UserCfg.malformed.opt   # Missing / commented-out value
│   └── Community/              # Tiny aircraft.cfg tree (3-5 files,
│                               # mixed PUSHBACK=0/1/missing)
├── Pushback.Engine.Tests.ps1   # Pester: line rewrite, counters, dry-run
├── Pushback.SimDetect.Tests.ps1# Pester: UserCfg.opt parser variants
└── Run-DryRunSmokeTest.ps1     # Manual smoke per Principle II — produces
                                # the dry-run log required by PR checklist.
```

**Structure Decision**: Single-project layout. The engine and the GUI are
separated into different files so the engine can be unit-tested in isolation
and reused from `pushback.ps1` (CLI) and `Pushback.Gui.ps1` (WPF) without
duplication. WPF lives entirely in `Pushback.Gui.ps1` + `MainWindow.xaml`
to keep the UI surface inspectable in one place.

## Complexity Tracking

> **No violations to track.** The plan stays inside the constitution's
> "boringly simple PowerShell" envelope: one engine module, one detection
> module, one GUI script, one XAML file, one launcher, one CLI entry. No
> classes, no advanced functions beyond `[CmdletBinding()]`, no background
> jobs (a single Runspace handles UI-thread offload, justified inline below).

| Potential complexity | Why used | Simpler alternative rejected because |
|---|---|---|
| Background **Runspace** for engine execution | FR-014 requires the GUI to stay responsive and cancellable while the engine walks ≥ 10 000 files. | `Start-Job` spawns a separate `pwsh.exe`, doubling memory and complicating progress reporting. Running on the UI thread freezes WPF for tens of seconds. |

