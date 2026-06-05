# Quickstart & Validation Guide: Pushback App

**Feature**: [spec.md](spec.md) · **Plan**: [plan.md](plan.md) ·
**Data model**: [data-model.md](data-model.md) ·
**Contracts**: [contracts/](contracts/)

This document tells a reviewer (or QA, or a future maintainer) **how to
prove the feature works end-to-end** on a clean Windows machine. It is
not an implementation guide — that lives in `tasks.md` (Phase 2).

## Prerequisites

| Requirement | Why |
|---|---|
| Windows 10 (1809+) or Windows 11, x64 | Target platform per [plan.md](plan.md#technical-context). |
| Windows PowerShell 5.1 **or** PowerShell 7.x | Constitution Operational Constraints. Validate on at least one of each per SC-007. |
| Either a real MSFS 2020 / 2024 install **or** the fixture tree under `tests/fixtures/` | Detection + engine targets. |
| Pester (any version) | Optional — only needed for the unit-test step below. Ships with Windows on PS 5.1. |

No PowerShell Gallery modules and no external downloads are required.

## Repository layout (what you'll see)

See [plan.md → Project Structure](plan.md#project-structure) for the
authoritative layout. The validation flows below reference these files
by relative path.

## Validation flow 1 — Smoke test on the fixture tree (no MSFS install needed)

This is the **mandatory PR evidence flow** per constitution Principle II.

```powershell
# From the repository root.
cd C:\Development\pushback

# 1. Run the smoke script. It points the engine at tests/fixtures/Community
#    using a temporary log file and prints the run summary.
.\tests\Run-DryRunSmokeTest.ps1
```

**Expected outcome**:

- Console prints `Processing: <path>` for each fixture `aircraft.cfg`.
- A summary line: `Would change: N · Unchanged: N · Errors: 0`.
- The temporary log file contains the markers and one entry per file (see
  [contracts/log-format.md](contracts/log-format.md)).
- **Zero** files under `tests/fixtures/Community/` have changed modification
  timestamps (proof that dry-run is non-destructive).

If any of those fail, the PR is **not** ready for review.

## Validation flow 2 — Engine CLI on a real Community folder

For users / reviewers who want to validate against a real install. Uses
the contract from [contracts/engine-cli.md](contracts/engine-cli.md).

```powershell
# Dry-run preview against a real folder. Safe — writes nothing except the log.
.\pushback.ps1 `
    -CommunityFolder 'C:\MSFS\Community' `
    -Action DryRun

# After reviewing the log, perform the real change. Creates .bak per file.
.\pushback.ps1 `
    -CommunityFolder 'C:\MSFS\Community' `
    -Action DisablePushback

# Undo: restores every aircraft.cfg from its .bak.
.\pushback.ps1 `
    -CommunityFolder 'C:\MSFS\Community' `
    -Action RestoreBackups
```

**Expected outcome**: each invocation prints a `RunResult` object whose
`Counts` add up to the number of files processed (per the invariant in
[data-model.md → RunResult](data-model.md#3-runresult)).

## Validation flow 3 — GUI end-to-end

```text
1. Open File Explorer in the repository root.
2. Double-click  launcher\Pushback.cmd
3. The Pushback window opens. Expect within 2 seconds:
     - Detection ran (sim list populated).
     - "Community folder" field shows the resolved path.
4. If both sims are detected:
     - Verify all action buttons are disabled.
     - Pick MSFS 2024 in the chooser → action buttons enable.
5. Click "Dry-run preview".
     - Progress bar advances; window stays movable; Cancel is reachable.
     - When done, results pane shows four sections with counts.
6. Click "Open log" → log opens in the default text viewer.
7. Optional: click "Disable pushback".
     - Confirmation dialog (when applicable, e.g. backup collision) appears.
     - On confirm, run executes and summary updates.
8. Click "Restore backups" → confirm → every modified file is restored.
9. Close the window.
```

**Mapping to acceptance scenarios**: this flow exercises US1
(steps 4-7), US2 (step 4), US3 (step 5), US5 (steps 6 + 8). US4 (manual
Browse…) is exercised by temporarily renaming the `UserCfg.opt` files
under `%LOCALAPPDATA%\Packages\` before launch, then using the Browse…
button to point at any folder containing an `aircraft.cfg`.

## Validation flow 4 — Unit tests

```powershell
# From the repository root.
Invoke-Pester -Path .\tests\
```

**Expected outcome**: all `Describe` blocks pass on both PS 5.1 and 7.x.
The suite covers:

- `Pushback.SimDetect.Tests.ps1` — every example in
  [contracts/usercfg-parser.md → Examples](contracts/usercfg-parser.md#examples-with-expected-outcomes)
  has a matching `It` block.
- `Pushback.Engine.Tests.ps1` — line rewrite, counter aggregation,
  dry-run no-write guarantee, backup collision behaviour.

## Validation flow 5 — Performance gate (release-only)

Before every release the PR author runs:

```powershell
Measure-Command {
    .\pushback.ps1 `
        -CommunityFolder 'C:\MSFS\Community' `
        -Action DryRun
} | Select-Object TotalSeconds
```

against the reference dataset (Community folder of ~5 000 aircraft on an
SSD). Result MUST be `< 30 s` per [plan.md →
Performance Goals](plan.md#technical-context) and constitution Principle
IV. A regression > 20 % vs. the previous release MUST be justified in
the PR.

## What passing validation means

A change is considered validated when:

- [ ] Flow 1 (smoke) passes locally.
- [ ] Flow 4 (Pester) passes on at least one of PS 5.1 / 7.x.
- [ ] Flows 2 and 3 have been performed at least once for the change
      being shipped (real Community folder when behaviour touches the
      engine; GUI flow when behaviour touches `Pushback.Gui.ps1` or
      `MainWindow.xaml`).
- [ ] Flow 5 was run for any change that touches enumeration, file I/O,
      or the per-file loop.
- [ ] The PR description links to the log produced by Flow 1 (or Flow 2)
      per constitution Principle II.
