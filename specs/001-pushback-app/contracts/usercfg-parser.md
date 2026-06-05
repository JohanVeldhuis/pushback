# Contract: `UserCfg.opt` Parser

**Producer**: MSFS 2020 (`Microsoft.FlightSimulator_8wekyb3d8bbwe`) and
MSFS 2024 (`Microsoft.Limitless_8wekyb3d8bbwe`).
**Consumer**: `src/Pushback.SimDetect.psm1`.

This contract defines what the detector accepts as a valid input and how
it normalises the value it extracts.

## File location

```text
MSFS 2020: %LOCALAPPDATA%\Packages\Microsoft.FlightSimulator_8wekyb3d8bbwe\LocalCache\UserCfg.opt
MSFS 2024: %LOCALAPPDATA%\Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt
```

The detector probes both paths unconditionally. Missing files are not an
error — they yield `Status = NotInstalled`.

## File format

Plain text. Encoding: ASCII / UTF-8 (BOM optional). One logical entry per
line. Lines whose first non-whitespace character is `;` are comments and
MUST be ignored. Empty lines MUST be ignored. Line terminators may be
`CRLF` or `LF`.

A non-comment line has the shape:

```text
<Key><whitespace+><Value>
```

`<Value>` is either:

- **Quoted** with ASCII double-quotes: `"..."`. Quotes are stripped; the
  inner content is taken verbatim and MAY contain spaces.
- **Unquoted**: the rest of the line after trimming trailing whitespace.

## Key of interest

Only one key is consumed: **`InstalledPackagesPath`**. Matching is
**case-sensitive** (matches the format MSFS itself writes). If multiple
non-comment lines define the key, the **first** wins and a debug-level
log message is emitted; subsequent definitions are ignored.

## Parsing algorithm

```text
1. Read file as UTF-8 text (StreamReader, BOM-tolerant).
2. For each line:
   a. Strip CR.
   b. If first non-whitespace char is ';' → skip.
   c. If line is whitespace-only → skip.
   d. Apply regex: ^\s*InstalledPackagesPath\s+(?:"([^"]*)"|(\S.*?))\s*$
   e. On match, capture group 1 (quoted) or group 2 (unquoted) as raw value.
3. If no match found → return $null.
4. Normalise the raw value (see next section).
```

## Normalisation

Applied in order:

1. `Trim()` whitespace from both ends of the raw value.
2. If the value ends with exactly one `\` or `/` and is **not** a bare
   drive root (`C:\`), strip the trailing separator.
3. Expand environment variables:
   `[System.Environment]::ExpandEnvironmentVariables($value)`.
4. Resolve to an absolute path:
   `[System.IO.Path]::GetFullPath($value)`. This collapses `..` and
   normalises separator casing on Windows.

The Community folder is then `Join-Path $normalised 'Community'`.

## Validation outcomes

The detector classifies the result into the `SimulatorInstallation.Status`
enum (see [`../data-model.md`](../data-model.md)):

| Condition | `Status` | `StatusDetail` |
|---|---|---|
| `UserCfg.opt` does not exist | `NotInstalled` | `"UserCfg.opt not found at <UserCfgPath>"` |
| File exists, key not present | `Misconfigured` | `"InstalledPackagesPath missing or commented out"` |
| File exists, key present, value parses but folder doesn't exist | `Misconfigured` | `"Community folder not found at <CommunityFolder>"` |
| File exists, key present, value parses, folder exists | `Detected` | empty string |

The detector MUST NOT throw on any malformed file — every parse failure
maps to `Misconfigured` with an explanatory `StatusDetail`. The user
needs an actionable error (FR-022), not a stack trace.

## Examples (with expected outcomes)

### Quoted with spaces and trailing slash

```text
InstalledPackagesPath "D:\Games\MSFS 2024\"
```

→ `InstalledPackagesPath = "D:\Games\MSFS 2024"`, `CommunityFolder = "D:\Games\MSFS 2024\Community"`.

### Unquoted, no spaces

```text
InstalledPackagesPath C:\MSFS
```

→ `InstalledPackagesPath = "C:\MSFS"`, `CommunityFolder = "C:\MSFS\Community"`.

### Environment variable

```text
InstalledPackagesPath "%PROGRAMDATA%\MSFS"
```

→ Expanded then normalised, e.g. `C:\ProgramData\MSFS`.

### Commented out

```text
; InstalledPackagesPath "C:\old"
```

→ No match. `Status = Misconfigured`,
`StatusDetail = "InstalledPackagesPath missing or commented out"`.

### Other keys present (ignored)

```text
[General]
Version 1.0.0
InstalledPackagesPath "C:\MSFS"
Language "en-US"
```

→ Only `InstalledPackagesPath` is read; `[General]`, `Version`,
`Language` are ignored.

## Out of scope

- Writing back to `UserCfg.opt` (the app never modifies it).
- Other keys (`Version`, `Language`, etc.).
- Roaming-installation discovery (Steam, custom installers) — those are
  handled by the manual **Browse…** path (US4) rather than by extending
  this parser.
