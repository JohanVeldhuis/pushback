# Pushback

A small Windows utility that toggles the **PUSHBACK** flag in every
`aircraft.cfg` under your Microsoft Flight Simulator **Community**
folder. Ships as a one-click WPF GUI for non-technical users and a
PowerShell CLI for power users — both share the same engine, so they
behave identically.

> Built for **MSFS 2020** *and* **MSFS 2024**. Auto-detects both
> installations by reading their `UserCfg.opt`. No registry edits, no
> third-party modules, no internet access.

---

## What it does

For every `aircraft.cfg` it finds under the Community folder:

- If the file contains `PUSHBACK = 1`, it can flip it to `PUSHBACK = 0`
  (Disable) or vice versa (Enable).
- Before any change it makes a `.bak` sibling so you can roll back.
- A first-class **Dry run** mode previews exactly what *would* change
  without touching a single byte on disk.
- A **Restore backups** action puts every `.bak` back over its `.cfg`,
  returning files to their pre-run state byte-for-byte.

Everything is logged with ISO-8601 UTC timestamps to
`%LOCALAPPDATA%\Pushback\pushback.log`.

---

## Requirements

- Windows 10 or 11.
- Windows PowerShell 5.1 (preinstalled) **or** PowerShell 7.x.
- No installer. No dependencies from the PowerShell Gallery.

---

## Quick start (GUI — recommended)

1. Download or clone this repository.
2. Close MSFS if it's running.
3. Double-click [`launcher/Pushback.cmd`](launcher/Pushback.cmd).
4. The window opens with your Community folder auto-detected.
5. Click **Dry run** first to preview the changes.
6. Click **Disable pushback** (or **Enable pushback**) to apply them.

### What the buttons do

| Button | Effect |
|---|---|
| **Dry run** | Scans and reports what *would* change. Writes nothing. Always safe. |
| **Disable pushback** | Rewrites `PUSHBACK = 1` → `PUSHBACK = 0`. Creates `.bak` siblings. |
| **Enable pushback** | Rewrites `PUSHBACK = 0` → `PUSHBACK = 1`. Creates `.bak` siblings. |
| **Restore backups** | Copies every `aircraft.cfg.bak` back over `aircraft.cfg`. |
| **Browse…** | Pick a Community folder manually when auto-detection misses it. |
| **Open log** | Opens `pushback.log` in your default text editor. |
| **Cancel** | Stops the run between files (safe — finishes the current file). |

### When both MSFS 2020 and MSFS 2024 are installed

The sim picker at the top will show both. Action buttons stay disabled
until you choose one — there is no surprise default. You can switch sims
mid-session; the results pane clears so old counts don't carry over.

### When auto-detection misses your install

If you installed MSFS via Steam, to a custom drive that isn't in your
`UserCfg.opt`, or the file is malformed, the GUI falls back to a
**Browse…** flow. Pick the folder named `Community`; the app verifies
it actually contains at least one `aircraft.cfg` before enabling the
action buttons.

---

## Backups & how to undo a run

Every Disable or Enable run creates an `aircraft.cfg.bak` next to each
file it rewrites.

- **One-click undo**: click **Restore backups** in the GUI.
- **Manual undo**: rename each `.bak` back to `aircraft.cfg` yourself
  (or delete the modified `.cfg` and rename the `.bak`).

If you re-run Disable/Enable and a `.bak` already exists, the run is
blocked and the GUI offers an explicit *"overwrite existing backups"*
opt-in. This stops you from accidentally overwriting a known-good
backup with a modified file.

---

## CLI usage (for power users)

The CLI wraps the same engine the GUI uses.

```powershell
# Preview only (default action is DryRun — never mutates files):
.\pushback.ps1 -CommunityFolder 'C:\MSFS\Community'

# Apply: rewrite PUSHBACK=1 → PUSHBACK=0 everywhere, with .bak siblings:
.\pushback.ps1 -CommunityFolder 'C:\MSFS\Community' -Action DisablePushback

# Re-enable:
.\pushback.ps1 -CommunityFolder 'C:\MSFS\Community' -Action EnablePushback

# Roll everything back from .bak siblings:
.\pushback.ps1 -CommunityFolder 'C:\MSFS\Community' -Action RestoreBackups

# Overwrite existing .bak files (opt-in; required if backups exist):
.\pushback.ps1 -CommunityFolder 'C:\MSFS\Community' -Action DisablePushback -OverwriteExistingBackups

# Use a custom log path:
.\pushback.ps1 -CommunityFolder 'C:\MSFS\Community' -LogPath 'D:\logs\pushback.log'
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-CommunityFolder` | *(required)* | Path to your MSFS Community folder. |
| `-Action` | `DryRun` | One of `DryRun`, `DisablePushback`, `EnablePushback`, `RestoreBackups`. |
| `-LogPath` | `%LOCALAPPDATA%\Pushback\pushback.log` | Where to append the run log. |
| `-OverwriteExistingBackups` | *(off)* | Allow overwriting existing `aircraft.cfg.bak` files. |

The script returns a `RunResult` object on the success stream, so you
can pipe it:

```powershell
$run = .\pushback.ps1 -CommunityFolder 'C:\MSFS\Community' -Action DryRun
$run.Entries | Where-Object State -eq 'WOULD CHANGE' | Select-Object FullPath
```

---

## Project layout

```text
pushback/
├─ launcher/Pushback.cmd           # double-click entry for end users
├─ pushback.ps1                    # CLI wrapper
└─ src/
   ├─ Pushback.Engine.psm1         # pure engine (no UI)
   ├─ Pushback.SimDetect.psm1      # UserCfg.opt parser + detector
   ├─ Pushback.Gui.ps1             # WPF GUI (background runspace)
   └─ MainWindow.xaml              # GUI layout
```

The GUI is just a thin wrapper around the engine, so if WPF fails to
load for any reason you can always fall back to the CLI.

---

## Troubleshooting

**"This script is not digitally signed"**
The launcher uses `-ExecutionPolicy Bypass` scoped to that single
invocation, so this should not appear. If you run `pushback.ps1`
directly, launch it via `powershell -ExecutionPolicy Bypass -File .\pushback.ps1 …`.

**"Existing .bak files found"**
Either restore from those backups first (recommended) or re-run with
`-OverwriteExistingBackups` (CLI) / tick the *Advanced → Overwrite
existing backups* checkbox in the GUI.

**File-in-use / IO errors**
MSFS holds `aircraft.cfg` open while it's running. Close the simulator
and re-run.

**Auto-detection says "Misconfigured"**
The `UserCfg.opt` was found but the Community folder it points at
doesn't exist on disk. Use **Browse…** to select the right folder
manually.

---

## Testing

The project ships with Pester tests and a non-destructive smoke
harness — both used as PR evidence.

```powershell
# Smoke test (no MSFS install needed; runs against tests/fixtures/):
.\tests\Run-DryRunSmokeTest.ps1

# Full Pester suite:
Invoke-Pester -Path .\tests\Pushback.SimDetect.Tests.ps1, .\tests\Pushback.Engine.Tests.ps1
```

See [`specs/001-pushback-app/quickstart.md`](specs/001-pushback-app/quickstart.md)
for the full validation flows.

---

## License & disclaimer

Use at your own risk. Always run **Dry run** first against a folder
you care about, and keep your `.bak` files until you've test-flown the
result.

---

## Credits

This project is based on the original PowerShell script by
[**joesalty**](https://github.com/joesalty):
[joesalty/MSFS_2024_FSLTL_Pushback_change_script](https://github.com/joesalty/MSFS_2024_FSLTL_Pushback_change_script)
— a PowerShell script to mass-update `aircraft.cfg` files in FSLTL
folders for MSFS 2024. Pushback wraps that core idea in a reusable
engine module, adds auto-detection for both MSFS 2020 and MSFS 2024,
and puts a WPF GUI on top so non-PowerShell users can run it safely.
