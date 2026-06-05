# Phase 0 Research: Pushback App

**Feature**: [spec.md](spec.md) · **Plan**: [plan.md](plan.md) · **Date**: 2026-06-05

This document resolves the open technical questions surfaced by the plan's
Technical Context. Every entry follows: **Decision → Rationale →
Alternatives considered**.

The user has already constrained two macro decisions (no need to research):

- **Language**: PowerShell only.
- **UI framework**: native WPF, loaded from XAML by PowerShell.

No `NEEDS CLARIFICATION` markers remained in `plan.md` at the time of
writing, so this document focuses on the **how**, not the **what**.

---

## 1. How to host a WPF window inside PowerShell with zero Gallery dependencies

**Decision**: Load WPF from the assemblies that ship with Windows and the
.NET Framework on every supported OS, then parse `MainWindow.xaml` via
`[System.Windows.Markup.XamlReader]::Load(...)`:

```powershell
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
[xml]$xaml = Get-Content -Raw -LiteralPath $xamlPath
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)
```

Named controls are pulled with `$window.FindName('btnDisable')`.

**Rationale**:
- All four assemblies are part of the in-box Windows .NET install and are
  reachable from both Windows PowerShell 5.1 and PowerShell 7.x (which
  runs on .NET 8 with Windows Desktop runtime included in the standard
  Windows install).
- Keeps the constitution's "no Gallery modules, no third-party binaries"
  rule intact.
- `XamlReader.Load` keeps markup in a separate `.xaml` file, which keeps
  designer/preview tooling (e.g. the WPF designer in Visual Studio) usable
  without changing the PowerShell side.

**Alternatives considered**:
- **Windows Forms** — older, simpler API, but the spec requires modern UX
  (progress bar, responsive resize, expandable per-file lists). WPF gives
  data binding and `ItemsControl` cheaply.
- **`Show-Command` or `Out-GridView`** — too primitive; no buttons,
  progress, or expandable result panes.
- **PowerShell Pro Tools / WPK / PoshGUI generated code** — adds a
  third-party dependency or proprietary tooling; rejected by constitution
  Operational Constraints.
- **Compiling a C# WPF app and shelling out** — rejected by user
  constraint ("PowerShell and native WPF GUI only").

---

## 2. How to keep the WPF UI responsive while the engine walks thousands of files

**Decision**: Run the engine on a single background **Runspace** created
with `[runspacefactory]::CreateRunspace()` (apartment state STA, shared
session state so we can share the engine module). Marshal progress and
completion callbacks back to the UI thread via
`$window.Dispatcher.Invoke({...})`. Provide a `[ref]$cancel` flag the
engine polls between files for cooperative cancellation.

**Rationale**:
- A Runspace is in-process — single `pwsh.exe`, single memory footprint,
  module state shared by reference — which is what the constitution's
  Principle IV ("Performance & Resource Efficiency") asks for.
- `Dispatcher.Invoke` is the WPF-sanctioned way to update UI from a
  non-UI thread; without it, touching any control raises
  `InvalidOperationException`.
- A `[ref]$cancel` boolean polled per-file is the cheapest possible
  cancellation signal and lets the engine guarantee FR-014 ("Cancellation
  MUST leave the filesystem in a self-consistent state") because each
  per-file step is atomic (backup → write).

**Alternatives considered**:
- **`Start-Job`** — spawns a child `pwsh.exe`. Doubles memory, slower
  startup, harder progress plumbing (serialised through job streams). The
  Complexity Tracking row in `plan.md` documents this explicitly.
- **`Start-ThreadJob`** — would work, but it requires the `ThreadJob`
  module, which is preinstalled on PS 7 but not on every PS 5.1 install
  (it's only preinstalled from Windows 10 1809+ via WMF 5.1 updates).
  Using a raw Runspace removes any version-dependency.
- **Running the engine on the UI thread with periodic
  `DoEvents`-style pumping** — WPF has no clean `DoEvents`; this freezes
  perceptibly and breaks Cancel responsiveness (FR-014, SC-006).

---

## 3. How to robustly parse `InstalledPackagesPath` out of `UserCfg.opt`

**Decision**: Read `UserCfg.opt` as UTF-8 text, ignore blank and `;`-
prefixed comment lines, then match the first non-comment line whose first
token equals `InstalledPackagesPath` using this regex:

```regex
^\s*InstalledPackagesPath\s+(?:"([^"]*)"|(\S.*?))\s*$
```

Capture group 1 (quoted) or group 2 (unquoted) yields the raw value. Then
normalise:

1. Trim surrounding whitespace.
2. Strip a single trailing `\` if present.
3. Expand environment variables with
   `[System.Environment]::ExpandEnvironmentVariables(...)`.
4. Resolve to an absolute path with `[System.IO.Path]::GetFullPath(...)`.

The Community folder is then `Join-Path $resolved 'Community'`. Detection
is **successful only if** that joined folder exists and is a directory.

**Rationale**:
- Real-world `UserCfg.opt` files from both MSFS 2020 and MSFS 2024 use
  one key per line in a `Key Value` or `Key "Value"` format. The above
  regex tolerates both forms, surrounding whitespace, and ignores
  commented lines.
- Spec edge case explicitly calls out spaces, quotes, mixed quoting,
  trailing slashes, and environment variables — all handled by the four
  normalisation steps.
- Refusing to declare detection successful unless the folder exists
  satisfies FR-007 and prevents the "InstalledPackagesPath points at a
  non-existent path" edge case from silently succeeding into FR-021's
  "no silent fallback" prohibition.

**Alternatives considered**:
- **`ConvertFrom-StringData`** — assumes `Key=Value` and doesn't handle
  the space-separated `Key "Value"` form. Rejected.
- **Calling out to an INI parser module** — would be a Gallery
  dependency. Rejected by constitution.
- **Splitting on whitespace and taking the rest of the line** — works for
  unquoted values, but corrupts values that contain spaces (e.g.
  `C:\Program Files\MSFS`). Rejected.

---

## 4. Where to default the log file path

**Decision**: Default log path is
`%LOCALAPPDATA%\Pushback\pushback.log`. The directory is created on demand
with `New-Item -ItemType Directory -Force`. Both the engine module and the
GUI accept a `-LogPath` parameter that overrides the default.

**Rationale**:
- `%LOCALAPPDATA%` is per-user, writable without elevation, and the
  conventional location for application data on Windows.
- The constitution requires the log path to be configurable and to default
  to a non-elevation location — both conditions met.
- Original script wrote to `c:\development\log.txt`, which only works on
  the original author's machine and would crash on a clean install.

**Alternatives considered**:
- **Repository directory** — fails for end users who install to
  `Program Files` or similar read-only locations.
- **`%TEMP%`** — gets garbage-collected and makes the **Open log** button
  (US5) frequently land on a deleted file.
- **`%USERPROFILE%\Documents\Pushback\`** — visible to the user but
  pollutes Documents; LocalAppData is the conventional choice.

---

## 5. How to launch the GUI by double-click without an execution-policy prompt

**Decision**: Ship `launcher/Pushback.cmd`:

```cmd
@echo off
set "PWSH=pwsh.exe"
where %PWSH% >nul 2>nul || set "PWSH=powershell.exe"
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\Pushback.Gui.ps1" %*
```

The user double-clicks `Pushback.cmd`. The shim prefers PowerShell 7 (`pwsh.exe`)
when on `PATH`, falls back to Windows PowerShell 5.1 (`powershell.exe`,
guaranteed preinstalled).

**Rationale**:
- A `.ps1` file is not double-clickable by default (it opens in Notepad)
  and would be blocked by the default `Restricted` execution policy on
  many machines. A `.cmd` shim is the lowest-friction Windows-native
  workaround.
- `-NoProfile` skips slow user profile loading and avoids surprises from
  the user's `$PROFILE` modifying the engine module.
- `-ExecutionPolicy Bypass` is **scoped to this invocation only** (it
  does not persist for the user or machine), which matches the
  constitution's "no telemetry, no surprises" posture.
- `-File` (vs. `-Command`) keeps the script blockable by Windows
  SmartScreen / Defender in the same way any double-clicked script would
  be, with no extra elevation needed.

**Alternatives considered**:
- **A `.lnk` shortcut** — works but requires per-user setup and breaks if
  the user moves the folder.
- **A signed `.ps1`** — would solve execution-policy concerns but
  requires a code-signing certificate (a runtime/build dependency the
  constitution forbids without justification).
- **Packaging as `.exe` via `ps2exe`** — explicitly out of scope by user
  decision; option C was not chosen.

---

## 6. How to support both Windows PowerShell 5.1 and PowerShell 7.x with one codebase

**Decision**: Target the PowerShell 5.1 language level (no `?.`,
`??`, `using namespace`, or pipeline chain operators). Use cross-version
APIs throughout (`[System.IO.Path]`, `[System.Environment]`,
`Get-ChildItem`, `Set-Content -Encoding utf8`). Smoke-test on both shells
before every release.

The one observable difference — `Set-Content -Encoding utf8` writes a BOM
on PS 5.1 and no BOM on PS 7 — does not affect functional correctness for
either log file consumers (text viewers) or `aircraft.cfg` consumers
(MSFS reads ASCII-compatible UTF-8 fine). We accept the difference rather
than work around it.

**Rationale**:
- The constitution mandates support for both. Lowest common denominator
  is the most maintainable strategy for a < 1 500 LOC project.

**Alternatives considered**:
- **`Out-File -Encoding utf8NoBOM`** to normalise encoding — only exists
  on PS 6+. Would require a `$PSVersionTable.PSVersion.Major -ge 6` branch
  on every log write. Rejected as not worth the complexity.

---

## 7. Test approach (Pester) without violating "no Gallery modules"

**Decision**: Use **Pester**. Pester 3.x ships with Windows PowerShell 5.1
out of the box on Windows 10+; Pester 5.x ships with PowerShell 7. Tests
are written to the Pester 5 syntax (`Describe / Context / It / Should`)
because that syntax is also accepted by Pester 3 for the basic assertions
we use. If a fresh Windows install lacks Pester, the test runner script
prints an instruction rather than auto-installing — staying compliant with
the constitution.

**Rationale**:
- Pester counts as "shipped with Windows" for the purposes of this repo's
  constitution (same status as WPF assemblies).
- Pester is the only realistic option for `.psm1` unit tests; the
  alternative is hand-rolled assertion code, which is strictly worse.

**Alternatives considered**:
- **Hand-rolled `if`-based test harness** — fewer dependencies but loses
  test-discovery, parallelism, and failure reporting. Not worth it.
- **No unit tests, only the dry-run smoke script** — violates the spirit
  of Principle II for the pure functions (parser, line-rewriter,
  counters) that are trivially unit-testable.

---

## Summary of open questions remaining

**None.** Every `NEEDS CLARIFICATION`-class question raised by the plan
template has been answered above. Ready to proceed to Phase 1.
