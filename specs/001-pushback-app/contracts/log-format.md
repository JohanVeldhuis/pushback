# Contract: Log File Format

**Producer**: `src/Pushback.Engine.psm1`.
**Consumers**: end users (via "Open log" in the GUI, US5), QA reviewers
(per constitution Principle II), automated regression checks.

This contract is **load-bearing** for Principle II (dry-run evidence) and
Principle III (predictable UX). Changes require a constitution amendment.

## File metadata

| Property | Value |
|---|---|
| Default path | `%LOCALAPPDATA%\Pushback\pushback.log` |
| Encoding | UTF-8 (BOM tolerated on PS 5.1; not emitted on PS 7.x) |
| Line terminator | `CRLF` on Windows |
| Open mode | Append (`Add-Content` / `Out-File -Append`). The engine MUST NOT take an exclusive lock that prevents tail viewers. |
| Truncation policy | Never automatic. If the user wants to discard history they delete the file manually. |

## Per-run structure

Each run writes exactly one "section" with the following shape:

```text
--- Script started: <ISO-8601 UTC timestamp> ---
<one line per file processed, see grammar below>
...
--- Script finished: <ISO-8601 UTC timestamp> ---
```

The start line MUST be the first line written in a run. The finish line
MUST be the last line written in the same run — including the
cancellation case. If the engine crashes mid-run such that the finish
line is never written, the run is considered **corrupt** and any
follow-up `RestoreBackups` action SHOULD warn the user.

## Per-file entry grammar

```text
<state-tag>: <absolute-path>
```

`<state-tag>` is exactly one of:

| Tag | When emitted |
|---|---|
| `CHANGED` | Real run, file was rewritten (and a `.bak` was created). |
| `WOULD CHANGE` | Dry-run, file would have been rewritten. |
| `NO CHANGE` | The target line wasn't present in the file, or the file was already in the desired state. |
| `ERROR: <reason>` | Per-file failure. `<reason>` MUST be a single-line, human-readable English sentence that names the operation that failed (e.g. `ERROR: Cannot read file (sharing violation - close MSFS and re-run): C:\MSFS\Community\foo\aircraft.cfg`). |

The colon and single space after the tag are mandatory. The path MUST be
absolute and printed verbatim — no quoting, no escaping (paths with
spaces are still legal).

## `RestoreBackups` action

Uses the same grammar, with these semantics:

| Tag | When emitted |
|---|---|
| `CHANGED` | `aircraft.cfg` was overwritten from its `.bak`. |
| `NO CHANGE` | A `.bak` existed but its content was byte-identical to `aircraft.cfg`. |
| `ERROR: <reason>` | Restore failed (e.g., locked file, missing `.bak`). |

`WOULD CHANGE` is never emitted by `RestoreBackups` because that action
has no dry-run mode in v1.

## Example

```text
--- Script started: 2026-06-05T13:42:01Z ---
WOULD CHANGE: C:\MSFS\Community\fsltl-traffic-base\SimObjects\Airplanes\B738\aircraft.cfg
WOULD CHANGE: C:\MSFS\Community\fsltl-traffic-base\SimObjects\Airplanes\A320\aircraft.cfg
NO CHANGE: C:\MSFS\Community\fsltl-traffic-base\SimObjects\Airplanes\A321\aircraft.cfg
ERROR: Cannot read file (sharing violation - close MSFS and re-run): C:\MSFS\Community\fsltl-traffic-base\SimObjects\Airplanes\B789\aircraft.cfg
--- Script finished: 2026-06-05T13:42:14Z ---
```

## Required GUI-to-log invariant

For each run the following MUST hold (validated by the GUI before showing
the summary, per SC-004):

```text
count("CHANGED:")     == RunResult.Counts.Changed
count("WOULD CHANGE:")== RunResult.Counts.WouldChange
count("NO CHANGE:")   == RunResult.Counts.Unchanged
count("ERROR:")       == RunResult.Counts.Errors
```

If any equality fails the GUI MUST display a banner ("Log and summary
disagree — please share the log with the maintainer") rather than
silently showing the in-memory counts. This is the cheapest possible
self-check that protects users from a counting bug shipping unnoticed.

## What MUST NOT appear

- ANSI colour codes.
- Multi-line entries.
- Stack traces — they belong in `Write-Verbose` / `-Debug` streams, not
  the log.
- File contents — only paths and state tags.
- Network identifiers (no telemetry, per FR-020).
