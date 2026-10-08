#requires -Version 7.0
<#
.SYNOPSIS
    Real (non-dry-run) tests for ci/runner/setup-runner.ps1.

.DESCRIPTION
    Every case launches the setup script as a child pwsh process (real exit codes, real
    stdout/stderr - the CLI contract), with -BinaryPath pointed at
    fixtures/runner-stub/runner-stub.cmd, a real .cmd process that records the argv it
    received (token value redacted, SHA-256 of it recorded instead), creates .runner in
    its current directory on a successful `register` and exits with $env:STUB_EXIT_CODE.

    Nothing here touches the network: the Gitea URL is only ever a string argument and
    the stub replaces gitea-runner entirely. No scheduled task is created (the suite never
    passes -ServiceTask; that path needs a real VM and is manual QA, see docs/vm-runner.md).

    Cases:
      T01 defaults-and-argv       default name/labels/capacity reach the runner; config.yaml shape
      T02 register-failure       non-zero runner exit -> exit 3, no .runner/config/temp leftovers,
                                 actionable output, no success claim
      T03 idempotent-skip        second run skips registration (exactly one register call ever)
      T04 workdir-guard          -WorkDir in a repo (real repo root, repo subdir, fake repo) refused,
                                 nothing written
      T05 token-not-leaked       sentinel token never in stdout/stderr nor in any file under the
                                 sandbox (success, failure-via-param, child-that-echoes-token)
      T06 malformed-inputs       missing token / bad URL / bad labels / bad name / bad capacity /
                                 missing -BinaryPath -> exit 2, nothing invoked, nothing written
      T07 force-reregister       -Force re-registers; a failed -Force restores the previous .runner
      T08 exit0-without-state    runner exits 0 but writes no .runner -> still a failure (exit 3)
      T09 space-in-root          a runner root containing a space works end to end

    Run:  pwsh -NoProfile -File ci/tests/setup-runner.tests.ps1
    Exit: 0 = all cases passed; N>0 = number of failed cases (capped at 125).
    -SetupScript <path> overrides the script under test (mutation testing).
#>
[CmdletBinding()]
param(
    [switch]$KeepFixtures,
    # Optional override used by mutation testing: point the suite at a deliberately broken
    # copy of the setup script to prove the assertions are not vacuous.
    [string]$SetupScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- paths ---------------------------------------------------------------------

$TestsDir = $PSScriptRoot
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $TestsDir '..\..')).ProviderPath
if ([string]::IsNullOrWhiteSpace($SetupScript)) {
    $ScriptUnderTest = (Resolve-Path -LiteralPath (Join-Path $TestsDir '..\runner\setup-runner.ps1')).ProviderPath
}
else {
    $ScriptUnderTest = (Resolve-Path -LiteralPath $SetupScript).ProviderPath
}
$StubCmd = (Resolve-Path -LiteralPath (Join-Path $TestsDir 'fixtures\runner-stub\runner-stub.cmd')).ProviderPath
$PwshExe = (Get-Command pwsh -ErrorAction Stop).Source

$Sentinel = 'SENTINEL-RUNNER-TOKEN'

Write-Host '== ci/runner/setup-runner.ps1 tests =='
Write-Host ("cwd               : " + (Get-Location).Path)
Write-Host ("script under test : " + $ScriptUnderTest + "  [exists=" + (Test-Path -LiteralPath $ScriptUnderTest) + "]")
Write-Host ("runner stub       : " + $StubCmd)
Write-Host ("repo root         : " + $RepoRoot)

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

# --- shared helpers -------------------------------------------------------------

function Get-StringSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

# Never embed the raw sentinel in a diagnostic; the token must not surface anywhere.
function Sanitize-Output {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return $Text.Replace($Sentinel, '<redacted>')
}

function Assert-NoSentinel {
    param([string]$Text, [string]$Where)
    if ($Text.Contains($Sentinel)) { throw ("ASSERT FAILED: registration token sentinel leaked into " + $Where) }
}

function Assert-NoSentinelUnder {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -File)) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        Assert-NoSentinel -Text $text -Where ("file " + $f.FullName)
    }
}

function Get-StubLogLines {
    param([string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $LogPath -Encoding utf8)
}
function Get-RegisterLines {
    param([string]$LogPath)
    return @(Get-StubLogLines -LogPath $LogPath | Where-Object { $_ -match ' argv: register( |$)' })
}

$script:TmpRoots = [System.Collections.Generic.List[string]]::new()
function New-TmpRoot {
    param([string]$Tag)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('mica-runner-test-' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    $script:TmpRoots.Add($p)
    return $p
}

# Launch the script under test as a child pwsh process with the stub wired in as the
# runner binary. Environment variables are set for the child only and always restored.
function Invoke-Setup {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ArgvLog,
        [string]$RunnerName = '',
        [string]$Token = 'SENTINEL-RUNNER-TOKEN',
        [int]$StubExitCode = 0,
        [bool]$StubCreateRunner = $true,
        [bool]$StubEchoToken = $false,
        [string]$WorkDirArg = '',
        [string]$LabelsArg = '',
        [int]$Capacity = 0,
        [string]$Instance = 'https://gitea.sevenology.top',
        [string]$Binary = '',
        [bool]$ProvideToken = $true,
        [bool]$UseTokenParam = $false,
        [string[]]$ExtraArgs = @()
    )
    $envKeys = @('STUB_ARGV_LOG', 'STUB_EXIT_CODE', 'STUB_CREATE_RUNNER', 'STUB_ECHO_TOKEN', 'GITEA_RUNNER_REGISTRATION_TOKEN')
    $saved = @{}
    foreach ($k in $envKeys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
    try {
        [Environment]::SetEnvironmentVariable('STUB_ARGV_LOG', $ArgvLog, 'Process')
        [Environment]::SetEnvironmentVariable('STUB_EXIT_CODE', "$StubExitCode", 'Process')
        [Environment]::SetEnvironmentVariable('STUB_CREATE_RUNNER', $(if ($StubCreateRunner) { '1' } else { '0' }), 'Process')
        [Environment]::SetEnvironmentVariable('STUB_ECHO_TOKEN', $(if ($StubEchoToken) { '1' } else { '0' }), 'Process')
        if ($ProvideToken -and -not $UseTokenParam) {
            [Environment]::SetEnvironmentVariable('GITEA_RUNNER_REGISTRATION_TOKEN', $Token, 'Process')
        }
        else {
            [Environment]::SetEnvironmentVariable('GITEA_RUNNER_REGISTRATION_TOKEN', $null, 'Process')
        }

        $argv = @('-NoProfile', '-NonInteractive', '-File', $ScriptUnderTest, '-RunnerRoot', $Root, '-InstanceUrl', $Instance)
        if (-not [string]::IsNullOrWhiteSpace($Binary)) { $argv += @('-BinaryPath', $Binary) }
        if (-not [string]::IsNullOrWhiteSpace($RunnerName)) { $argv += @('-Name', $RunnerName) }
        if (-not [string]::IsNullOrWhiteSpace($LabelsArg)) { $argv += @('-Labels', $LabelsArg) }
        if ($Capacity -gt 0) { $argv += @('-Capacity', "$Capacity") }
        if (-not [string]::IsNullOrWhiteSpace($WorkDirArg)) { $argv += @('-WorkDir', $WorkDirArg) }
        if ($ProvideToken -and $UseTokenParam) { $argv += @('-RegistrationToken', $Token) }
        if ($ExtraArgs.Count -gt 0) { $argv += $ExtraArgs }

        $out = & $PwshExe @argv 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
    finally {
        foreach ($k in $envKeys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
}

# --- main -----------------------------------------------------------------------

# Computed after the helpers above are defined (functions are not hoisted).
$SentinelSha = Get-StringSha256 -Text $Sentinel

$script:Results = [System.Collections.Generic.List[object]]::new()

try {
    # ------------------------------------------------------------------ T01 -----
    Test-Case 'T01-defaults-and-argv' 'defaults reach the runner; config.yaml carries labels/capacity/log level' {
        $sandbox = New-TmpRoot 't01'
        $root = Join-Path $sandbox 'runner-root'
        $log = Join-Path $sandbox 'stub\argv.log'
        # No -Name / -Labels / -Capacity / -WorkDir: the documented defaults must apply.
        $r = Invoke-Setup -Root $root -ArgvLog $log -Binary $StubCmd
        Assert-Equal 0 $r.ExitCode ("default run must exit 0; output:`n" + (Sanitize-Output $r.Output))
        Assert-NoSentinel -Text $r.Output -Where 'stdout/stderr'

        $lines = @(Get-RegisterLines -LogPath $log)
        Assert-Equal 1 $lines.Count 'exactly one register invocation expected'
        Assert-Match $lines[0] ('register --no-interactive --instance https://gitea\.sevenology\.top --token <redacted> --name mica-build-01 --labels windows-labview26:host') 'argv must carry the exact contract call shape with default values'
        Assert-Match $lines[0] ('token-sha256=' + $SentinelSha) 'argv log must prove the exact token value was passed (via SHA-256)'
        Write-Evidence ('argv: ' + $lines[0])

        $statePath = Join-Path $root '.runner'
        Assert-True (Test-Path -LiteralPath $statePath -PathType Leaf) '.runner must land in <RunnerRoot> (register ran with RunnerRoot as cwd)'

        $configPath = Join-Path $root 'config.yaml'
        Assert-True (Test-Path -LiteralPath $configPath -PathType Leaf) 'config.yaml must be generated'
        $cfg = [System.IO.File]::ReadAllText($configPath)
        Assert-Match $cfg '(?m)^\s*level:\s*info\s*$' 'config.yaml must set log.level'
        Assert-Match $cfg '(?m)^\s*capacity:\s*1\s*$' 'config.yaml must set capacity: 1'
        Assert-Match $cfg 'windows-labview26:host' 'config.yaml must carry the runner label'
        Assert-Match $cfg ('workdir_parent:\s*"' + [regex]::Escape($root.Replace('\', '/')) + '/_work"') 'config.yaml must point workdir_parent at <RunnerRoot>/_work'
        Assert-True (Test-Path -LiteralPath (Join-Path $root '_work') -PathType Container) 'default work dir must exist'

        Assert-Match $r.Output 'Settings -> Actions -> Runners' 'success output must point at the Gitea UI location'
        Assert-Match $r.Output 'Online' 'success output must ask for Online confirmation'
        Write-Evidence ('config.yaml: ' + ($cfg -split "`r?`n" | Where-Object { $_ -match 'level|capacity|labels|workdir_parent|windows-labview26' }) -join ' | ')
    }

    # ------------------------------------------------------------------ T02 -----
    Test-Case 'T02-register-failure-clean' 'non-zero runner exit -> exit 3, no leftovers, actionable output, no success claim' {
        $sandbox = New-TmpRoot 't02'
        $root = Join-Path $sandbox 'runner-root'
        $log = Join-Path $sandbox 'stub\argv.log'
        $r = Invoke-Setup -Root $root -ArgvLog $log -Binary $StubCmd -RunnerName 'mica-test-fail' -StubExitCode 7
        Assert-Equal 3 $r.ExitCode ("failed registration must exit 3; output:`n" + (Sanitize-Output $r.Output))
        Assert-NoSentinel -Text $r.Output -Where 'stdout/stderr'
        Assert-Match $r.Output 'Create new runner' 'failure output must say how to get a fresh token'
        Assert-Match $r.Output '\[register\]' 'failure output must surface the runner output'
        Assert-NotContains $r.Output 'Online' 'failure must never print the success/Online guidance'
        Assert-NotContains $r.Output 'Done. Summary' 'failure must never print the success summary'

        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.runner'))) 'no .runner may survive a failed registration'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'config.yaml'))) 'config created by the failed run must be removed'
        Assert-True (-not (Test-Path -LiteralPath $root)) 'a runner root created by the failed run must be removed (no half-products)'
        $leftovers = @(Get-ChildItem -LiteralPath $sandbox -Recurse -Force -File | Where-Object { $_.Name -like '.runner*' -or $_.Name -like '*.tmp' -or $_.Name -like '*.download' })
        Assert-Equal 0 $leftovers.Count ('no state/temp/download leftovers anywhere under the sandbox: ' + (($leftovers | ForEach-Object { $_.FullName }) -join ', '))
        Assert-Equal 1 (@(Get-RegisterLines -LogPath $log)).Count 'the stub must have been invoked exactly once'
        Write-Evidence ('exit=3; cleanup verified: .runner absent, config absent, root dir absent; stub ran 1x with exit=7')
    }

    # ------------------------------------------------------------------ T03 -----
    Test-Case 'T03-idempotent-skip' 'second run skips registration; exactly one register call across two runs' {
        $sandbox = New-TmpRoot 't03'
        $root = Join-Path $sandbox 'runner-root'
        $log = Join-Path $sandbox 'stub\argv.log'
        $name = 'mica-test-idem'

        $r1 = Invoke-Setup -Root $root -ArgvLog $log -Binary $StubCmd -RunnerName $name
        Assert-Equal 0 $r1.ExitCode ("first run must exit 0; output:`n" + (Sanitize-Output $r1.Output))
        $configBefore = [System.IO.File]::ReadAllText((Join-Path $root 'config.yaml'))
        $stateBefore = [System.IO.File]::ReadAllText((Join-Path $root '.runner'))

        $r2 = Invoke-Setup -Root $root -ArgvLog $log -Binary $StubCmd -RunnerName $name
        Assert-Equal 0 $r2.ExitCode ("idempotent rerun must exit 0; output:`n" + (Sanitize-Output $r2.Output))
        Assert-Match $r2.Output '\-Force' 'skip path must tell the operator about -Force'
        Assert-Match $r2.Output '\.runner' 'skip path must name the existing state file'
        Assert-Match $r2.Output 'Online' 'skip path is a success path and must still print the Online guidance'

        Assert-Equal 1 (@(Get-RegisterLines -LogPath $log)).Count 'registration must be skipped on the second run (single register call overall)'
        Assert-Equal $configBefore ([System.IO.File]::ReadAllText((Join-Path $root 'config.yaml'))) 'config.yaml must not be rewritten when the content is identical'
        Assert-Equal $stateBefore ([System.IO.File]::ReadAllText((Join-Path $root '.runner'))) 'existing .runner must be left untouched'
        Write-Evidence ('register invocations across 2 runs = 1; skip message contains -Force; .runner untouched')
    }

    # ------------------------------------------------------------------ T04 -----
    Test-Case 'T04-workdir-guard' '-WorkDir inside any git repo (real root, real subdir, fake repo) is refused with nothing written' {
        $cases = @(
            [pscustomobject]@{ Tag = 'repo-root'; WorkDir = $RepoRoot },
            [pscustomobject]@{ Tag = 'repo-subdir'; WorkDir = (Join-Path $RepoRoot 'ci') }
        )
        foreach ($c in $cases) {
            $sandbox = New-TmpRoot ('t04-' + $c.Tag)
            $root = Join-Path $sandbox 'runner-root'
            $log = Join-Path $sandbox 'stub\argv.log'
            $r = Invoke-Setup -Root $root -ArgvLog $log -Binary $StubCmd -RunnerName 'mica-test-guard' -WorkDirArg $c.WorkDir
            Assert-Equal 2 $r.ExitCode ("guard must fail with usage exit 2 for " + $c.WorkDir + "; output:`n" + (Sanitize-Output $r.Output))
            Assert-Contains $r.Output $c.WorkDir 'refusal must name the offending work dir'
            Assert-Match $r.Output 'git' 'refusal must explain the git-repo rule'
            Assert-True (-not (Test-Path -LiteralPath $root)) 'nothing may be created when the guard refuses'
            Assert-Equal 0 (@(Get-StubLogLines -LogPath $log)).Count 'the runner binary must never be invoked when the guard refuses'
            Write-Evidence ('refused: ' + $c.WorkDir + ' (no root dir, stub never invoked)')
        }

        # Structural check: not hardcoded to this repository - a fake repo anywhere is refused too.
        $sandbox = New-TmpRoot 't04-fake'
        $fakeRepo = Join-Path $sandbox 'fake-repo'
        New-Item -ItemType Directory -Path (Join-Path $fakeRepo '.git') -Force | Out-Null
        $workDir = Join-Path $fakeRepo 'sub'
        $root = Join-Path $sandbox 'runner-root'
        $log = Join-Path $sandbox 'stub\argv.log'
        $r = Invoke-Setup -Root $root -ArgvLog $log -Binary $StubCmd -RunnerName 'mica-test-guard' -WorkDirArg $workDir
        Assert-Equal 2 $r.ExitCode 'guard must refuse a fake repo as well'
        Assert-Contains $r.Output $fakeRepo 'refusal must name the enclosing repo root'
        Assert-True (-not (Test-Path -LiteralPath $workDir)) 'the work dir itself must not be created'
        Assert-True (-not (Test-Path -LiteralPath $root)) 'nothing may be created when the guard refuses'
        Assert-Equal 0 (@(Get-StubLogLines -LogPath $log)).Count 'stub must not run in the fake-repo case'
        Write-Evidence ('fake repo refused: ' + $workDir + ' -> names ' + $fakeRepo)
    }

    # ------------------------------------------------------------------ T05 -----
    Test-Case 'T05-token-not-leaked' 'sentinel token never in stdout/stderr nor in any sandbox file (success / failure / echoing child)' {
        # (a) success, token via environment variable
        $s1 = New-TmpRoot 't05a'
        $root1 = Join-Path $s1 'runner-root'
        $log1 = Join-Path $s1 'stub\argv.log'
        $r1 = Invoke-Setup -Root $root1 -ArgvLog $log1 -Binary $StubCmd -RunnerName 'mica-test-leak-a'
        Assert-Equal 0 $r1.ExitCode 'success run for the leak scan must exit 0'
        Assert-NoSentinel -Text $r1.Output -Where 'T05a stdout/stderr'
        Assert-NoSentinelUnder -Dir $s1
        $reg1 = @(Get-RegisterLines -LogPath $log1)
        Assert-Match $reg1[0] ('token-sha256=' + $SentinelSha) 'T05a: token must actually have been passed (hash proof)'

        # (b) failure, token via -RegistrationToken (parameter route)
        $s2 = New-TmpRoot 't05b'
        $root2 = Join-Path $s2 'runner-root'
        $log2 = Join-Path $s2 'stub\argv.log'
        $r2 = Invoke-Setup -Root $root2 -ArgvLog $log2 -Binary $StubCmd -RunnerName 'mica-test-leak-b' -StubExitCode 4 -UseTokenParam $true
        Assert-Equal 3 $r2.ExitCode 'failure run for the leak scan must exit 3'
        Assert-NoSentinel -Text $r2.Output -Where 'T05b stdout/stderr'
        Assert-NoSentinelUnder -Dir $s2
        $reg2 = @(Get-RegisterLines -LogPath $log2)
        Assert-Match $reg2[0] ('token-sha256=' + $SentinelSha) 'T05b: parameter-supplied token must have been passed (hash proof)'

        # (c) adversarial child: the runner itself echoes the token on stderr; the setup
        #     script must redact it before echoing.
        $s3 = New-TmpRoot 't05c'
        $root3 = Join-Path $s3 'runner-root'
        $log3 = Join-Path $s3 'stub\argv.log'
        $r3 = Invoke-Setup -Root $root3 -ArgvLog $log3 -Binary $StubCmd -RunnerName 'mica-test-leak-c' -StubExitCode 5 -StubEchoToken $true
        Assert-Equal 3 $r3.ExitCode 'echoing-child run must fail with exit 3'
        Assert-NoSentinel -Text $r3.Output -Where 'T05c stdout/stderr (child echoed the token; the script must redact it)'
        Assert-Match $r3.Output 'token=<redacted>' 'T05c: redaction marker must be visible instead of the value'
        Assert-NoSentinelUnder -Dir $s3
        $reg3 = @(Get-RegisterLines -LogPath $log3)
        Assert-Match $reg3[0] ('token-sha256=' + $SentinelSha) 'T05c: token must actually have been passed (hash proof)'
        Write-Evidence ('three runs: outputs + all files under each sandbox carry no sentinel; hash proofs present; child echo redacted to token=<redacted>')
    }

    # ------------------------------------------------------------------ T06 -----
    Test-Case 'T06-malformed-inputs' 'missing token / bad URL / bad labels / bad name / bad capacity / missing binary -> exit 2, nothing written' {
        $variants = @(
            [pscustomobject]@{ Tag = 'no-token'; Args = @{}; ExpectText = 'GITEA_RUNNER_REGISTRATION_TOKEN' },
            [pscustomobject]@{ Tag = 'bad-url'; Args = @{ Instance = 'not-a-url' }; ExpectText = 'not-a-url' },
            [pscustomobject]@{ Tag = 'bad-labels'; Args = @{ LabelsArg = 'windows-labview26' }; ExpectText = 'windows-labview26' },
            [pscustomobject]@{ Tag = 'bad-name'; Args = @{ RunnerName = 'bad name!' }; ExpectText = 'bad name!' },
            [pscustomobject]@{ Tag = 'bad-capacity'; Args = @{ ExtraArgs = @('-Capacity', '0') }; ExpectText = 'Capacity' },
            [pscustomobject]@{ Tag = 'missing-binary'; Args = @{}; ExpectText = 'does-not-exist' }
        )
        foreach ($v in $variants) {
            $sandbox = New-TmpRoot ('t06-' + $v.Tag)
            $root = Join-Path $sandbox 'runner-root'
            $log = Join-Path $sandbox 'stub\argv.log'
            $callArgs = @{ Root = $root; ArgvLog = $log; RunnerName = 'mica-test-malformed' }
            foreach ($k in $v.Args.Keys) { $callArgs[$k] = $v.Args[$k] }
            if ($v.Tag -eq 'no-token') { $callArgs['ProvideToken'] = $false }
            if ($v.Tag -eq 'missing-binary') { $callArgs['Binary'] = (Join-Path $sandbox 'does-not-exist\gitea-runner.exe') }
            else { $callArgs['Binary'] = $StubCmd }

            $r = Invoke-Setup @callArgs
            Assert-Equal 2 $r.ExitCode ("malformed input '" + $v.Tag + "' must exit 2; output:`n" + (Sanitize-Output $r.Output))
            Assert-Contains $r.Output $v.ExpectText ("the diagnostic for '" + $v.Tag + "' must name the offending value/source")
            Assert-True (-not (Test-Path -LiteralPath $root)) ("nothing may be created for '" + $v.Tag + "'")
            Assert-Equal 0 (@(Get-StubLogLines -LogPath $log)).Count ("the runner binary must not run for '" + $v.Tag + "'")
            Write-Evidence ("'" + $v.Tag + "' -> exit 2, names [" + $v.ExpectText + "], nothing created")
        }
    }

    # ------------------------------------------------------------------ T07 -----
    Test-Case 'T07-force-reregister' '-Force re-registers with the new parameters; a failed -Force restores the previous .runner' {
        $sandbox = New-TmpRoot 't07'
        $root = Join-Path $sandbox 'runner-root'
        $log = Join-Path $sandbox 'stub\argv.log'
        $name = 'mica-test-force'

        $r1 = Invoke-Setup -Root $root -ArgvLog $log -Binary $StubCmd -RunnerName $name
        Assert-Equal 0 $r1.ExitCode 'first registration must succeed'
        $stateHashBefore = (Get-FileHash -LiteralPath (Join-Path $root '.runner') -Algorithm SHA256).Hash

        # -Force with explicit labels/capacity: must re-register and rewrite config.
        $r2 = Invoke-Setup -Root $root -ArgvLog $log -Binary $StubCmd -RunnerName $name -ExtraArgs @('-Force') -LabelsArg 'windows-labview26:host' -Capacity 2
        Assert-Equal 0 $r2.ExitCode ("forced re-register must exit 0; output:`n" + (Sanitize-Output $r2.Output))
        Assert-Equal 2 (@(Get-RegisterLines -LogPath $log)).Count '-Force must trigger a second register call'
        $cfg = [System.IO.File]::ReadAllText((Join-Path $root 'config.yaml'))
        Assert-Match $cfg '(?m)^\s*capacity:\s*2\s*$' 'explicit -Capacity 2 must be rendered into config.yaml'
        Assert-True (Test-Path -LiteralPath (Join-Path $root '.runner')) '.runner must exist after a successful -Force'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.runner.bak'))) '.runner.bak must not survive a successful -Force'
        Write-Evidence ('forced rerun: register calls=2, capacity=2 in config, no .runner.bak')

        # -Force fails: the displaced registration must be rolled back intact.
        $r3 = Invoke-Setup -Root $root -ArgvLog $log -Binary $StubCmd -RunnerName $name -ExtraArgs @('-Force') -StubExitCode 9
        Assert-Equal 3 $r3.ExitCode 'failed -Force must exit 3'
        Assert-NotContains $r3.Output 'Online' 'failed -Force must not claim success'
        $stateHashAfter = (Get-FileHash -LiteralPath (Join-Path $root '.runner') -Algorithm SHA256).Hash
        Assert-Equal $stateHashBefore $stateHashAfter 'the pre-existing .runner must be restored byte-identical after a failed -Force'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.runner.bak'))) '.runner.bak must be gone after rollback'
        Assert-True (Test-Path -LiteralPath (Join-Path $root 'config.yaml')) 'config.yaml that existed before the failed -Force must not be deleted'
        Assert-Equal 3 (@(Get-RegisterLines -LogPath $log)).Count 'third register call (failed) must be recorded'
        Write-Evidence ('failed -Force: exit 3, .runner restored (sha equal), .runner.bak removed, config preserved')
    }

    # ------------------------------------------------------------------ T08 -----
    Test-Case 'T08-exit0-without-state' 'runner exits 0 but writes no .runner -> failure (exit 3), never reported as success' {
        $sandbox = New-TmpRoot 't08'
        $root = Join-Path $sandbox 'runner-root'
        $log = Join-Path $sandbox 'stub\argv.log'
        $r = Invoke-Setup -Root $root -ArgvLog $log -Binary $StubCmd -RunnerName 'mica-test-nostate' -StubCreateRunner $false
        Assert-Equal 3 $r.ExitCode ('exit code 0 from the child with no .runner must still fail; output:' + "`n" + (Sanitize-Output $r.Output))
        Assert-Match $r.Output '\.runner' 'failure must name the missing state file'
        Assert-NotContains $r.Output 'Online' 'must not claim success when registration state is missing'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.runner'))) '.runner must not miraculously exist'
        Assert-True (-not (Test-Path -LiteralPath $root)) 'no half-products may be left behind'
        Write-Evidence ('child exit=0 but no .runner -> script exit=3, cleanup verified')
    }

    # ------------------------------------------------------------------ T09 -----
    Test-Case 'T09-space-in-root' 'a runner root containing a space works end to end' {
        $sandbox = New-TmpRoot 't09'
        $root = Join-Path $sandbox 'runner root with space'
        $log = Join-Path $sandbox 'stub logs\argv.log'
        $r = Invoke-Setup -Root $root -ArgvLog $log -Binary $StubCmd -RunnerName 'mica-test-space'
        Assert-Equal 0 $r.ExitCode ("spaced root must work; output:`n" + (Sanitize-Output $r.Output))
        Assert-True (Test-Path -LiteralPath (Join-Path $root '.runner') -PathType Leaf) '.runner must land in the spaced root'
        $cfg = [System.IO.File]::ReadAllText((Join-Path $root 'config.yaml'))
        Assert-Match $cfg ('workdir_parent:\s*"' + [regex]::Escape($root.Replace('\', '/')) + '/_work"') 'spaced workdir_parent must be rendered correctly'
        Assert-Equal 1 (@(Get-RegisterLines -LogPath $log)).Count 'register must have been invoked once through the spaced log path'
        Write-Evidence ('spaced root OK: ' + $root + ' ; argv log at ' + $log)
    }

    # --- receipts -----------------------------------------------------------------
    Write-Host ''
    Write-Host '[receipt] last argv log excerpt (T01):'
    $t01Roots = @($script:TmpRoots | Where-Object { $_ -match 't01' })
    if ($t01Roots.Count -gt 0) {
        foreach ($l in @(Get-StubLogLines -LogPath (Join-Path $t01Roots[0] 'stub\argv.log'))) {
            Write-Host ('    ' + (Sanitize-Output $l))
        }
        $cfgPath = Join-Path $t01Roots[0] 'runner-root\config.yaml'
        if (Test-Path -LiteralPath $cfgPath) {
            Write-Host '[receipt] rendered config.yaml:'
            foreach ($cl in @([System.IO.File]::ReadAllText($cfgPath) -split "`r?`n")) { Write-Host ('    ' + $cl) }
        }
    }
}
finally {
    if ($KeepFixtures) {
        Write-Host ('[cleanup] -KeepFixtures set; kept: ' + (($script:TmpRoots) -join ', '))
    }
    else {
        Write-Host '[cleanup] removing fixture trees:'
        foreach ($d in $script:TmpRoots) {
            if (Test-Path -LiteralPath $d) {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host ('    ' + $d + ' -> exists=' + (Test-Path -LiteralPath $d))
            }
        }
    }
}

# --- summary ---------------------------------------------------------------------

$passed = @($script:Results | Where-Object { $_.Ok }).Count
$failed = $script:Results.Count - $passed
Write-Host ''
Write-Host ('RESULT: ' + $passed + ' passed, ' + $failed + ' failed, ' + $script:Results.Count + ' total')
if ($failed -gt 0) {
    foreach ($f in @($script:Results | Where-Object { -not $_.Ok })) {
        Write-Host ('  FAILED ' + $f.Id + ': ' + $f.Detail)
    }
    exit ([Math]::Min($failed, 125))
}
exit 0
