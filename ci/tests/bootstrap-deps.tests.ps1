#Requires -Version 7.0
<#
.SYNOPSIS
    Real (non-dry-run) tests for ci/bootstrap-deps.ps1.

.DESCRIPTION
    Every case launches bootstrap-deps.ps1 as a child pwsh process (real exit codes, real
    stdout/stderr - the CLI contract) with -VipmPath pointed at
    fixtures/vipm-stub/vipm-stub.cmd, a real .cmd process that records the argv it
    received, replays a fixture as the `list` output and exits with $env:STUB_EXIT_CODE.

    The real VI Package Manager is NEVER executed: this maintainer machine has 20 real
    packages installed and a stray `vipm install`/`list`/`remove` would change a
    developer environment. Every single invocation in this suite goes through the stub,
    and T02 asserts that a missing CLI means the stub was not called at all.

    No test writes to the repository: dragons, listings and the fake NI/LabVIEW tree all
    live in a temp sandbox (removed in the finally block).

    Cases:
      T01 full-run-and-argv    default run against the REAL Lab_Super.dragon: exit 0, all
                               20 ids verified, exact install/list argv shape, absolute
                               dragon path, no warnings, a sandbox path with a space
      T02 missing-vipm         no CLI -> exit 2, actionable VIPM guidance, nothing invoked
      T03 missing-two-packages install claims "20 packages installed successfully" but the
                               listing omits 2 ids -> exit 4, both ids named, no success
                               claim anywhere (the core assertion of the script)
      T04 malformed-dragon     no [vipm.dependencies] / empty section / malformed entry ->
                               exit 2 with the line named, nothing invoked
      T05 idempotent-rerun     two consecutive runs: both exit 0, identical argv, no file
                               in the sandbox or the repository changed
      T06 verify-only          -VerifyOnly: `list` runs, `install` does not
      T07 hung-install         the CLI hangs -> the watchdog kills the process tree inside
                               the budget, exit 3, no stub process left behind
      T08 node-too-old         PATH shim reports v18 -> exit 2 with the Node 20 guidance,
                               nothing invoked
      T09 missing-labview      -LabViewPath does not exist -> exit 2, nothing invoked
      T10 ni-soft-check        empty NI root -> still exit 0 with all four products listed
                               as warnings (soft by design; the Installer spec needs them)
      T11 parser-and-format    quoted keys / inline comments / blank lines parse, and a
                               JSON-shaped installed listing verifies as well as a table
      T12 stale-extra-boundary extra packages from other projects still pass; a substring
                               look-alike (oglib_appcontrol_extra) does not satisfy an id;
                               an effectively empty listing is red with 20/20 missing
      T13 hung-list            a hanging `list` fails the verification (exit 4) inside its
                               budget instead of hanging the unattended VM run
      T14 invalid-parameters   a non-year -LabViewVersion / a non-positive timeout -> exit 2
                               usage error with the offending parameter named, nothing run

    Run:  pwsh -NoProfile -File ci/tests/bootstrap-deps.tests.ps1
    Exit: 0 = all cases passed; N>0 = number of failed cases (capped at 125).
    -BootstrapScript <path> overrides the script under test (mutation testing).
#>
[CmdletBinding()]
param(
    [switch]$KeepFixtures,
    # Optional override used by mutation testing: point the suite at a deliberately
    # broken copy of bootstrap-deps.ps1 to prove the assertions are not vacuous.
    [string]$BootstrapScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- paths ---------------------------------------------------------------------

$TestsDir = $PSScriptRoot
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $TestsDir '..\..')).ProviderPath
if ([string]::IsNullOrWhiteSpace($BootstrapScript)) {
    $ScriptUnderTest = (Resolve-Path -LiteralPath (Join-Path $TestsDir '..\bootstrap-deps.ps1')).ProviderPath
}
else {
    $ScriptUnderTest = (Resolve-Path -LiteralPath $BootstrapScript).ProviderPath
}
$StubCmd = (Resolve-Path -LiteralPath (Join-Path $TestsDir 'fixtures\vipm-stub\vipm-stub.cmd')).ProviderPath
$StubPs1 = (Resolve-Path -LiteralPath (Join-Path $TestsDir 'fixtures\vipm-stub\vipm-stub.ps1')).ProviderPath
$RealDragon = (Resolve-Path -LiteralPath (Join-Path $RepoRoot 'Lab_Super.dragon')).ProviderPath
$PwshExe = (Get-Command pwsh -ErrorAction Stop).Source
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

Write-Host '== ci/bootstrap-deps.ps1 tests =='
Write-Host ("cwd                : " + (Get-Location).Path)
Write-Host ("script under test  : " + $ScriptUnderTest + "  [exists=" + (Test-Path -LiteralPath $ScriptUnderTest) + "]")
Write-Host ("vipm stub          : " + $StubCmd)
Write-Host ("real dragon        : " + $RealDragon + "  [exists=" + (Test-Path -LiteralPath $RealDragon) + "]")
Write-Host ("repo root          : " + $RepoRoot)

# --- tiny assertion harness -----------------------------------------------------

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ("ASSERT FAILED: " + $Message) }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ("$Expected" -ne "$Actual") { throw ("ASSERT FAILED: " + $Message + " -- expected [" + $Expected + "], got [" + $Actual + "]") }
}
function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Message)
    if (-not $Haystack.Contains($Needle)) { throw ("ASSERT FAILED: " + $Message + " -- output does not contain [" + $Needle + "]") }
}
function Assert-NotContains {
    param([string]$Haystack, [string]$Needle, [string]$Message)
    if ($Haystack.Contains($Needle)) { throw ("ASSERT FAILED: " + $Message + " -- output unexpectedly contains [" + $Needle + "]") }
}
function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) { throw ("ASSERT FAILED: " + $Message + " -- text does not match /" + $Pattern + "/") }
}
function Assert-NotMatch {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -match $Pattern) { throw ("ASSERT FAILED: " + $Message + " -- text unexpectedly matches /" + $Pattern + "/") }
}
function Write-Evidence {
    param([string]$Text)
    Write-Host ("    evidence: " + $Text)
}
function Test-Case {
    param([string]$Id, [string]$Title, [scriptblock]$Body)
    try {
        & $Body
        $script:Results.Add([pscustomobject]@{ Id = $Id; Title = $Title; Ok = $true; Detail = '' })
        Write-Host ("[PASS] " + $Id + "  " + $Title)
    }
    catch {
        $script:Results.Add([pscustomobject]@{ Id = $Id; Title = $Title; Ok = $false; Detail = $_.Exception.Message })
        Write-Host ("[FAIL] " + $Id + "  " + $Title)
        Write-Host ("       " + $_.Exception.Message)
    }
}

# --- sandbox helpers ------------------------------------------------------------

$script:TmpRoots = [System.Collections.Generic.List[string]]::new()

function New-Sandbox {
    param([string]$Tag, [switch]$Spaced)
    $leaf = 'mica-bootstrap-' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    if ($Spaced) { $leaf = 'mica bootstrap ' + $Tag + ' ' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) $leaf
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $script:TmpRoots.Add($path)
    return $path
}

# Fake LabVIEW exe + fake NI product tree + paths for the listing/stub log.
function New-FakeEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$Sandbox,
        [int]$NiProducts = 4
    )
    $labview = Join-Path $Sandbox 'LabVIEW.exe'
    [System.IO.File]::WriteAllText($labview, 'stub-labview-not-a-real-binary', $Utf8NoBom)
    $niRoot = Join-Path $Sandbox 'NI'
    New-Item -ItemType Directory -Path $niRoot -Force | Out-Null
    $productDirs = @('NI-488.2', 'Shared\NI-VISA', 'NI-DAQ', 'Shared\LabVIEW Run-Time\2026')
    $created = 0
    foreach ($relative in $productDirs) {
        if ($created -ge $NiProducts) { break }
        New-Item -ItemType Directory -Path (Join-Path $niRoot $relative) -Force | Out-Null
        $created += 1
    }
    return [pscustomobject]@{
        LabView           = $labview
        NiRoot            = $niRoot
        ListFile          = (Join-Path $Sandbox 'installed-list.txt')
        InstallOutputFile = Join-Path $Sandbox 'install-output.txt'
        ArgvLog           = Join-Path $Sandbox 'stub\argv.log'
    }
}

# The 20 ids, read with an independent mini-parser so the fixture is not a copy of the
# production parser's opinion.
function Get-RealDragonIds {
    $section = ''
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($RealDragon)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed.StartsWith('[')) {
            $section = $trimmed.Trim('[', ']').Trim().ToLowerInvariant()
            continue
        }
        if ($section -eq 'vipm.dependencies' -and $trimmed.Contains('=')) {
            $ids.Add($trimmed.Split('=')[0].Trim().Trim('"'))
        }
    }
    return $ids
}

# Table listing shaped like `vipm list --installed` output.
function Write-InstalledListing {
    param([string]$Path, [string[]]$Ids, [string[]]$Omit = @())
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('VIPM: Installed Packages (LabVIEW 2026, 32-bit)')
    $lines.Add('-------------------------------------------------------------')
    foreach ($id in $Ids) {
        if ($Omit -contains $id) { continue }
        $lines.Add('  ' + $id.PadRight(46) + '6.0.0.10')
    }
    [System.IO.File]::WriteAllLines($Path, $lines.ToArray(), $Utf8NoBom)
}

# JSON-shaped listing: proves the verification does not depend on a text table layout.
function Write-JsonListing {
    param([string]$Path, [string[]]$Ids)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')
    $lines.Add('  "labview_version": 2026,')
    $lines.Add('  "installed": [')
    $index = 0
    foreach ($id in $Ids) {
        $index += 1
        $comma = ','
        if ($index -eq $Ids.Count) { $comma = '' }
        $lines.Add('    { "id": "' + $id + '", "version": "6.0.0.10", "kind": "vipm" }' + $comma)
    }
    $lines.Add('  ]')
    $lines.Add('}')
    [System.IO.File]::WriteAllLines($Path, $lines.ToArray(), $Utf8NoBom)
}

function Write-InstallBanner {
    param([string]$Path, [int]$Count = 20)
    $lines = @(
        'Resolving VIPM dependencies from the dragon file...',
        ('Done: ' + $Count + ' packages installed successfully.')
    )
    [System.IO.File]::WriteAllLines($Path, $lines, $Utf8NoBom)
}

function Write-DragonFile {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Get-StubLines {
    param([string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $LogPath -Encoding utf8)
}
function Get-InstallLines {
    param([string]$LogPath)
    return @(Get-StubLines -LogPath $LogPath | Where-Object { $_ -match ' argv: install( |$)' })
}
function Get-ListLines {
    param([string]$LogPath)
    return @(Get-StubLines -LogPath $LogPath | Where-Object { $_ -match ' argv: list( |$)' })
}
function Get-ArgvPart {
    param([string]$LogLine)
    $marker = ' argv: '
    $index = $LogLine.IndexOf($marker)
    if ($index -lt 0) { return '' }
    return $LogLine.Substring($index + $marker.Length)
}

# Any stub process still alive? Used by the hung-command case.
function Get-LiveStubProcesses {
    $alive = [System.Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)) {
        if ($null -eq $process.CommandLine) { continue }
        if ($process.CommandLine -match 'vipm-stub') { $alive.Add($process) }
    }
    return $alive
}

# WMI can lag behind a kill by a moment; poll before declaring a cleanup failure.
function Wait-NoStubProcesses {
    param([int]$TimeoutSec = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $alive = @(Get-LiveStubProcesses)
        if ($alive.Count -eq 0) { return @() }
        Start-Sleep -Milliseconds 500
    }
    return @(Get-LiveStubProcesses)
}

# Launch the script under test as a child pwsh process with the stub wired in as the
# VIPM CLI. Environment variables are set for the child only and always restored.
function Invoke-Bootstrap {
    param(
        [Parameter(Mandatory = $true)][string]$Sandbox,
        [string]$Dragon = '',
        [string]$Vipm = '',
        [string]$LabView = '',
        [string]$NiRoot = '',
        [string]$ListFile = '',
        [string]$InstallOutputFile = '',
        [int]$StubExitCode = 0,
        [int]$StubSleepSec = 0,
        [string]$StubSleepSubcommand = '',
        [int]$ExpectedPackageCount = 20,
        [int]$InstallTimeoutSec = 3600,
        [int]$ListTimeoutSec = 120,
        [int]$WatchdogGraceSec = 60,
        [string]$PathOverride = '',
        [string[]]$ExtraArgs = @()
    )
    if ([string]::IsNullOrWhiteSpace($Dragon)) { $Dragon = $RealDragon }
    if ([string]::IsNullOrWhiteSpace($Vipm)) { $Vipm = $StubCmd }
    $argvLog = Join-Path $Sandbox 'stub\argv.log'

    $envKeys = @('STUB_ARGV_LOG', 'STUB_LIST_FILE', 'STUB_INSTALL_OUTPUT_FILE', 'STUB_EXIT_CODE', 'STUB_SLEEP_SEC', 'STUB_SLEEP_SUBCOMMAND', 'PATH')
    $saved = @{}
    foreach ($key in $envKeys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
    try {
        [Environment]::SetEnvironmentVariable('STUB_ARGV_LOG', $argvLog, 'Process')
        [Environment]::SetEnvironmentVariable('STUB_LIST_FILE', $ListFile, 'Process')
        [Environment]::SetEnvironmentVariable('STUB_INSTALL_OUTPUT_FILE', $InstallOutputFile, 'Process')
        [Environment]::SetEnvironmentVariable('STUB_EXIT_CODE', "$StubExitCode", 'Process')
        [Environment]::SetEnvironmentVariable('STUB_SLEEP_SEC', "$StubSleepSec", 'Process')
        [Environment]::SetEnvironmentVariable('STUB_SLEEP_SUBCOMMAND', $StubSleepSubcommand, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($PathOverride)) {
            [Environment]::SetEnvironmentVariable('PATH', $PathOverride, 'Process')
        }

        $argv = @('-NoProfile', '-NonInteractive', '-File', $ScriptUnderTest, '-VipmPath', $Vipm, '-DragonFile', $Dragon)
        if (-not [string]::IsNullOrWhiteSpace($LabView)) { $argv += @('-LabViewPath', $LabView) }
        if (-not [string]::IsNullOrWhiteSpace($NiRoot)) { $argv += @('-NiRoot', $NiRoot) }
        if ($ExpectedPackageCount -ne 20) { $argv += @('-ExpectedPackageCount', "$ExpectedPackageCount") }
        if ($InstallTimeoutSec -ne 3600) { $argv += @('-InstallTimeoutSec', "$InstallTimeoutSec") }
        if ($ListTimeoutSec -ne 120) { $argv += @('-ListTimeoutSec', "$ListTimeoutSec") }
        if ($WatchdogGraceSec -ne 60) { $argv += @('-WatchdogGraceSec', "$WatchdogGraceSec") }
        if ($ExtraArgs.Count -gt 0) { $argv += $ExtraArgs }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $out = & $PwshExe @argv 2>&1 | Out-String
        $stopwatch.Stop()
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $out
            Seconds  = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        }
    }
    finally {
        foreach ($key in $envKeys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    }
}

# --- main -----------------------------------------------------------------------

$script:Results = [System.Collections.Generic.List[object]]::new()
$RealIds = Get-RealDragonIds
$RealDragonHashBefore = (Get-FileHash -LiteralPath $RealDragon -Algorithm SHA256).Hash

try {
    # ------------------------------------------------------------------ T01 -----
    Test-Case 'T01-full-run-and-argv' 'real dragon: exit 0 with all 20 ids verified; exact argv; spaced paths work' {
        Assert-Equal 20 $RealIds.Count 'the repository dragon file must declare 20 vipm ids (test precondition)'
        $sandbox = New-Sandbox -Tag 't01' -Spaced
        $env = New-FakeEnvironment -Sandbox $sandbox
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds

        $r = Invoke-Bootstrap -Sandbox $sandbox -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile
        Assert-Equal 0 $r.ExitCode ("a fully bootstrapped environment must exit 0; output:`n" + $r.Output)
        Assert-NotContains $r.Output '[WARN]' 'no warning expected when the fake NI tree is complete'
        Assert-Match $r.Output ('OK: all 20 VIPM package ids declared in ' + [regex]::Escape($RealDragon)) 'the success line must name the dragon file'

        $installLines = @(Get-InstallLines -LogPath $env.ArgvLog)
        Assert-Equal 1 $installLines.Count 'exactly one install invocation expected'
        $installArgv = Get-ArgvPart -LogLine $installLines[0]
        Assert-Match $installArgv '^install -y --labview-version 2026 --timeout 3600 --color-mode never ' 'the install argv must follow the documented shape'
        $vipmSafeCopy = Join-Path (Join-Path $env:TEMP 'vipm-public-cwd') 'Lab_Super.dragon'
        Assert-Match $installArgv ([regex]::Escape($vipmSafeCopy) + '$') 'the install must run from the public-repo copy of the dragon (-VipmSafeRemote)'
        Assert-Equal (Get-FileHash -LiteralPath $RealDragon -Algorithm SHA256).Hash (Get-FileHash -LiteralPath $vipmSafeCopy -Algorithm SHA256).Hash 'the public-repo copy must be byte-identical to the dragon under test'
        Assert-NotMatch $installArgv '--vipm' 'the VIPM-only switch must stay off without -SkipNipm'
        Assert-NotMatch $installArgv '--json' 'the experimental --json flag must not be used for install'

        $listLines = @(Get-ListLines -LogPath $env.ArgvLog)
        Assert-Equal 1 $listLines.Count 'exactly one list invocation expected'
        $listArgv = Get-ArgvPart -LogLine $listLines[0]
        Assert-Match $listArgv '^list --installed --labview-version 2026 --timeout 120 --color-mode never$' 'the list argv must follow the documented shape'

        Assert-Contains $r.Output ('vipm cli       : ' + $StubCmd) 'the banner must echo the CLI actually used'
        Write-Evidence ('install argv: ' + $installArgv)
        Write-Evidence ('list argv   : ' + $listArgv)
        Write-Evidence ('spaced sandbox: ' + $sandbox)
    }

    # ------------------------------------------------------------------ T02 -----
    Test-Case 'T02-missing-vipm-no-calls' 'no VIPM CLI -> exit 2 with install guidance and zero invocations' {
        $sandbox = New-Sandbox -Tag 't02'
        $env = New-FakeEnvironment -Sandbox $sandbox
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds
        $absent = Join-Path $sandbox 'no-such-dir\vipm.exe'

        $r = Invoke-Bootstrap -Sandbox $sandbox -Vipm $absent -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile
        Assert-Equal 2 $r.ExitCode ("a missing CLI must be a preflight failure; output:`n" + $r.Output)
        Assert-Match $r.Output 'the VIPM CLI was not found' 'the failure must name the missing CLI'
        Assert-Match $r.Output 'vipm\.io/download' 'the failure must point at the VIPM download page'
        Assert-Match $r.Output 'JKI\\VI Package Manager\\support\\vipm\.exe' 'the failure must give the default CLI location'
        Assert-Match $r.Output '\-VipmPath' 'the failure must mention the -VipmPath override'
        Assert-NotContains $r.Output 'OK: all' 'a failure must never print the success summary'
        Assert-True (-not (Test-Path -LiteralPath $env.ArgvLog)) 'nothing may be invoked when the CLI is missing'
        Write-Evidence ('exit=2; stub argv log exists=' + (Test-Path -LiteralPath $env.ArgvLog))
    }

    # ------------------------------------------------------------------ T03 -----
    Test-Case 'T03-missing-two-packages-red' 'install claims success but 2 ids are missing -> exit 4, both named' {
        $sandbox = New-Sandbox -Tag 't03'
        $env = New-FakeEnvironment -Sandbox $sandbox
        $omitted = @($RealIds[0], $RealIds[5])
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds -Omit $omitted
        Write-InstallBanner -Path $env.InstallOutputFile -Count 20

        $r = Invoke-Bootstrap -Sandbox $sandbox -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile -InstallOutputFile $env.InstallOutputFile
        Assert-Equal 4 $r.ExitCode ("a half-installed environment must exit 4; output:`n" + $r.Output)
        Assert-Match $r.Output '2 of 20 declared VIPM package ids are missing' 'the failure must count the missing ids'
        Assert-Match $r.Output ('- ' + [regex]::Escape($omitted[0]) + '  \(declared version') 'the failure must name ' + $omitted[0]
        Assert-Match $r.Output ('- ' + [regex]::Escape($omitted[1]) + '  \(declared version') 'the failure must name ' + $omitted[1]
        Assert-NotContains $r.Output 'OK: all 20' 'missing packages must never be reported as success'
        Assert-NotMatch $r.Output '\[4/4\] result' 'the success result section must not be reached'
        Assert-Match $r.Output 'packages installed successfully' 'the misleading install banner must be surfaced next to the failure (install claimed 20)'
        Assert-Match $r.Output 'the environment is NOT ready' 'the failure must state that the environment is not ready'
        Assert-Equal 1 (@(Get-InstallLines -LogPath $env.ArgvLog)).Count 'install must have run (the failure happens at verification)'
        Assert-Equal 1 (@(Get-ListLines -LogPath $env.ArgvLog)).Count 'list must have run'
        Write-Evidence ('exit=4; missing ids: ' + ($omitted -join ', '))
    }

    # ------------------------------------------------------------------ T04 -----
    Test-Case 'T04-malformed-dragon' 'no section / empty section / malformed entry -> exit 2, nothing invoked' {
        $sandbox = New-Sandbox -Tag 't04'
        $env = New-FakeEnvironment -Sandbox $sandbox
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds

        $noSection = Join-Path $sandbox 'no-section.dragon'
        Write-DragonFile -Path $noSection -Content @"
[project]
labview-version = 2026

[nipm.dependencies]
ni-visa = { version = "23.5.0.49319-0+f167", feed = "ni-visa-2023 Q3-released" }
"@
        $emptySection = Join-Path $sandbox 'empty-section.dragon'
        Write-DragonFile -Path $emptySection -Content @"
[project]
labview-version = 2026

[vipm.dependencies]
"@
        $garbage = Join-Path $sandbox 'garbage.dragon'
        Write-DragonFile -Path $garbage -Content @"
[project]
labview-version = 2026

[vipm.dependencies]
oglib_appcontrol
"@

        $r1 = Invoke-Bootstrap -Sandbox $sandbox -Dragon $noSection -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile
        Assert-Equal 2 $r1.ExitCode ("a dragon without the section must fail preflight; output:`n" + $r1.Output)
        Assert-Match $r1.Output '\[vipm\.dependencies\]' 'the failure must name the missing section'

        $r2 = Invoke-Bootstrap -Sandbox $sandbox -Dragon $emptySection -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile
        Assert-Equal 2 $r2.ExitCode ("an empty section must fail preflight; output:`n" + $r2.Output)
        Assert-Match $r2.Output 'is empty - there is nothing to install or verify' 'the failure must say the section is empty'

        $r3 = Invoke-Bootstrap -Sandbox $sandbox -Dragon $garbage -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile
        Assert-Equal 2 $r3.ExitCode ("a malformed entry must fail preflight; output:`n" + $r3.Output)
        Assert-Match $r3.Output 'malformed entry in \[vipm\.dependencies\]' 'the failure must name the malformed entry'
        Assert-Match $r3.Output 'line 5' 'the failure must carry the line number'

        foreach ($r in @($r1, $r2, $r3)) {
            Assert-NotContains $r.Output 'OK: all' 'a malformed dragon must never print the success summary'
        }
        Assert-True (-not (Test-Path -LiteralPath $env.ArgvLog)) 'nothing may be invoked when the dragon file is unusable'
        Write-Evidence 'exits 2/2/2; stub argv log exists=False'
    }

    # ------------------------------------------------------------------ T05 -----
    Test-Case 'T05-idempotent-rerun' 'two consecutive runs: both exit 0, identical argv, no state change' {
        $sandbox = New-Sandbox -Tag 't05'
        $env = New-FakeEnvironment -Sandbox $sandbox
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds
        $listingHashBefore = (Get-FileHash -LiteralPath $env.ListFile -Algorithm SHA256).Hash

        $r1 = Invoke-Bootstrap -Sandbox $sandbox -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile
        Assert-Equal 0 $r1.ExitCode ("first run must exit 0; output:`n" + $r1.Output)
        $r2 = Invoke-Bootstrap -Sandbox $sandbox -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile
        Assert-Equal 0 $r2.ExitCode ("second run must exit 0 (idempotent); output:`n" + $r2.Output)

        $installLines = @(Get-InstallLines -LogPath $env.ArgvLog)
        Assert-Equal 2 $installLines.Count 'both runs must issue the install call'
        Assert-Equal (Get-ArgvPart -LogLine $installLines[0]) (Get-ArgvPart -LogLine $installLines[1]) 'the install argv must be identical across runs'
        $listLines = @(Get-ListLines -LogPath $env.ArgvLog)
        Assert-Equal 2 $listLines.Count 'both runs must issue the list call'
        Assert-Equal (Get-ArgvPart -LogLine $listLines[0]) (Get-ArgvPart -LogLine $listLines[1]) 'the list argv must be identical across runs'

        Assert-Equal (Get-FileHash -LiteralPath $RealDragon -Algorithm SHA256).Hash $RealDragonHashBefore 'the repository dragon file must never be written'
        Assert-Equal (Get-FileHash -LiteralPath $env.ListFile -Algorithm SHA256).Hash $listingHashBefore 'the installed listing fixture must not be rewritten'
        $leftovers = @(Get-ChildItem -LiteralPath $sandbox -Recurse -Force -File |
            Where-Object { $_.Name -notin @('argv.log', 'installed-list.txt', 'LabVIEW.exe') })
        Assert-Equal 0 $leftovers.Count ('the script must not create any state file: ' + (($leftovers | ForEach-Object { $_.FullName }) -join ', '))
        Assert-NotContains $r2.Output 'warning' 'a rerun of a complete environment must stay warning-free at the package level'
        Write-Evidence ('install invocations = 2, identical argv; new files in sandbox = 0')
    }

    # ------------------------------------------------------------------ T06 -----
    Test-Case 'T06-verify-only' '-VerifyOnly reads the listing but never installs' {
        $sandbox = New-Sandbox -Tag 't06'
        $env = New-FakeEnvironment -Sandbox $sandbox
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds

        $r = Invoke-Bootstrap -Sandbox $sandbox -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile -ExtraArgs @('-VerifyOnly')
        Assert-Equal 0 $r.ExitCode ("-VerifyOnly must exit 0 when all ids are present; output:`n" + $r.Output)
        Assert-Equal 0 (@(Get-InstallLines -LogPath $env.ArgvLog)).Count '-VerifyOnly must not run install'
        Assert-Equal 1 (@(Get-ListLines -LogPath $env.ArgvLog)).Count '-VerifyOnly must run list exactly once'
        Assert-Match $r.Output 'skipped: -VerifyOnly' 'the output must state that the install step was skipped on purpose'
        Assert-Match $r.Output 'OK: all 20' 'the verification itself must still run and pass'
        Write-Evidence 'install invocations = 0; list invocations = 1'
    }

    # ------------------------------------------------------------------ T07 -----
    Test-Case 'T07-hung-install' 'a hanging CLI is killed inside the watchdog budget (exit 3, no process left)' {
        $sandbox = New-Sandbox -Tag 't07'
        $env = New-FakeEnvironment -Sandbox $sandbox
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds

        $r = Invoke-Bootstrap -Sandbox $sandbox -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile `
            -StubSleepSec 60 -InstallTimeoutSec 3 -WatchdogGraceSec 2
        Assert-Equal 3 $r.ExitCode ("a hung install must fail with exit 3; output:`n" + $r.Output)
        Assert-Match $r.Output 'vipm install did not return within 5s' 'the failure must state the budget that expired'
        Assert-Match $r.Output 'process tree was killed' 'the failure must state that the CLI was killed'
        Assert-Match $r.Output 'installing is idempotent' 'the failure must tell the operator to simply re-run'
        Assert-True ($r.Seconds -lt 30) ('the watchdog must not wait for the 60s stub sleep (took ' + $r.Seconds + 's)')
        Assert-Equal 1 (@(Get-InstallLines -LogPath $env.ArgvLog)).Count 'the hung invocation must still be visible in the argv log (evidence before the kill)'
        $alive = @(Wait-NoStubProcesses -TimeoutSec 10)
        Assert-Equal 0 $alive.Count ('no vipm-stub process may survive the kill: ' + (($alive | ForEach-Object { $_.ProcessId }) -join ', '))
        Write-Evidence ('exit=3 after ' + $r.Seconds + 's (budget 5s); surviving stub processes = 0')
    }

    # ------------------------------------------------------------------ T08 -----
    Test-Case 'T08-node-too-old' 'node v18 on PATH -> exit 2 with the Node 20 guidance, nothing invoked' {
        $sandbox = New-Sandbox -Tag 't08'
        $env = New-FakeEnvironment -Sandbox $sandbox
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds
        $shimDir = Join-Path $sandbox 'shim'
        New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $shimDir 'node.cmd'), "@echo off`r`necho v18.16.0`r`nexit /b 0`r`n", $Utf8NoBom)
        $pathOverride = $shimDir + ';' + (Join-Path $env:SystemRoot 'System32')

        $r = Invoke-Bootstrap -Sandbox $sandbox -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile -PathOverride $pathOverride
        Assert-Equal 2 $r.ExitCode ("node below 20 must fail preflight; output:`n" + $r.Output)
        Assert-Match $r.Output 'Node\.js 20 or newer is required' 'the failure must state the Node requirement'
        Assert-Match $r.Output 'v18\.16\.0' 'the failure must show the version it found'
        Assert-Match $r.Output 'nodejs\.org' 'the failure must say where to get Node'
        Assert-NotContains $r.Output 'OK: all' 'a failure must never print the success summary'
        Assert-True (-not (Test-Path -LiteralPath $env.ArgvLog)) 'nothing may be invoked before the Node check fails'
        Write-Evidence 'exit=2 with the v18 shim on PATH; stub argv log exists=False'
    }

    # ------------------------------------------------------------------ T09 -----
    Test-Case 'T09-missing-labview' 'no LabVIEW.exe at -LabViewPath -> exit 2, nothing invoked' {
        $sandbox = New-Sandbox -Tag 't09'
        $env = New-FakeEnvironment -Sandbox $sandbox
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds
        $absent = Join-Path $sandbox 'no-such-dir\LabVIEW.exe'

        $r = Invoke-Bootstrap -Sandbox $sandbox -LabView $absent -NiRoot $env.NiRoot -ListFile $env.ListFile
        Assert-Equal 2 $r.ExitCode ("a missing LabVIEW must fail preflight; output:`n" + $r.Output)
        Assert-Match $r.Output 'LabVIEW was not found' 'the failure must name the missing LabVIEW'
        Assert-Match $r.Output 'vm-runner\.md' 'the failure must point at the VM install order'
        Assert-True (-not (Test-Path -LiteralPath $env.ArgvLog)) 'nothing may be invoked when LabVIEW is missing'
        Write-Evidence 'exit=2; stub argv log exists=False'
    }

    # ------------------------------------------------------------------ T10 -----
    Test-Case 'T10-ni-soft-check' 'empty NI root -> warnings for all four runtimes, still exit 0' {
        $sandbox = New-Sandbox -Tag 't10'
        $env = New-FakeEnvironment -Sandbox $sandbox -NiProducts 0
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds

        $r = Invoke-Bootstrap -Sandbox $sandbox -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile
        Assert-Equal 0 $r.ExitCode ("the NI check is soft and must not fail the bootstrap; output:`n" + $r.Output)
        Assert-Match $r.Output 'MISSING - NI-VISA Runtime' 'NI-VISA must be reported missing'
        Assert-Match $r.Output 'MISSING - NI-DAQmx Runtime' 'NI-DAQmx must be reported missing'
        Assert-Match $r.Output 'MISSING - NI-488\.2 Runtime' 'NI-488.2 must be reported missing'
        Assert-Match $r.Output 'MISSING - LabVIEW 2026 Run-Time' 'the 2026 LabVIEW Run-Time must be reported missing'
        Assert-Match $r.Output '4 of 4 products not found' 'the warning must count the missing products'
        Assert-Match $r.Output '\[WARN\] this is a SOFT check on purpose' 'the warning must state the soft semantics'
        Assert-Match $r.Output 'nipkg\.exe' 'the warning must give the authoritative follow-up command'
        Assert-Match $r.Output 'OK: all 20' 'the VIPM verification must still run and pass'
        Write-Evidence 'exit=0 with 4 NI warnings; the warning is not a silent skip'
    }

    # ------------------------------------------------------------------ T11 -----
    Test-Case 'T11-parser-and-format' 'quoted keys/comments parse; a JSON-shaped listing verifies too' {
        $sandbox = New-Sandbox -Tag 't11'
        $env = New-FakeEnvironment -Sandbox $sandbox
        $dragon = Join-Path $sandbox 'variant.dragon'
        Write-DragonFile -Path $dragon -Content @"
# fixture: quoted keys, blank lines and inline comments must parse
[project]
labview-version = 2026

[vipm.dependencies]
"oglib_appcontrol" = "6.0.0.10"     # inline comment
   ni_lib_advanced_http_client_api    =    "1.1.0.6"

[vipm.feeds]
some_feed = "https://example.invalid/feed"

[vipm]
vipc = ""
"@
        Write-JsonListing -Path $env.ListFile -Ids @('oglib_appcontrol', 'ni_lib_advanced_http_client_api')

        $r = Invoke-Bootstrap -Sandbox $sandbox -Dragon $dragon -LabView $env.LabView -NiRoot $env.NiRoot `
            -ListFile $env.ListFile -ExpectedPackageCount 2
        Assert-Equal 0 $r.ExitCode ("a two-id variant dragon plus a JSON listing must verify; output:`n" + $r.Output)
        Assert-Match $r.Output 'OK - 2 vipm package ids declared' 'the parser must count exactly the [vipm.dependencies] entries'
        Assert-Match $r.Output 'OK: all 2 VIPM package ids' 'both ids must be matched against the JSON-shaped listing'
        $installArgv = Get-ArgvPart -LogLine (@(Get-InstallLines -LogPath $env.ArgvLog))[0]
        $vipmSafeCopy = Join-Path (Join-Path $env:TEMP 'vipm-public-cwd') 'Lab_Super.dragon'
        Assert-Match $installArgv ([regex]::Escape($vipmSafeCopy) + '$') 'the install must run from the public-repo copy of the variant dragon (-VipmSafeRemote)'
        Assert-Equal (Get-FileHash -LiteralPath $dragon -Algorithm SHA256).Hash (Get-FileHash -LiteralPath $vipmSafeCopy -Algorithm SHA256).Hash 'the public-repo copy must be byte-identical to the variant dragon'
        Write-Evidence 'quoted keys + inline comments + [vipm.feeds]/[vipm] noise parsed as 2 ids; JSON listing verified'
    }

    # ------------------------------------------------------------------ T12 -----
    Test-Case 'T12-stale-extra-and-boundary' 'extra packages are fine; a substring look-alike is not; an empty listing is red' {
        # (a) stale/extra state: a machine with packages from other projects must still pass
        $sandboxA = New-Sandbox -Tag 't12a'
        $envA = New-FakeEnvironment -Sandbox $sandboxA
        Write-InstalledListing -Path $envA.ListFile -Ids ($RealIds + @('oglib_appcontrol', 'some_other_project_lib', 'mgi_lib_mgi_actor_framework_message_maker'))
        $rA = Invoke-Bootstrap -Sandbox $sandboxA -LabView $envA.LabView -NiRoot $envA.NiRoot -ListFile $envA.ListFile
        Assert-Equal 0 $rA.ExitCode ("extra installed packages must not fail the verification; output:`n" + $rA.Output)
        Assert-Match $rA.Output 'OK: all 20' 'the 20 declared ids must still verify with extra packages present'

        # (b) boundary: `oglib_appcontrol_extra` must NOT satisfy `oglib_appcontrol`
        $sandboxB = New-Sandbox -Tag 't12b'
        $envB = New-FakeEnvironment -Sandbox $sandboxB
        $target = $RealIds[0]
        Write-InstalledListing -Path $envB.ListFile -Ids $RealIds -Omit @($target)
        Add-Content -LiteralPath $envB.ListFile -Value ('  ' + $target + '_extra' + ' 9.9.9.9') -Encoding utf8NoBOM
        $rB = Invoke-Bootstrap -Sandbox $sandboxB -LabView $envB.LabView -NiRoot $envB.NiRoot -ListFile $envB.ListFile
        Assert-Equal 4 $rB.ExitCode ("a substring look-alike must not count as installed; output:`n" + $rB.Output)
        Assert-Match $rB.Output '1 of 20 declared VIPM package ids are missing' 'exactly the omitted id must be reported'
        Assert-Match $rB.Output ('- ' + [regex]::Escape($target) + '  \(declared version') ('the failure must name ' + $target)

        # (c) worst case: the listing has no packages at all
        $sandboxC = New-Sandbox -Tag 't12c'
        $envC = New-FakeEnvironment -Sandbox $sandboxC
        Write-InstalledListing -Path $envC.ListFile -Ids @('some_other_project_lib')
        $rC = Invoke-Bootstrap -Sandbox $sandboxC -LabView $envC.LabView -NiRoot $envC.NiRoot -ListFile $envC.ListFile
        Assert-Equal 4 $rC.ExitCode ("an effectively empty environment must be red; output:`n" + $rC.Output)
        Assert-Match $rC.Output '20 of 20 declared VIPM package ids are missing' 'every declared id must be reported missing'
        Assert-NotContains $rC.Output 'OK: all' 'an empty environment must never pass'
        Write-Evidence 'superset=exit 0; substring look-alike=exit 4; empty=exit 4 with 20/20 missing'
    }

    # ------------------------------------------------------------------ T13 -----
    Test-Case 'T13-hung-list' 'a hanging list call fails the verification (exit 4) instead of hanging the VM run' {
        $sandbox = New-Sandbox -Tag 't13'
        $env = New-FakeEnvironment -Sandbox $sandbox
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds

        $r = Invoke-Bootstrap -Sandbox $sandbox -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile `
            -StubSleepSec 60 -StubSleepSubcommand 'list' -ListTimeoutSec 3 -WatchdogGraceSec 2
        Assert-Equal 4 $r.ExitCode ("a hung list call must be a verification failure; output:`n" + $r.Output)
        Assert-Match $r.Output 'vipm list did not return within 5s' 'the failure must state the list budget that expired'
        Assert-Match $r.Output 'the verification did NOT pass' 'the failure must state that nothing was verified'
        Assert-True ($r.Seconds -lt 30) ('the watchdog must not wait for the 60s stub sleep (took ' + $r.Seconds + 's)')
        Assert-Equal 1 (@(Get-InstallLines -LogPath $env.ArgvLog)).Count 'the install must have completed normally'
        Assert-Equal 0 (@(Wait-NoStubProcesses -TimeoutSec 10)).Count 'no vipm-stub process may survive the kill'
        Write-Evidence ('exit=4 after ' + $r.Seconds + 's; install ran once; surviving stub processes = 0')
    }

    # ------------------------------------------------------------------ T14 -----
    Test-Case 'T14-invalid-parameters' 'bad -LabViewVersion / -InstallTimeoutSec -> exit 2 usage error, nothing invoked' {
        $sandbox = New-Sandbox -Tag 't14'
        $env = New-FakeEnvironment -Sandbox $sandbox
        Write-InstalledListing -Path $env.ListFile -Ids $RealIds

        $rBadYear = Invoke-Bootstrap -Sandbox $sandbox -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile -ExtraArgs @('-LabViewVersion', '26')
        Assert-Equal 2 $rBadYear.ExitCode ("a non-year -LabViewVersion must be a usage error; output:`n" + $rBadYear.Output)
        Assert-Match $rBadYear.Output '-LabViewVersion must be a 4-digit LabVIEW year' 'the failure must name the offending parameter'

        $rBadTimeout = Invoke-Bootstrap -Sandbox $sandbox -LabView $env.LabView -NiRoot $env.NiRoot -ListFile $env.ListFile -ExtraArgs @('-InstallTimeoutSec', '0')
        Assert-Equal 2 $rBadTimeout.ExitCode ("a non-positive timeout must be a usage error; output:`n" + $rBadTimeout.Output)
        Assert-Match $rBadTimeout.Output '-InstallTimeoutSec must be positive' 'the failure must name the offending parameter'

        Assert-True (-not (Test-Path -LiteralPath $env.ArgvLog)) 'nothing may be invoked when a parameter is invalid'
        Write-Evidence 'exit=2/2 for -LabViewVersion 26 and -InstallTimeoutSec 0; stub argv log exists=False'
    }

    # --- receipts -----------------------------------------------------------------
    Write-Host ''
    Write-Host '[receipt] stub argv log (T01):'
    $t01Roots = @($script:TmpRoots | Where-Object { $_ -match 't01' })
    if ($t01Roots.Count -gt 0) {
        $log = Join-Path $t01Roots[0] 'stub\argv.log'
        if (Test-Path -LiteralPath $log) {
            foreach ($line in @(Get-StubLines -LogPath $log)) { Write-Host ('    ' + $line) }
        }
        $listing = Join-Path $t01Roots[0] 'installed-list.txt'
        if (Test-Path -LiteralPath $listing) {
            Write-Host '[receipt] installed listing fixture (head):'
            foreach ($line in @(Get-Content -LiteralPath $listing -TotalCount 4)) { Write-Host ('    ' + $line) }
        }
    }
    Write-Host ('[receipt] surviving vipm-stub processes: ' + @(Get-LiveStubProcesses).Count)
}
finally {
    if ($KeepFixtures) {
        Write-Host ('[cleanup] -KeepFixtures set; kept: ' + (($script:TmpRoots) -join ', '))
    }
    else {
        Write-Host '[cleanup] removing fixture trees:'
        foreach ($dir in $script:TmpRoots) {
            if (Test-Path -LiteralPath $dir) {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host ('    ' + $dir + ' -> exists=' + (Test-Path -LiteralPath $dir))
            }
        }
        Write-Host ('[cleanup] surviving vipm-stub processes after cleanup: ' + @(Get-LiveStubProcesses).Count)
    }
}

# --- summary ---------------------------------------------------------------------

$passed = @($script:Results | Where-Object { $_.Ok }).Count
$failed = $script:Results.Count - $passed
Write-Host ''
Write-Host ('RESULT: ' + $passed + ' passed, ' + $failed + ' failed, ' + $script:Results.Count + ' total')
if ($failed -gt 0) {
    foreach ($failure in @($script:Results | Where-Object { -not $_.Ok })) {
        Write-Host ('  FAILED ' + $failure.Id + ': ' + $failure.Detail)
    }
    exit ([Math]::Min($failed, 125))
}
exit 0
