# Feature Specification: Pushback App

**Feature Branch**: `001-pushback-app`

**Created**: 2026-06-05

**Status**: Draft

**Input**: User description: "Build an application on top of the PowerShell script. First optimize the PowerShell script and avoid hardcoded values where possible. Second, the script should be enhanced to find the Community folder automatically for MSFS and MSFS 2024 (MSFS 2020 location: `C:\Users\%USERNAME%\AppData\Local\Packages\Microsoft.FlightSimulator_8wekyb3d8bbwe\LocalCache\UserCfg.opt`; MSFS 2024 location: `C:\Users\%USERNAME%\AppData\Local\Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt`). The Community folder value is assigned to the parameter `InstalledPackagesPath` (for example: `InstalledPackagesPath \"C:\\MSFS\"`). Third, create an easy way to use the tool for people without PowerShell knowledge — chosen approach: a native WPF GUI driven by PowerShell, and when both sims are detected the user is prompted to pick one."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Toggle pushback for one detected sim via the GUI (Priority: P1)

A flight-sim user installs an FSLTL traffic update and discovers every parked AI
aircraft has its pushback flag set, causing visual clutter on the ramp. They
download Pushback App, double-click the launcher, see their Community folder
auto-detected and pre-selected, click **Disable pushback**, watch a progress bar
finish, and read a summary like "Changed: 412 files. Unchanged: 3. Errors: 0".
They close the app and the next time they fly the ramp looks correct.

**Why this priority**: This is the entire reason the tool exists. Without it,
nothing else in the app provides user value. It also covers the most common
real-world case: one sim installed.

**Independent Test**: With only one MSFS version installed and the
`UserCfg.opt` file populated with an `InstalledPackagesPath`, launching the
app and clicking **Disable pushback** must produce the same on-disk result as
running the current `pushback.ps1` against the same folder, and the GUI
summary counts must match the log entries.

**Acceptance Scenarios**:

1. **Given** only MSFS 2024 is installed and its `UserCfg.opt` contains a
   valid `InstalledPackagesPath`, **When** the user launches the app, **Then**
   the detected sim ("MSFS 2024") and resolved Community folder path are
   displayed before any action is taken, and the action buttons are enabled.
2. **Given** the sim and folder are detected, **When** the user clicks
   **Disable pushback** and confirms the action, **Then** every
   `aircraft.cfg` under the Community folder containing `PUSHBACK = 1` is
   rewritten to `PUSHBACK = 0`, a `.bak` is created for each modified file,
   and the GUI shows counts for `Changed`, `Unchanged`, and `Errors` that
   match the log.
3. **Given** an operation just completed, **When** the user clicks
   **Enable pushback**, **Then** the inverse change is applied to the same
   file set with the same backup and reporting behavior.

---

### User Story 2 - Choose which sim to target when both are installed (Priority: P1)

A user has both MSFS 2020 and MSFS 2024 installed side-by-side, each with its
own Community folder. When they launch the app, both sims are detected and
the user is presented with a clear choice ("Which sim do you want to modify?
MSFS 2020 / MSFS 2024") before any action button is enabled. They pick one,
and from then on the session operates only on that sim's Community folder.

**Why this priority**: Same priority as US1 because the user explicitly
called out this case as required behavior, and silently picking the wrong sim
would mutate hundreds of files in the wrong installation — a serious user
harm.

**Independent Test**: On a machine (or simulated environment) where both
`UserCfg.opt` files exist and resolve to two different paths, launching the
app must surface a chooser. Selecting one sim and running an action must
modify only that sim's Community folder; the other folder's files must remain
byte-identical (verified via hash before/after).

**Acceptance Scenarios**:

1. **Given** both MSFS 2020 and MSFS 2024 are detected with distinct
   Community folders, **When** the app launches, **Then** the action buttons
   are disabled until the user has explicitly selected one sim from the
   chooser.
2. **Given** the user selects "MSFS 2020", **When** they run **Disable
   pushback**, **Then** only files under the MSFS 2020 Community folder are
   modified and the MSFS 2024 folder is untouched.
3. **Given** the user wants to switch sims after an operation, **When** they
   re-open the chooser and pick the other sim, **Then** subsequent actions
   target the newly chosen folder without restarting the app.

---

### User Story 3 - Dry-run preview before any change (Priority: P1)

Before committing to changing hundreds of files, a cautious user clicks
**Dry-run preview**. The app walks the same files it would in a real run but
writes nothing to disk. The GUI shows the same counts (`Would change`,
`Unchanged`, `Errors`) plus a scrollable list of file paths in each
category, so the user can sanity-check the impact before clicking the real
action.

**Why this priority**: Mandated by constitution Principle II (Testing
Standards — NON-NEGOTIABLE). A behavior-changing tool aimed at non-technical
users must give them a safe preview, and this is also how QA verifies any
release.

**Independent Test**: After a dry-run, the modification timestamps and
contents of every file under the target Community folder must be identical
to their pre-run state, while the GUI must still report accurate counts and
the log file must contain one `WOULD CHANGE` / `NO CHANGE` / `ERROR` entry
per file processed.

**Acceptance Scenarios**:

1. **Given** a target sim is selected, **When** the user clicks **Dry-run
   preview**, **Then** no file under the Community folder is modified and no
   `.bak` files are created.
2. **Given** a dry-run has just completed, **When** the user inspects the
   GUI results pane, **Then** they can see the count of `Would change`,
   `Unchanged`, and `Errors`, and can expand each category to see the
   per-file list.
3. **Given** the user is satisfied with the preview, **When** they click
   **Disable pushback** (or **Enable pushback**), **Then** the real run
   processes the same files and the final counts match the dry-run counts
   (allowing for differences only if files changed on disk between the two
   runs).

---

### User Story 4 - Manual folder override when auto-detection fails (Priority: P2)

A user has installed MSFS to a non-default location, has a Steam installation
that the Microsoft Store `UserCfg.opt` files don't cover, or moved their
Community folder to a junction on a different drive. When auto-detection
fails or returns a path that doesn't exist, the GUI shows the failure
clearly and offers a **Browse…** button so the user can point at their
actual Community folder. The app validates the chosen folder before enabling
any action.

**Why this priority**: Important but not blocking — most users will have a
standard install. Users with non-standard setups already understand they
have a non-standard setup and tolerate one extra step.

**Independent Test**: With both `UserCfg.opt` files absent (or their
`InstalledPackagesPath` pointing at a non-existent path), launching the app
must surface an actionable error and a working **Browse…** picker.
Selecting a valid folder must enable the action buttons; selecting an
invalid folder (no `aircraft.cfg` files anywhere underneath) must keep them
disabled and explain why.

**Acceptance Scenarios**:

1. **Given** neither `UserCfg.opt` file exists, **When** the app launches,
   **Then** the user sees a message such as "No MSFS installation detected.
   Click Browse… to select your Community folder manually." and the
   **Browse…** button is the only enabled control besides Quit.
2. **Given** the user picks a folder via **Browse…** that contains at least
   one `aircraft.cfg` somewhere underneath, **When** validation completes,
   **Then** the action buttons are enabled and the chosen path is displayed.
3. **Given** the user picks a folder that contains no `aircraft.cfg` files,
   **When** validation completes, **Then** the action buttons remain
   disabled and an explanation is shown.

---

### User Story 5 - View results, log, and undo via restored backups (Priority: P3)

After any real run, the user wants to (a) see what happened in detail and
(b) be able to revert if they don't like the result. The GUI provides an
**Open log** button that reveals the log file in Explorer and a **Restore
backups** action that walks the same folder and restores every `aircraft.cfg`
from its sibling `aircraft.cfg.bak`, with a confirmation prompt and a
summary at the end.

**Why this priority**: A nice-to-have safety net. The `.bak` files are
already produced by the core flow (US1), so this story only adds discovery
and a one-click restore.

**Independent Test**: After running US1 to disable pushback, clicking
**Restore backups** and confirming must leave every `aircraft.cfg` byte-
identical to its pre-US1 state, and the `.bak` files must be removed (or
kept, per the chosen policy — see Assumptions).

**Acceptance Scenarios**:

1. **Given** a successful real run produced `.bak` files, **When** the user
   clicks **Open log**, **Then** the configured log file opens in the user's
   default text viewer.
2. **Given** `.bak` files exist alongside `aircraft.cfg` files, **When** the
   user clicks **Restore backups** and confirms, **Then** each `aircraft.cfg`
   is overwritten with the content of its `.bak`, and the summary reports
   the number of files restored.

---

### Edge Cases

- **MSFS is currently running**: `aircraft.cfg` may be open with a write
  lock. Affected files must be reported as `ERROR` with a clear remediation
  message ("Close MSFS and try again"). One locked file must not abort the
  whole run.
- **`UserCfg.opt` exists but `InstalledPackagesPath` is missing,
  commented out, or points to a non-existent path**: treat as "not
  detected" for that sim and surface the manual override path (US4).
- **`InstalledPackagesPath` value contains spaces, quotes, mixed quoting,
  trailing slashes, or environment variables**: the value must be parsed
  robustly and normalised to an absolute filesystem path before use.
- **Community folder is on a slow / network / OneDrive-synced drive**: the
  GUI must remain responsive (work happens off the UI thread) and show
  progress; the 30-second performance target (Principle IV) is only
  guaranteed on local SSDs.
- **A previous run left `.bak` files behind**: the new run must not silently
  overwrite them. Per constitution Principle II, overwriting an existing
  `.bak` requires an explicit user opt-in.
- **User clicks an action twice quickly**: the second click must be
  ignored while the first is still running; cancellation must be possible.
- **Very large Community folder (10 000+ aircraft)**: the GUI must show
  progress and remain cancellable; memory use must stay bounded (Principle
  IV — streaming enumeration).
- **Symbolic links / junctions / reparse points** inside the Community
  folder: enumeration must follow them where MSFS itself would, but must not
  loop infinitely on cycles.
- **Read-only files**: must be reported as `ERROR` (with reason), not
  silently skipped and not silently chmod'd.
- **App launched without a UI session (e.g. SSH / remote PowerShell)**: the
  GUI cannot render; the app must fail with a clear message rather than
  crash. (Headless / CLI mode is out of scope for v1 — see Assumptions.)

## Requirements *(mandatory)*

### Functional Requirements

**Core script optimisation (point 1 of user request)**

- **FR-001**: The underlying engine MUST expose all currently-hardcoded
  values (target filename, search line, replacement line, log path,
  Community folder path, dry-run default, backup behaviour) as named,
  documented parameters with safe defaults, in line with constitution
  Principle I.
- **FR-002**: The engine MUST be invocable both from the GUI and directly
  from a PowerShell prompt, so that automation users retain a scriptable
  surface.
- **FR-003**: The engine MUST stream file enumeration (no full-list
  materialisation) and MUST read and write each target file at most once
  per run, in line with constitution Principle IV.

**Sim and Community-folder detection (point 2 of user request)**

- **FR-004**: The system MUST attempt to locate the MSFS 2020 user
  configuration at `%LOCALAPPDATA%\Packages\Microsoft.FlightSimulator_8wekyb3d8bbwe\LocalCache\UserCfg.opt`.
- **FR-005**: The system MUST attempt to locate the MSFS 2024 user
  configuration at `%LOCALAPPDATA%\Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt`.
- **FR-006**: For each `UserCfg.opt` found, the system MUST parse the
  `InstalledPackagesPath` value, accepting quoted and unquoted forms (e.g.
  `InstalledPackagesPath "C:\MSFS"` and `InstalledPackagesPath C:\MSFS`),
  and MUST normalise the result to an absolute filesystem path with any
  surrounding whitespace and trailing slash removed.
- **FR-007**: The Community folder for a given sim is defined as
  `<InstalledPackagesPath>\Community`. The system MUST treat detection as
  successful only when that resolved folder exists on disk.
- **FR-008**: When **both** MSFS 2020 and MSFS 2024 are detected, the GUI
  MUST require the user to pick exactly one sim before enabling any action
  button; no default selection that could trigger accidental mutation is
  allowed.
- **FR-009**: When **only one** sim is detected, the GUI MUST pre-select it
  and display the resolved Community folder, while still requiring the user
  to click an explicit action button before any change is made.
- **FR-010**: When **no** sim is detected, the GUI MUST display an
  actionable message and expose a manual folder-picker (US4) instead of
  silently failing.

**GUI for non-technical users (point 3 of user request — option B)**

- **FR-011**: The application MUST present a native graphical window with,
  at minimum: a sim/folder display area, a sim chooser (visible when
  applicable), four primary actions (**Disable pushback**, **Enable
  pushback**, **Dry-run preview**, **Restore backups**), a progress
  indicator, a results summary, and access to the log.
- **FR-012**: The application MUST be launchable by double-clicking a
  single file from File Explorer, without the user opening a terminal,
  setting an execution policy by hand, or typing any command. A shim
  launcher that handles execution-policy bypass is acceptable.
- **FR-013**: Every action button MUST require an explicit user click on
  the action; no destructive action may be initiated by application
  startup, by selecting a sim, or by opening the log.
- **FR-014**: While a long-running action executes, the GUI MUST remain
  responsive (no frozen window), MUST show progress, and MUST expose a
  **Cancel** control. Cancellation MUST leave the filesystem in a
  self-consistent state (no half-rewritten files).
- **FR-015**: After every action the GUI MUST display a results summary
  containing at least the count of `Changed` (or `Would change` in dry-run),
  `Unchanged`, and `Errors`, and MUST allow the user to expand each
  category to see the per-file list.

**Safety, logging, and backups**

- **FR-016**: Every real (non-dry-run) action that modifies a file MUST
  first copy that file to a sibling `.bak`. The system MUST refuse to
  overwrite an existing `.bak` without an explicit user opt-in surfaced in
  the GUI, in line with constitution Principle II.
- **FR-017**: The system MUST write a UTF-8 log file beginning with
  `--- Script started: <ISO timestamp> ---` and ending with
  `--- Script finished: <ISO timestamp> ---`, containing exactly one
  entry per file processed using the state tags `CHANGED`, `WOULD CHANGE`,
  `NO CHANGE`, or `ERROR: <reason>`, per constitution Principle III.
- **FR-018**: Dry-run mode MUST perform full discovery and diff logic but
  MUST NOT write to any file other than the log.
- **FR-019**: The GUI MUST default to dry-run for any pre-release / debug
  build of the app, in line with constitution Principle III ("Default
  values MUST be safe"). Release builds MAY default to interactive choice.
- **FR-020**: The application MUST NOT make any network calls, in line
  with constitution Operational Constraints ("No telemetry").
- **FR-021**: The application MUST refuse to operate on a Community folder
  path that resolves outside the user's explicitly detected or
  user-selected location (no silent fallback to `C:\` or `%USERPROFILE%`).
- **FR-022**: Error messages presented to the user MUST identify the file,
  the operation that failed, and a remediation hint (e.g. "Close MSFS and
  re-run"), in line with constitution Principle III.

### Key Entities

- **Simulator installation**: A detected MSFS version. Attributes: display
  name ("MSFS 2020" or "MSFS 2024"), source `UserCfg.opt` path,
  `InstalledPackagesPath` value as parsed, resolved Community folder path,
  detection status (detected / not detected / detected-but-invalid).
- **Aircraft config file**: A discovered `aircraft.cfg` under a Community
  folder. Attributes: full path, current pushback state (on / off /
  neither), backup-exists flag.
- **Run result**: The outcome of a single user-initiated action.
  Attributes: action type (disable / enable / dry-run / restore), target
  sim, target Community folder, counts (`changed`, `unchanged`, `errors`),
  per-file list with state tag, start/end timestamps, log file path.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A first-time user who has never used PowerShell can go from
  downloading the release ZIP to a successful **Dry-run preview** result
  in **under 2 minutes** on a standard installation, without consulting any
  external documentation beyond a one-page README.
- **SC-002**: With one MSFS version installed on a typical workstation
  (SSD, Community folder of up to 5 000 aircraft), a dry-run completes in
  **under 30 seconds** and a real run completes in **under 60 seconds**,
  satisfying constitution Principle IV.
- **SC-003**: When both sims are installed, **100 %** of test runs that
  target one sim leave the other sim's Community folder byte-identical
  (verified via folder hash).
- **SC-004**: Across a representative test corpus of 500 aircraft.cfg
  files, the counts shown in the GUI summary match the log entries with
  **0 discrepancies**.
- **SC-005**: When MSFS is running and a subset of files is locked, the
  application reports each locked file as `ERROR` with a remediation hint,
  finishes processing the remaining files, and does not crash — measured
  by a manual test with at least one locked file present.
- **SC-006**: The GUI remains responsive (the window can be moved and the
  **Cancel** button reacts within 1 second) throughout a run on a
  Community folder containing **at least 10 000 aircraft.cfg files**.
- **SC-007**: All five user stories pass their independent tests on a
  clean machine running each of: Windows PowerShell 5.1 and PowerShell
  7.x on Windows 10 and Windows 11.

## Assumptions

- **Platform**: Windows only (Windows 10 and 11). MSFS is Windows-only, so
  cross-platform support is out of scope.
- **PowerShell**: The host machine has either Windows PowerShell 5.1
  (preinstalled on Windows 10/11) or PowerShell 7.x. No PowerShell Gallery
  modules or third-party binaries are required, per constitution
  Operational Constraints.
- **Distribution**: The app is distributed as a ZIP containing the
  PowerShell scripts and a `.cmd` shim launcher that handles execution-
  policy bypass on first run. A compiled `.exe` is explicitly out of
  scope for v1 (option C was not chosen).
- **Headless / CLI mode**: Out of scope for v1. Running the GUI executable
  in a non-interactive session must fail gracefully but a separate
  headless entry point is not part of this feature. The underlying engine
  remains scriptable for power users (FR-002).
- **Steam / non–Microsoft-Store installs**: The two `UserCfg.opt`
  locations listed in the user request cover Microsoft Store and Game
  Pass installations. Steam installs of MSFS write to the same locations
  (verified industry behaviour); if a user has a non-standard install the
  manual override (US4) is the supported path.
- **Backup retention policy**: After a successful **Restore backups**
  action, `.bak` files are **kept** so the user can re-restore if needed.
  Cleanup is a separate, explicit action (not in v1 scope).
- **Target line format**: The current script matches the literal line
  `PUSHBACK = 1`. This spec assumes that exact format is sufficient for v1
  (matches FSLTL output). Whitespace or casing variants are not in scope
  unless a real-world failure surfaces them.
- **Sim chooser persistence**: The chosen sim is remembered only for the
  current session. The app does not persist a "preferred sim" across
  launches in v1.
- **Telemetry / analytics**: None, per constitution.
- **Localization**: English-only for v1.
