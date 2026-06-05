<!--
Sync Impact Report
==================
Version change: [none] → 1.0.0 (initial ratification)
Rationale: First formal constitution for the Pushback project. MAJOR version
established because this codifies governance and non-negotiable principles
where none previously existed in machine-actionable form.

Modified principles:
  - [PRINCIPLE_1_NAME] → I. Code Quality & Maintainability
  - [PRINCIPLE_2_NAME] → II. Testing Standards (NON-NEGOTIABLE)
  - [PRINCIPLE_3_NAME] → III. User Experience Consistency
  - [PRINCIPLE_4_NAME] → IV. Performance & Resource Efficiency
  - [PRINCIPLE_5_NAME] → REMOVED (project scope warrants four principles only)

Added sections:
  - Operational Constraints & Safety (replaces SECTION_2)
  - Development Workflow & Quality Gates (replaces SECTION_3)

Removed sections:
  - Fifth principle slot (intentionally omitted; project is a single-purpose
    PowerShell utility and a fifth principle would be filler)

Templates requiring updates:
  - ✅ .specify/templates/plan-template.md — Constitution Check gate is
    generic ("Gates determined based on constitution file") and references
    this file by design; no edits required
  - ✅ .specify/templates/spec-template.md — Success Criteria already
    require measurable, technology-agnostic outcomes; compatible with
    Principle IV
  - ✅ .specify/templates/tasks-template.md — Test tasks remain OPTIONAL
    per template, but Principle II makes dry-run evidence MANDATORY for
    behavior-changing work in this repo; reviewers enforce on PR
  - ✅ .specify/templates/checklist-template.md — generic, no changes
    required

Follow-up TODOs:
  - None. Ratification date set to today (2026-06-05) as this is the first
    formal constitution.
-->

# Pushback Constitution

## Core Principles

### I. Code Quality & Maintainability

All code in this repository MUST be readable by a contributor who has never
seen it before. To enforce this:

- Scripts MUST use full PowerShell cmdlet names (e.g., `Get-ChildItem`, not
  `gci`) and named parameters in any non-trivial invocation.
- Configuration (paths, target strings, replacement values, log locations)
  MUST be declared in a single, clearly-labeled `# --- CONFIGURATION ---`
  block at the top of each script. Hard-coded values scattered through logic
  are prohibited.
- Every script MUST run cleanly under `Set-StrictMode -Version Latest` and
  `$ErrorActionPreference = 'Stop'` once it grows beyond a single linear
  pass. Below that threshold the relaxation MUST be documented in a header
  comment.
- Dead code, commented-out blocks, and `Write-Host` debugging left from
  development MUST be removed before merge. Diagnostic output belongs in
  the log file (see Principle III) or behind an explicit `-Verbose` switch.

**Rationale**: This is a small utility that modifies files on a user's
machine. A contributor must be able to audit the entire behavior in one
sitting; obscurity and drift between configuration and logic directly
increase the risk of corrupting flight-sim installs.

### II. Testing Standards (NON-NEGOTIABLE)

No change that alters file-modification behavior MAY be merged without
evidence that it was exercised in **dry-run mode** against a representative
sample, and that the resulting log was reviewed.

- Every script that mutates files MUST support a dry-run mode (currently
  the `$dryRun` flag) that performs the full discovery and diff logic but
  writes nothing to disk except the log.
- Dry-run output MUST distinguish at least three states per file:
  `WOULD CHANGE`, `NO CHANGE`, and `ERROR` (with the failure reason).
- For any behavior change, the PR description MUST include: the dry-run
  command invoked, the count of files in each state, and a paste or link
  to the relevant log excerpt.
- Backups MUST be created before any destructive write (current `.bak`
  convention), and the script MUST refuse to overwrite an existing `.bak`
  unless an explicit `-Force` switch is passed.

**Rationale**: There is no realistic unit-test harness for a script that
walks a user's MSFS Community folder. Dry-run + log review + automatic
backups are the achievable equivalent of a test suite for this domain,
and they directly protect users from data loss.

### III. User Experience Consistency

The script's only "UI" is its console output and its log file. Both MUST
follow a single, predictable contract:

- The console MUST show one line per file being processed, prefixed with
  `Processing:` and the full path. No other chatter at default verbosity.
- The log file MUST be UTF-8, MUST start with a `--- Script started:
  <ISO timestamp> ---` line, MUST end with a `--- Script finished:
  <ISO timestamp> ---` line, and MUST contain exactly one entry per file
  processed, using the state tags defined in Principle II.
- Default values MUST be safe: `$dryRun` defaults to `$true` for any new
  script or any script whose mutation logic has materially changed in the
  current PR. Flipping to `$false` is a separate, reviewable commit.
- Error messages MUST name the file, the operation that failed, and the
  remediation (e.g., "close MSFS and re-run"). Raw exception dumps alone
  are not acceptable user output.

**Rationale**: Users run this against irreplaceable game data. A
consistent, boring, predictable surface is what lets them trust the tool
and spot anomalies (an unexpected `CHANGED` line, a missing finish marker)
at a glance.

### IV. Performance & Resource Efficiency

The script targets a directory tree that can contain thousands of aircraft
config files. It MUST remain responsive on a typical user workstation:

- A full dry-run pass over the configured `$rootPath` MUST complete in
  under 30 seconds on a system with an SSD and the reference dataset
  documented in `pushback.ps1`. Any change that regresses this beyond 20%
  MUST be justified in the PR.
- File enumeration MUST stream (`Get-ChildItem ... | ForEach-Object`); it
  MUST NOT materialize the full file list into memory before processing.
- File contents MUST be read once per file and rewritten at most once per
  file per run. Repeated `Get-Content`/`Set-Content` round-trips on the
  same file in a single pass are prohibited.
- Log writes MUST use append mode (`-Append`) and MUST NOT re-open the log
  file with exclusive locks that would block a concurrent tail/viewer.

**Rationale**: The script is invoked interactively by end users who expect
near-instant feedback. Memory blowups or pathological I/O patterns on a
large Community folder would make the tool unusable on exactly the
installations that need it most.

## Operational Constraints & Safety

- **Target platform**: Windows PowerShell 5.1 and PowerShell 7+ MUST both
  execute the scripts without modification. Cmdlets and syntax exclusive
  to one are prohibited unless guarded by a version check.
- **External dependencies**: The repository MUST remain dependency-free.
  No PowerShell modules from the Gallery, no .NET assemblies outside the
  BCL, no external binaries.
- **Filesystem scope**: Scripts MUST refuse to run if `$rootPath` resolves
  outside a path the user has explicitly configured. Hard-coded fallbacks
  to `C:\` or `%USERPROFILE%` are prohibited.
- **Logging location**: The log file path MUST be configurable and MUST
  default to a location the script can create without elevation.
- **No telemetry**: The scripts MUST NOT make network calls of any kind.

## Development Workflow & Quality Gates

- **Branching**: Feature work happens on `###-feature-name` branches per
  the Spec Kit convention. Direct commits to `main` are reserved for
  documentation and constitution amendments.
- **Pre-merge checklist** (reviewer MUST verify):
  1. Principle I: script passes `Invoke-ScriptAnalyzer` with no `Error`-
     or `Warning`-severity findings, or each finding is justified in the
     PR.
  2. Principle II: dry-run evidence is present in the PR description for
     any behavior-changing diff.
  3. Principle III: console and log output match the contract above; a
     sample log excerpt is attached when output format changed.
  4. Principle IV: for any change touching enumeration, I/O, or the
     per-file loop, a timing measurement against the reference dataset
     is attached.
- **Constitution Check gate**: The `/speckit.plan` workflow's Constitution
  Check section MUST explicitly map each planned task to the principle(s)
  it touches, or state "no principle impact" with reasoning.
- **Amendment procedure**: Any change to this document requires (a) the
  Sync Impact Report at the top updated, (b) a version bump per the rules
  below, and (c) a separate commit so the amendment is reviewable in
  isolation.
- **Versioning policy**:
  - **MAJOR**: A principle is removed, redefined in a backward-incompatible
    way, or a NON-NEGOTIABLE rule is relaxed.
  - **MINOR**: A new principle or section is added, or existing guidance
    is materially expanded.
  - **PATCH**: Wording, typo, or clarification that does not change the
    rule's meaning.

## Governance

This constitution supersedes ad-hoc conventions and prior informal
practice. When a code review, plan, or task conflicts with this document,
this document wins until it is formally amended.

- All pull requests MUST be reviewed against the principles above; a PR
  that violates a principle without an accompanying amendment MUST be
  blocked or refactored.
- Complexity MUST be justified: any deviation from "boringly simple
  PowerShell" (e.g., introducing classes, advanced functions, modules, or
  background jobs) MUST cite the concrete user-visible problem it solves.
- Runtime guidance for contributors and AI agents lives in
  `.github/copilot-instructions.md` and the Spec Kit templates under
  `.specify/templates/`. Those files MUST be kept consistent with this
  constitution; the Sync Impact Report tracks pending propagation.

**Version**: 1.0.0 | **Ratified**: 2026-06-05 | **Last Amended**: 2026-06-05
