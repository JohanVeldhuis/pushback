#requires -Version 5.1
<#
.SYNOPSIS
    MSFS UserCfg.opt discovery and InstalledPackagesPath parsing.

.DESCRIPTION
    Probes both known UserCfg.opt locations (MSFS 2020 + MSFS 2024),
    extracts InstalledPackagesPath using the regex defined in
    specs/001-pushback-app/contracts/usercfg-parser.md, normalises the
    value, and classifies each sim into Detected / NotInstalled /
    Misconfigured.

.NOTES
    Constitution Principle I — no hardcoded paths in business logic; sim
    package IDs are constants here at the top of the file. Principle III
    — never throws on a malformed file; surfaces an actionable
    StatusDetail instead.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Package IDs are fixed by Microsoft.
$script:SimRegistry = @(
    [pscustomobject]@{
        Id              = 'MSFS2020'
        DisplayName     = 'MSFS 2020'
        PackageFolder   = 'Microsoft.FlightSimulator_8wekyb3d8bbwe'
    }
    [pscustomobject]@{
        Id              = 'MSFS2024'
        DisplayName     = 'MSFS 2024'
        PackageFolder   = 'Microsoft.Limitless_8wekyb3d8bbwe'
    }
)

# Public regex; mirrors usercfg-parser.md exactly.
$script:InstalledPackagesPathRegex =
    '^\s*InstalledPackagesPath\s+(?:"([^"]*)"|(\S.*?))\s*$'

function ConvertTo-DetectorPath {
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }

    $value = $Raw.Trim()
    if ($value.Length -gt 3 -and ($value.EndsWith('\') -or $value.EndsWith('/'))) {
        $value = $value.Substring(0, $value.Length - 1)
    }
    $value = [System.Environment]::ExpandEnvironmentVariables($value)
    try { return [System.IO.Path]::GetFullPath($value) } catch { return $null }
}

function Read-InstalledPackagesPath {
    <#
    .SYNOPSIS
        Return the raw InstalledPackagesPath value from a UserCfg.opt
        file, or $null if not found. Returns the first match if multiple
        are present.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$UserCfgPath)

    if (-not (Test-Path -LiteralPath $UserCfgPath -PathType Leaf)) { return $null }

    # StreamReader is BOM-tolerant on both PS 5.1 and 7.x.
    $reader = [System.IO.StreamReader]::new($UserCfgPath)
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { continue }
            $trimmed = $line.TrimStart()
            if ($trimmed.Length -eq 0) { continue }
            if ($trimmed.StartsWith(';')) { continue }

            $m = [System.Text.RegularExpressions.Regex]::Match(
                $line, $script:InstalledPackagesPathRegex)
            if ($m.Success) {
                # group 1 = quoted, group 2 = unquoted
                if ($m.Groups[1].Success) { return $m.Groups[1].Value }
                if ($m.Groups[2].Success) { return $m.Groups[2].Value }
            }
        }
    } finally {
        $reader.Dispose()
    }
    return $null
}

function New-SimulatorInstallation {
    [OutputType([pscustomobject])]
    param(
        [string]$Id,
        [string]$DisplayName,
        [string]$UserCfgPath,
        [bool]  $UserCfgExists,
        [string]$InstalledPackagesPath,
        [string]$CommunityFolder,
        [ValidateSet('Detected','NotInstalled','Misconfigured')][string]$Status,
        [string]$StatusDetail
    )
    return [pscustomobject]@{
        Id                    = $Id
        DisplayName           = $DisplayName
        UserCfgPath           = $UserCfgPath
        UserCfgExists         = $UserCfgExists
        InstalledPackagesPath = $InstalledPackagesPath
        CommunityFolder       = $CommunityFolder
        Status                = $Status
        StatusDetail          = $StatusDetail
    }
}

function Get-SimulatorInstallation {
    <#
    .SYNOPSIS
        Detects MSFS 2020 and MSFS 2024 installs.

    .OUTPUTS
        Exactly two [pscustomobject] records in MSFS2020, MSFS2024 order.

    .PARAMETER LocalAppData
        Override for tests. Defaults to the current user's %LOCALAPPDATA%.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([string]$LocalAppData = $env:LOCALAPPDATA)

    $results = foreach ($sim in $script:SimRegistry) {
        $userCfg = Join-Path -Path $LocalAppData -ChildPath "Packages\$($sim.PackageFolder)\LocalCache\UserCfg.opt"
        $exists  = Test-Path -LiteralPath $userCfg -PathType Leaf

        if (-not $exists) {
            New-SimulatorInstallation `
                -Id $sim.Id -DisplayName $sim.DisplayName `
                -UserCfgPath $userCfg -UserCfgExists $false `
                -InstalledPackagesPath '' -CommunityFolder '' `
                -Status 'NotInstalled' `
                -StatusDetail "UserCfg.opt not found at $userCfg"
            continue
        }

        $raw = Read-InstalledPackagesPath -UserCfgPath $userCfg
        if ([string]::IsNullOrWhiteSpace($raw)) {
            New-SimulatorInstallation `
                -Id $sim.Id -DisplayName $sim.DisplayName `
                -UserCfgPath $userCfg -UserCfgExists $true `
                -InstalledPackagesPath '' -CommunityFolder '' `
                -Status 'Misconfigured' `
                -StatusDetail 'InstalledPackagesPath missing or commented out'
            continue
        }

        $normalised = ConvertTo-DetectorPath -Raw $raw
        if (-not $normalised) {
            New-SimulatorInstallation `
                -Id $sim.Id -DisplayName $sim.DisplayName `
                -UserCfgPath $userCfg -UserCfgExists $true `
                -InstalledPackagesPath $raw -CommunityFolder '' `
                -Status 'Misconfigured' `
                -StatusDetail "InstalledPackagesPath could not be resolved: $raw"
            continue
        }

        $community = Join-Path -Path $normalised -ChildPath 'Community'
        if (-not (Test-Path -LiteralPath $community -PathType Container)) {
            New-SimulatorInstallation `
                -Id $sim.Id -DisplayName $sim.DisplayName `
                -UserCfgPath $userCfg -UserCfgExists $true `
                -InstalledPackagesPath $normalised -CommunityFolder $community `
                -Status 'Misconfigured' `
                -StatusDetail "Community folder not found at $community"
            continue
        }

        New-SimulatorInstallation `
            -Id $sim.Id -DisplayName $sim.DisplayName `
            -UserCfgPath $userCfg -UserCfgExists $true `
            -InstalledPackagesPath $normalised -CommunityFolder $community `
            -Status 'Detected' -StatusDetail ''
    }

    # ForEach over $script:SimRegistry preserves order, but materialise
    # explicitly so callers see a stable two-element array.
    return ,@($results)
}

Export-ModuleMember -Function Get-SimulatorInstallation
