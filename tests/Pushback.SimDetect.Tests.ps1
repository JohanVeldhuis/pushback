#requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for src/Pushback.SimDetect.psm1.

.DESCRIPTION
    Covers every example from
    specs/001-pushback-app/contracts/usercfg-parser.md and the
    Detected / NotInstalled / Misconfigured classification branches of
    Get-SimulatorInstallation. Written in Pester 3-compatible syntax
    (`Should Be`, no dashes) so the suite runs against the Pester 3.4
    that ships with Windows PowerShell.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path -Path $PSScriptRoot -Parent
$moduleUnderTest = Join-Path $repoRoot 'src\Pushback.SimDetect.psm1'

# Fresh import every run; -Force so iterating in the same session works.
Import-Module $moduleUnderTest -Force

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function New-TempDir {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("pushback-tests-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

function New-FakeLocalAppData {
    <#
    .SYNOPSIS
        Build a fake %LOCALAPPDATA% tree with optional UserCfg.opt content
        for one or both sims.

    .PARAMETER MSFS2020Content
        UserCfg.opt content for the MSFS 2020 install. $null = no file.

    .PARAMETER MSFS2024Content
        UserCfg.opt content for the MSFS 2024 install. $null = no file.

    .PARAMETER InstalledPackagesPath
        Optional Community-folder parent to actually create on disk so a
        $Status = 'Detected' result is reachable.
    #>
    param(
        [string]$MSFS2020Content,
        [string]$MSFS2024Content,
        [string]$MSFS2020PackagesPath,
        [string]$MSFS2024PackagesPath
    )

    $root = New-TempDir

    if ($PSBoundParameters.ContainsKey('MSFS2020Content')) {
        $dir = Join-Path $root 'Packages\Microsoft.FlightSimulator_8wekyb3d8bbwe\LocalCache'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'UserCfg.opt') -Value $MSFS2020Content -Encoding utf8
    }
    if ($PSBoundParameters.ContainsKey('MSFS2024Content')) {
        $dir = Join-Path $root 'Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'UserCfg.opt') -Value $MSFS2024Content -Encoding utf8
    }
    if ($MSFS2020PackagesPath) {
        New-Item -ItemType Directory -Path (Join-Path $MSFS2020PackagesPath 'Community') -Force | Out-Null
    }
    if ($MSFS2024PackagesPath) {
        New-Item -ItemType Directory -Path (Join-Path $MSFS2024PackagesPath 'Community') -Force | Out-Null
    }

    return $root
}

# Collect temp paths so we can clean up after every It.
$script:tempPaths = New-Object System.Collections.Generic.List[string]
function Track-Temp([string]$Path) {
    if ($Path) { $script:tempPaths.Add($Path) | Out-Null }
    return $Path
}
function Clear-Temps {
    foreach ($p in $script:tempPaths) {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $script:tempPaths.Clear()
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

Describe 'Read-InstalledPackagesPath (regex contract)' {

    # All raw-line tests run against the module-private function via
    # InModuleScope; we only need a UserCfg.opt file with one line in it
    # at a time.
    function Invoke-Parse([string]$Content) {
        $dir  = New-TempDir
        Track-Temp $dir | Out-Null
        $file = Join-Path $dir 'UserCfg.opt'
        Set-Content -LiteralPath $file -Value $Content -Encoding utf8
        # Pester 3's InModuleScope has no -ArgumentList parameter, and
        # $script: inside the scriptblock refers to the *module's* script
        # scope. $global: is the only scope visible across both.
        $global:__pushback_usercfgPath = $file
        try {
            return (InModuleScope Pushback.SimDetect { Read-InstalledPackagesPath -UserCfgPath $global:__pushback_usercfgPath })
        } finally {
            Remove-Variable -Name __pushback_usercfgPath -Scope Global -ErrorAction SilentlyContinue
        }
    }

    AfterEach { Clear-Temps }

    It 'parses a quoted value with spaces and trailing slash' {
        $raw = Invoke-Parse 'InstalledPackagesPath "D:\Games\MSFS 2024\"'
        $raw | Should Be 'D:\Games\MSFS 2024\'
    }

    It 'parses an unquoted value' {
        $raw = Invoke-Parse 'InstalledPackagesPath C:\MSFS'
        $raw | Should Be 'C:\MSFS'
    }

    It 'parses a quoted value containing environment variables verbatim' {
        $raw = Invoke-Parse 'InstalledPackagesPath "%PROGRAMDATA%\MSFS"'
        $raw | Should Be '%PROGRAMDATA%\MSFS'
    }

    It 'returns $null when the line is commented out' {
        $multi = @(
            '[General]'
            'Version 1.0.0'
            '; InstalledPackagesPath "C:\old"'
            'Language "en-US"'
        ) -join "`r`n"
        $raw = Invoke-Parse $multi
        $raw | Should BeNullOrEmpty
    }

    It 'ignores other keys and extracts only InstalledPackagesPath' {
        $multi = @(
            '[General]'
            'Version 1.0.0'
            'InstalledPackagesPath "C:\MSFS"'
            'Language "en-US"'
        ) -join "`r`n"
        $raw = Invoke-Parse $multi
        $raw | Should Be 'C:\MSFS'
    }

    It 'tolerates leading whitespace on the key' {
        $raw = Invoke-Parse "   InstalledPackagesPath `"C:\MSFS`""
        $raw | Should Be 'C:\MSFS'
    }

    It 'returns the FIRST match if the key appears multiple times' {
        $multi = @(
            'InstalledPackagesPath "C:\First"'
            'InstalledPackagesPath "C:\Second"'
        ) -join "`r`n"
        $raw = Invoke-Parse $multi
        $raw | Should Be 'C:\First'
    }

    It 'is case-SENSITIVE on the key (per contract)' {
        $raw = Invoke-Parse 'installedpackagespath "C:\MSFS"'
        $raw | Should BeNullOrEmpty
    }

    It 'returns $null when the file is empty' {
        $raw = Invoke-Parse ''
        $raw | Should BeNullOrEmpty
    }
}

Describe 'Get-SimulatorInstallation (classification)' {

    AfterEach { Clear-Temps }

    It 'returns exactly two records in MSFS2020, MSFS2024 order' {
        $fake = Track-Temp (New-FakeLocalAppData)
        $result = Get-SimulatorInstallation -LocalAppData $fake
        $result.Count          | Should Be 2
        $result[0].Id          | Should Be 'MSFS2020'
        $result[1].Id          | Should Be 'MSFS2024'
        $result[0].DisplayName | Should Be 'MSFS 2020'
        $result[1].DisplayName | Should Be 'MSFS 2024'
    }

    It 'reports NotInstalled when UserCfg.opt is missing' {
        $fake = Track-Temp (New-FakeLocalAppData)
        $result = Get-SimulatorInstallation -LocalAppData $fake
        $result[0].Status       | Should Be 'NotInstalled'
        $result[0].UserCfgExists| Should Be $false
        $result[0].StatusDetail | Should Match 'UserCfg\.opt not found'
        $result[1].Status       | Should Be 'NotInstalled'
    }

    It 'reports Misconfigured when InstalledPackagesPath is missing or commented out' {
        $fake = Track-Temp (New-FakeLocalAppData -MSFS2020Content @"
[General]
Version 1.0.0
; InstalledPackagesPath "C:\old"
Language "en-US"
"@)
        $result = Get-SimulatorInstallation -LocalAppData $fake
        $result[0].Status        | Should Be 'Misconfigured'
        $result[0].UserCfgExists | Should Be $true
        $result[0].StatusDetail  | Should Be 'InstalledPackagesPath missing or commented out'
    }

    It 'reports Misconfigured when the Community folder does not exist on disk' {
        $bogus = Join-Path ([System.IO.Path]::GetTempPath()) ("pushback-bogus-" + [Guid]::NewGuid().ToString('N'))
        # NOTE: we deliberately do NOT create $bogus, so Community does not exist.
        $fake  = Track-Temp (New-FakeLocalAppData -MSFS2020Content "InstalledPackagesPath `"$bogus`"")
        $result = Get-SimulatorInstallation -LocalAppData $fake
        $result[0].Status      | Should Be 'Misconfigured'
        $result[0].StatusDetail| Should Match 'Community folder not found'
    }

    It 'reports Detected when the Community folder exists' {
        $packages = Track-Temp (New-TempDir)
        $fake = Track-Temp (New-FakeLocalAppData `
            -MSFS2020Content "InstalledPackagesPath `"$packages`"" `
            -MSFS2020PackagesPath $packages)
        $result = Get-SimulatorInstallation -LocalAppData $fake
        $result[0].Status                | Should Be 'Detected'
        $result[0].StatusDetail          | Should BeNullOrEmpty
        $result[0].InstalledPackagesPath | Should Be ([System.IO.Path]::GetFullPath($packages))
        $result[0].CommunityFolder       | Should Be (Join-Path ([System.IO.Path]::GetFullPath($packages)) 'Community')
    }

    It 'strips one trailing backslash from InstalledPackagesPath but keeps the bare drive root' {
        $packages = Track-Temp (New-TempDir)
        $withSlash = $packages.TrimEnd('\') + '\'
        $fake = Track-Temp (New-FakeLocalAppData `
            -MSFS2020Content "InstalledPackagesPath `"$withSlash`"" `
            -MSFS2020PackagesPath $packages)
        $result = Get-SimulatorInstallation -LocalAppData $fake
        $result[0].Status                | Should Be 'Detected'
        $result[0].InstalledPackagesPath | Should Be ([System.IO.Path]::GetFullPath($packages))
    }

    It 'expands environment variables in InstalledPackagesPath' {
        $packages = Track-Temp (New-TempDir)
        $env:PUSHBACK_TEST_PACKAGES = $packages
        try {
            $fake = Track-Temp (New-FakeLocalAppData `
                -MSFS2020Content 'InstalledPackagesPath "%PUSHBACK_TEST_PACKAGES%"' `
                -MSFS2020PackagesPath $packages)
            $result = Get-SimulatorInstallation -LocalAppData $fake
            $result[0].Status                | Should Be 'Detected'
            $result[0].InstalledPackagesPath | Should Be ([System.IO.Path]::GetFullPath($packages))
        } finally {
            Remove-Item Env:\PUSHBACK_TEST_PACKAGES -ErrorAction SilentlyContinue
        }
    }

    It 'never throws on a malformed UserCfg.opt' {
        $fake = Track-Temp (New-FakeLocalAppData -MSFS2020Content "garbage on a single line with no key")
        { Get-SimulatorInstallation -LocalAppData $fake } | Should Not Throw
        $result = Get-SimulatorInstallation -LocalAppData $fake
        $result[0].Status | Should Be 'Misconfigured'
    }

    It 'classifies each sim independently (one Detected, one NotInstalled)' {
        $packages = Track-Temp (New-TempDir)
        $fake = Track-Temp (New-FakeLocalAppData `
            -MSFS2020Content "InstalledPackagesPath `"$packages`"" `
            -MSFS2020PackagesPath $packages)
        # Deliberately omit MSFS2024Content.
        $result = Get-SimulatorInstallation -LocalAppData $fake
        $result[0].Status | Should Be 'Detected'
        $result[1].Status | Should Be 'NotInstalled'
    }
}
