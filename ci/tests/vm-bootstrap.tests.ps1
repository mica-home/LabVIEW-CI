#requires -Version 7.0
<#
.SYNOPSIS
    Real (non-dry-run) tests for ci/runner/vm-bootstrap.ps1.

.DESCRIPTION
    Every case launches the bootstrap script as a child pwsh process (real exit codes, real
    stdout/stderr) with the system side effects replaced by real stand-in processes:

      * gitea-runner      -> fixtures/runner-stub/runner-stub.cmd (records the argv it got,
                             records the SHA-256 of GITEA_RUNNER_REGISTRATION_TOKEN instead
                             of its value, creates .runner on a successful register)
      * winget / node     -> tiny .cmd stubs written into the sandbox (a Node probe that
                             "installs" itself through the winget stub, or fails, or hangs)
      * Task Scheduler    -> a PowerShell backend stub (-TaskBackend) recording the
                             install/start/status/uninstall verbs
      * Gitea raw API     -> fixtures/api-stub.mjs with --raw-dir (the real
                             ci/bootstrap-deps.ps1 is served under the kit slug and the real
                             Lab_Super.dragon under the MICA slug, so the Phase 3 child is
                             the REAL script) and --raw-status 401/404; the same stub also
                             answers the GitHub contents shape for the kit fetch
      * GitHub kit fetch  -> the kit script is fetched through the GitHub contents API
                             (default -KitForge github), pointed at the loopback stub with
                             -KitApiBase. The public kit is fetched ANONYMOUSLY (no
                             Authorization header) unless -GitHubToken is given (a sentinel
                             separate from the Gitea registration token), which then
                             travels as Bearer + is proven by its sha256 in the stub log
      * VIPM              -> fixtures/vipm-stub (driven by the real bootstrap-deps.ps1)

    Nothing here touches gitea.sevenology.top, dl.gitea.com, a real VIPM, a real Node
    install or the Task Scheduler. -RunnerBinaryPath / -NodeCommand / -WingetCommand /
    -TaskBackend are the seams that keep those out; every HTTP request goes to the
    loopback api-stub and the request log is checked for that.

    Cases:
      T01 preflight-report     hostname / IPv4 / OS / disks / node / LabVIEW / VIPM probes
                               and the manual-install checklist land in preflight.json
      T02 register-and-task    argv shape, config.yaml, .runner, SYSTEM/AtStartup task
                               verbs; the token sentinel appears in NO output and NO file
      T03 phase3-raw-deps      kit fetched through the GitHub contents route and the dragon
                               through the Gitea raw route, both byte-identical from their
                               own repos, and the real bootstrap-deps.ps1 invoked with the
                               staged dragon
      T04 idempotency-resume   second run skips both phases (1 register call, 2 fetches),
                               a missing phase marker resumes that phase, -Force redoes it
      T05 phase1-node          skip when >= 20; winget path + re-probe; winget failure ->
                               exit 6 with the MSI page; hung winget -> exit 6 within budget
      T06 fetch-failures       401 / 404 / hung raw fetch -> exit 3 + manual fallback, no
                               bootstrap-deps run, no phase marker
      T07 misleading-success   exit 0 without .runner, task install/start/status failures,
                               and a child that echoes the token: all red, cleanup verified
      T08 zero-external-calls  every request in the api-stub log went to 127.0.0.1
      T09 kit-anonymous        no -GitHubToken: the public kit is fetched with NO
                               Authorization header (scheme none, no sha); the same fetch
                               with -GitHubToken sends Bearer + the sha proof
      T10 manual-fallback      staged files + -SkipRunner (no token) run Phase 3 offline
      T11 spaced-paths         a runner root / stage dir containing spaces works end to end
      T12 malformed-inputs     empty token / bad URL / capacity 0 / bad slug / bad ref /
                               missing binary / zero timeout -> exit 2, nothing created, no
                               HTTP request at all

    Run:  pwsh -NoProfile -File ci/tests/vm-bootstrap.tests.ps1
    Exit: 0 = all cases passed; N>0 = number of failed cases (capped at 125).
    -SetupScript <path> overrides the script under test (mutation testing).
#>
[CmdletBinding()]
param(
    [switch]$KeepFixtures,
    # Optional override used by mutation testing: point the suite at a deliberately broken
    # copy of the bootstrap script to prove the assertions are not vacuous.
    [string]$SetupScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- paths ---------------------------------------------------------------------

$TestsDir = $PSScriptRoot
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $TestsDir '..\..')).ProviderPath
if ([string]::IsNullOrWhiteSpace($SetupScript)) {
    $ScriptUnderTest = (Resolve-Path -LiteralPath (Join-Path $TestsDir '..\runner\vm-bootstrap.ps1')).ProviderPath
}
else {
    $ScriptUnderTest = (Resolve-Path -LiteralPath $SetupScript).ProviderPath
}
$RunnerStubCmd = (Resolve-Path -LiteralPath (Join-Path $TestsDir 'fixtures\runner-stub\runner-stub.cmd')).ProviderPath
$VipmStubCmd = (Resolve-Path -LiteralPath (Join-Path $TestsDir 'fixtures\vipm-stub\vipm-stub.cmd')).ProviderPath
$ApiStubScript = (Resolve-Path -LiteralPath (Join-Path $TestsDir 'fixtures\api-stub.mjs')).ProviderPath
$RealDragon = (Resolve-Path -LiteralPath (Join-Path $RepoRoot 'Lab_Super.dragon')).ProviderPath
$RealDeps = (Resolve-Path -LiteralPath (Join-Path $RepoRoot 'ci\bootstrap-deps.ps1')).ProviderPath
$PwshExe = (Get-Command pwsh -ErrorAction Stop).Source
$NodeExe = (Get-Command node -ErrorAction Stop).Source

$Sentinel = 'SENTINEL-BOOTSTRAP-TOKEN'
# Separate credential for the GitHub kit fetch (-GitHubToken): never the Gitea token, so a
# mix-up between the two auth paths is visible in the api-stub's authSha256 proof.
$GhSentinel = 'SENTINEL-BOOTSTRAP-GH-TOKEN'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

Write-Host '== ci/runner/vm-bootstrap.ps1 tests =='
Write-Host ("cwd               : " + (Get-Location).Path)
Write-Host ("script under test : " + $ScriptUnderTest + "  [exists=" + (Test-Path -LiteralPath $ScriptUnderTest) + "]")
Write-Host ("runner stub       : " + $RunnerStubCmd)
Write-Host ("vipm stub         : " + $VipmStubCmd)
Write-Host ("api stub          : " + $ApiStubScript)
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
        # Some files are held open by a live stub process (its redirected stdout/stderr);
        # open them shared-write instead of skipping them, so nothing escapes the scan.
        $fs = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = [System.IO.StreamReader]::new($fs)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $fs.Dispose() }
        Assert-NoSentinel -Text $text -Where ("file " + $f.FullName)
    }
}

function Get-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return [int]$listener.LocalEndpoint.Port }
    finally { $listener.Stop() }
}

$script:TmpRoots = [System.Collections.Generic.List[string]]::new()
$script:StubProcs = [System.Collections.Generic.List[object]]::new()
$script:StubPorts = [System.Collections.Generic.List[int]]::new()

function New-Sandbox {
    param([string]$Tag)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('mica-vb-' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    $script:TmpRoots.Add($p)
    return $p
}

# --- stub writers ---------------------------------------------------------------

function New-NodeStub {
    # v18.0.0 until the flip marker exists, v24.19.0 afterwards: models "winget installed it".
    param([Parameter(Mandatory = $true)][string]$Sandbox)
    $dir = Join-Path $Sandbox 'node-stub'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stub = Join-Path $dir 'node.cmd'
    $flip = Join-Path $dir 'installed.flag'
    $lines = @(
        '@echo off',
        ('if exist "' + $flip + '" (echo v24.19.0) else (echo v18.0.0)'),
        'exit /b 0'
    )
    [System.IO.File]::WriteAllLines($stub, $lines, $Utf8NoBom)
    return [pscustomobject]@{ Cmd = $stub; FlipMarker = $flip }
}

function New-WingetStub {
    param(
        [Parameter(Mandatory = $true)][string]$Sandbox,
        [int]$ExitCode = 0,
        [int]$SleepSec = 0,
        [string]$FlipMarker = ''
    )
    $dir = Join-Path $Sandbox 'winget-stub'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stub = Join-Path $dir 'winget.cmd'
    $log = Join-Path $dir 'argv.log'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('@echo off')
    $lines.Add('>>"' + $log + '" echo argv: %*')
    if (-not [string]::IsNullOrWhiteSpace($FlipMarker)) { $lines.Add('>"' + $FlipMarker + '" echo installed') }
    if ($SleepSec -gt 0) { $lines.Add('ping -n ' + ($SleepSec + 1) + ' 127.0.0.1 >nul') }
    $lines.Add('exit /b ' + $ExitCode)
    [System.IO.File]::WriteAllLines($stub, $lines.ToArray(), $Utf8NoBom)
    return [pscustomobject]@{ Cmd = $stub; Log = $log }
}

function New-TaskStub {
    # Real executable stand-in for the Windows Task Scheduler verbs used by the bootstrap
    # script. Exit codes come from STUB_TASK_* environment variables (set by Invoke-Bootstrap).
    param([Parameter(Mandatory = $true)][string]$Sandbox)
    $dir = Join-Path $Sandbox 'task-stub'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stub = Join-Path $dir 'task-stub.ps1'
    $log = Join-Path $dir 'argv.log'
    $content = @'
param(
    [string]$Verb = '',
    [string]$TaskName = '',
    [string]$Execute = '',
    [string]$Arguments = '',
    [string]$WorkingDirectory = '',
    [string]$Trigger = '',
    [string]$UserId = '',
    [string]$LogPath = '',
    [string]$ProcessName = '',
    [int]$TimeoutSec = 0,
    [switch]$Force
)
$log = $env:STUB_TASK_LOG
$line = 'verb=' + $Verb + ' task=' + $TaskName + ' execute=' + $Execute + ' args=' + $Arguments +
    ' wd=' + $WorkingDirectory + ' trigger=' + $Trigger + ' user=' + $UserId +
    ' proc=' + $ProcessName + ' timeout=' + $TimeoutSec + ' force=' + $Force.IsPresent
$dir = Split-Path -Parent $log
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Add-Content -LiteralPath $log -Value $line -Encoding utf8NoBOM
$code = 0
if ($Verb -eq 'install') { $code = [int]$env:STUB_TASK_INSTALL_EXIT }
if ($Verb -eq 'start') { $code = [int]$env:STUB_TASK_START_EXIT }
if ($Verb -eq 'status') { $code = [int]$env:STUB_TASK_STATUS_EXIT }
exit $code
'@
    [System.IO.File]::WriteAllText($stub, $content, $Utf8NoBom)
    return [pscustomobject]@{ Script = $stub; Log = $log }
}

function Start-ApiStub {
    param(
        [Parameter(Mandatory = $true)][string]$Sandbox,
        [string]$RawDir = '',
        [int]$RawStatus = 0,
        [string]$HangOn = ''
    )
    $dir = Join-Path $Sandbox 'api-stub'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $log = Join-Path $dir 'requests.jsonl'
    $port = Get-FreePort
    # NOTE: every element is built into its own variable first - mixing "+" with "," inside
    # one array literal is a precedence trap (the comma binds tighter) and silently merges
    # elements into one quoted blob.
    $stubArg = '"' + $ApiStubScript + '"'
    $logArg = '"' + $log + '"'
    $argv = @($stubArg, "$port", $logArg)
    if (-not [string]::IsNullOrWhiteSpace($RawDir)) {
        $rawArg = '"' + $RawDir + '"'
        $argv += @('--raw-dir', $rawArg)
    }
    if ($RawStatus -gt 0) { $argv += @('--raw-status', "$RawStatus") }
    if (-not [string]::IsNullOrWhiteSpace($HangOn)) {
        $hangArg = '"' + $HangOn + '"'
        $argv += @('--hang-on', $hangArg)
    }
    Write-Host ('    api-stub argv: ' + ($argv -join ' '))
    $p = Start-Process -FilePath $NodeExe -ArgumentList $argv -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $dir 'stdout.log') -RedirectStandardError (Join-Path $dir 'stderr.log')
    $script:StubProcs.Add($p)
    $script:StubPorts.Add($port)
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            Invoke-RestMethod -Uri ("http://127.0.0.1:" + $port + "/__state") -TimeoutSec 2 | Out-Null
            $ready = $true
            break
        }
        catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ready) { throw ("api-stub did not become ready on port " + $port) }
    return [pscustomobject]@{ Port = $port; Log = $log; Base = ("http://127.0.0.1:" + $port); Dir = $dir }
}

function Get-ApiRequests {
    param([string]$LogPath, [switch]$RawOnly)
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return @() }
    $all = @()
    foreach ($line in [System.IO.File]::ReadAllLines($LogPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $obj = $line | ConvertFrom-Json
        if ($RawOnly -and -not ($obj.PSObject.Properties.Name -contains 'raw')) { continue }
        $all += $obj
    }
    return @($all)
}

function Get-ScriptRequests {
    # The harness's own readiness probe (/__state) is not a request made by the script
    # under test, so it is excluded whenever "the script made no call" is asserted.
    param([string]$LogPath)
    return @(Get-ApiRequests -LogPath $LogPath | Where-Object { $_.path -ne '/__state' })
}

# --- dragon / vipm fixtures -----------------------------------------------------

function Get-RealDragonIds {
    # Independent mini-parser so the fixture is not a copy of the production parser's opinion.
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

function New-DepsFixture {
    # Serves the REAL ci/bootstrap-deps.ps1 and Lab_Super.dragon through the raw route and
    # points the child's LabVIEW/NI/VIPM probes at sandbox stand-ins.
    param([Parameter(Mandatory = $true)][string]$Sandbox)
    $served = Join-Path $Sandbox 'served'
    New-Item -ItemType Directory -Path (Join-Path $served 'ci') -Force | Out-Null
    Copy-Item -LiteralPath $RealDeps -Destination (Join-Path $served 'ci\bootstrap-deps.ps1') -Force
    Copy-Item -LiteralPath $RealDragon -Destination (Join-Path $served 'Lab_Super.dragon') -Force
    $fake = Join-Path $Sandbox 'fake'
    New-Item -ItemType Directory -Path $fake -Force | Out-Null
    $labview = Join-Path $fake 'LabVIEW.exe'
    [System.IO.File]::WriteAllText($labview, 'stub-labview-not-a-real-binary', $Utf8NoBom)
    $niRoot = Join-Path $fake 'NI'
    foreach ($rel in @('NI-488.2', 'Shared\NI-VISA', 'NI-DAQ', 'Shared\LabVIEW Run-Time\2026')) {
        New-Item -ItemType Directory -Path (Join-Path $niRoot $rel) -Force | Out-Null
    }
    $listFile = Join-Path $Sandbox 'installed-list.txt'
    Write-InstalledListing -Path $listFile -Ids (Get-RealDragonIds)
    return [pscustomobject]@{
        Served   = $served
        LabView  = $labview
        NiRoot   = $niRoot
        ListFile = $listFile
        ArgvLog  = (Join-Path $Sandbox 'vipm-stub\argv.log')
    }
}

# --- launching the script under test --------------------------------------------

function Invoke-Bootstrap {
    param(
        [Parameter(Mandatory = $true)][string]$Sandbox,
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$RunnerRoot,
        [string]$Token = $Sentinel,
        [bool]$ProvideToken = $true,
        [string]$Instance = 'https://gitea.sevenology.top',
        [string]$RepoSlug = 'MICA/MICA',
        [string]$Ref = 'dev',
        [string]$RunnerBinary = '',
        [string]$TaskBackend = '',
        [string]$NodeCommand = '',
        [string]$WingetCommand = '',
        [string]$VipmPath = '',
        [string]$LabViewPath = '',
        [string]$NiRoot = '',
        [string]$DepsScript = '',
        # The GitHub kit fetch token. Defaults to the GH sentinel (Bearer + sha proof); an
        # explicitly EMPTY value omits the argument entirely, which drives the anonymous
        # no-Authorization kit fetch (the public repository needs no token).
        [string]$GitHubToken = $GhSentinel,
        # Base URL for the GitHub contents route; point it at the api-stub.
        [string]$KitApiBase = '',
        [int]$Capacity = 0,
        [hashtable]$Env = @{},
        [string[]]$ExtraArgs = @(),
        [int]$TimeoutSec = 300
    )
    $argv = @('-NoProfile', '-NonInteractive', '-File', $ScriptUnderTest,
        '-StageDir', $StageDir, '-RunnerRoot', $RunnerRoot,
        '-InstanceUrl', $Instance, '-RepoSlug', $RepoSlug, '-Ref', $Ref)
    if ($Capacity -gt 0) { $argv += @('-Capacity', "$Capacity") }
    if ($ProvideToken) { $argv += @('-RegistrationToken', $Token) }
    if (-not [string]::IsNullOrWhiteSpace($RunnerBinary)) { $argv += @('-RunnerBinaryPath', $RunnerBinary) }
    if (-not [string]::IsNullOrWhiteSpace($TaskBackend)) { $argv += @('-TaskBackend', $TaskBackend) }
    if (-not [string]::IsNullOrWhiteSpace($NodeCommand)) { $argv += @('-NodeCommand', $NodeCommand) }
    if (-not [string]::IsNullOrWhiteSpace($WingetCommand)) { $argv += @('-WingetCommand', $WingetCommand) }
    if (-not [string]::IsNullOrWhiteSpace($VipmPath)) { $argv += @('-VipmPath', $VipmPath) }
    if (-not [string]::IsNullOrWhiteSpace($LabViewPath)) { $argv += @('-LabViewPath', $LabViewPath) }
    if (-not [string]::IsNullOrWhiteSpace($NiRoot)) { $argv += @('-NiRoot', $NiRoot) }
    if (-not [string]::IsNullOrWhiteSpace($DepsScript)) { $argv += @('-DepsScript', $DepsScript) }
    if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) { $argv += @('-GitHubToken', $GitHubToken) }
    if (-not [string]::IsNullOrWhiteSpace($KitApiBase)) { $argv += @('-KitApiBase', $KitApiBase) }
    if ($ExtraArgs.Count -gt 0) { $argv += $ExtraArgs }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PwshExe
    foreach ($a in $argv) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Drop anything this suite must control explicitly, THEN apply the case's own values.
    # The suite never hands the token in through the environment unless a case asks for it:
    # the script under test must obtain it from -RegistrationToken (or its own prompt).
    foreach ($stale in @('GITEA_RUNNER_REGISTRATION_TOKEN', 'GITHUB_TOKEN', 'STUB_ARGV_LOG', 'STUB_EXIT_CODE', 'STUB_CREATE_RUNNER',
            'STUB_ECHO_TOKEN', 'STUB_ECHO_ENV_TOKEN', 'STUB_TASK_LOG', 'STUB_TASK_INSTALL_EXIT',
            'STUB_TASK_START_EXIT', 'STUB_TASK_STATUS_EXIT', 'STUB_LIST_FILE', 'STUB_INSTALL_OUTPUT_FILE',
            'STUB_SLEEP_SEC', 'STUB_SLEEP_SUBCOMMAND')) {
        [void]$psi.Environment.Remove($stale)
    }
    foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()  # a prompt can never hang: it sees EOF immediately
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $finished = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) { try { $proc.Kill($true) } catch { } ; [void]$proc.WaitForExit(5000) }
    $stopwatch.Stop()
    $text = $outTask.Result + $errTask.Result
    $exitCode = 127
    if ($finished) { try { $exitCode = $proc.ExitCode } catch { $exitCode = 127 } }
    try { $proc.Dispose() } catch { }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $text
        TimedOut = -not $finished
        Seconds  = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    }
}

function Get-Lines {
    param([string]$Path, [string]$Pattern = '')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $lines = @(Get-Content -LiteralPath $Path -Encoding utf8)
    if ([string]::IsNullOrWhiteSpace($Pattern)) { return $lines }
    return @($lines | Where-Object { $_ -match $Pattern })
}

# --- main -----------------------------------------------------------------------

$script:Results = [System.Collections.Generic.List[object]]::new()
$RealIds = Get-RealDragonIds
$SentinelSha = Get-StringSha256 -Text $Sentinel

try {
    # ------------------------------------------------------------------ T01 -----
    Test-Case 'T01-preflight-report' 'Phase 0 probes (host, IPv4, OS, disks, node, LabVIEW, VIPM) land in preflight.json' {
        Assert-Equal 20 $RealIds.Count 'test precondition: the repository dragon file declares 20 vipm ids (the tripwire count of the kit bootstrap-deps.ps1)'
        $sandbox = New-Sandbox 't01'
        $stage = Join-Path $sandbox 'stage'
        $root = Join-Path $sandbox 'runner-root'
        $r = Invoke-Bootstrap -Sandbox $sandbox -StageDir $stage -RunnerRoot $root -ProvideToken $false -ExtraArgs @('-SkipNode', '-SkipRunner', '-SkipDeps')
        Assert-Equal 0 $r.ExitCode ("preflight-only run must exit 0; output:`n" + (Sanitize-Output $r.Output))
        Assert-NotContains $r.Output 'paste the registration token' 'no token prompt may happen when nothing needs a token'

        $preflightPath = Join-Path $stage 'preflight.json'
        Assert-True (Test-Path -LiteralPath $preflightPath -PathType Leaf) 'preflight.json must be written to <StageDir>'
        $raw = [System.IO.File]::ReadAllText($preflightPath)
        Assert-NoSentinel -Text $raw -Where 'preflight.json'
        $pf = $raw | ConvertFrom-Json

        Assert-Equal $env:COMPUTERNAME $pf.hostname 'hostname must be reported'
        Assert-True ($pf.ipv4.Count -ge 1) 'at least one IPv4 address must be reported'
        $nonLoopback = 0
        foreach ($ip in $pf.ipv4) {
            Assert-Match ([string]$ip) '^\d{1,3}(\.\d{1,3}){3}$' ('every entry must look like an IPv4 address: ' + $ip)
            if ($ip -ne '127.0.0.1') { $nonLoopback++ }
        }
        Assert-True ($nonLoopback -ge 1) 'a non-loopback IPv4 address must be present'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$pf.os.caption)) 'OS caption must be reported'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$pf.os.version)) 'OS version must be reported'
        Assert-True ($pf.isAdmin -is [bool]) 'isAdmin must be a boolean'
        Assert-True ($null -ne $pf.disks) 'disks must be reported'
        $systemDisk = @($pf.disks | Where-Object { $_.drive -eq 'system' })[0]
        Assert-True ($null -ne $systemDisk) 'the system drive entry must exist'
        Assert-True ($systemDisk.exists -eq $true) 'the system drive must be readable'
        Assert-True ($null -ne $systemDisk.freeGb) 'system free space must be reported'
        $dDisk = @($pf.disks | Where-Object { $_.drive -eq 'D:' })[0]
        Assert-True ($null -ne $dDisk) 'the D: entry must exist (even when the drive does not)'
        Assert-True ($pf.node.found -eq $true) ('the test machine must have node on PATH (probe: ' + [string]$pf.node.detail + ')')
        Assert-Match ([string]$pf.node.version) '^v\d+\.' 'node version must be recorded'
        Assert-True ($pf.node.ok -eq $true) 'node must be reported as >= 20 on the test machine'
        Assert-Match ([string]$pf.labview.path) 'LabVIEW\.exe$' 'the LabVIEW probe path must be recorded'
        Assert-Match ([string]$pf.vipm.path) 'vipm\.exe$' 'the VIPM probe path must be recorded'
        Assert-True ($pf.plan.tokenRequired -eq $false) 'no token may be required for a -SkipNode -SkipRunner -SkipDeps run'
        Assert-Equal 900 $pf.timeouts.wingetSec 'the winget timeout must be recorded in the report'
        Assert-Equal 300 $pf.timeouts.downloadSec 'the download timeout must be recorded in the report'
        Assert-Equal 120 $pf.timeouts.registerSec 'the register timeout must be recorded in the report'

        $items = @($pf.manualItems | ForEach-Object { [string]$_.item })
        Assert-True ($items.Count -ge 6) 'the manual-install checklist must list LabVIEW, the four NI runtimes and VIPM'
        foreach ($needle in @('LabVIEW 2026 Professional', 'Application Builder', 'NI-VISA Runtime', 'NI-DAQmx Runtime', 'NI-488.2 Runtime', 'VIPM')) {
            Assert-True (@($items | Where-Object { $_ -like ('*' + $needle + '*') }).Count -ge 1) ('the manual checklist must mention ' + $needle)
        }
        foreach ($item in @($pf.manualItems)) {
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$item.expectedPath)) ('every checklist entry must carry an expected path (' + $item.item + ')')
        }
        Assert-True (-not (Test-Path -LiteralPath $root)) 'a preflight-only run must not create the runner root'
        Assert-Match $r.Output 'manual install checklist' 'the checklist must be printed for the operator'
        Assert-Match $r.Output 'IPv4' 'the report must print the IPv4 line'
        Write-Evidence ('preflight.json: hostname=' + $pf.hostname + ' ipv4=' + ($pf.ipv4 -join ',') + ' node=' + $pf.node.version + ' labview.exists=' + $pf.labview.exists + ' vipm.exists=' + $pf.vipm.exists + ' manualItems=' + $items.Count)
    }

    # ------------------------------------------------------------------ T02 -----
    Test-Case 'T02-register-and-task' 'register argv + config.yaml + SYSTEM/AtStartup task; token sentinel in no output and no file' {
        $sandbox = New-Sandbox 't02'
        $stage = Join-Path $sandbox 'stage'
        $root = Join-Path $sandbox 'runner-root'
        $argvLog = Join-Path $sandbox 'stub\runner-argv.log'
        $taskStub = New-TaskStub -Sandbox $sandbox
        $env = @{
            STUB_ARGV_LOG            = $argvLog
            STUB_EXIT_CODE           = '0'
            STUB_CREATE_RUNNER       = '1'
            STUB_ECHO_TOKEN          = '0'
            STUB_ECHO_ENV_TOKEN      = '0'
            STUB_TASK_LOG            = $taskStub.Log
            STUB_TASK_INSTALL_EXIT   = '0'
            STUB_TASK_START_EXIT     = '0'
            STUB_TASK_STATUS_EXIT    = '0'
        }
        $r = Invoke-Bootstrap -Sandbox $sandbox -StageDir $stage -RunnerRoot $root -RunnerBinary $RunnerStubCmd `
            -TaskBackend $taskStub.Script -Env $env -ExtraArgs @('-SkipNode', '-SkipDeps')
        Assert-Equal 0 $r.ExitCode ("full Phase 2 run must exit 0; output:`n" + (Sanitize-Output $r.Output))
        Assert-NoSentinel -Text $r.Output -Where 'stdout/stderr'
        Assert-NoSentinelUnder -Dir $sandbox

        $reg = @(Get-Lines -Path $argvLog -Pattern ' argv: register( |$)')
        Assert-Equal 1 $reg.Count 'exactly one register invocation expected'
        Assert-Match $reg[0] ('register --no-interactive --instance https://gitea\.sevenology\.top --name ' + [regex]::Escape($env:COMPUTERNAME) + ' --labels windows-labview26:host') 'the register argv must carry instance/name/labels'
        Assert-NotContains $reg[0] '--token' 'the token must NOT travel on the command line'
        Assert-Contains $reg[0] 'token-sha256=-' 'no --token value may be recorded by the stub'
        Assert-Contains $reg[0] ('token-env-sha256=' + $SentinelSha) 'the token must reach the runner through GITEA_RUNNER_REGISTRATION_TOKEN (hash proof)'
        Write-Evidence ('register argv: ' + $reg[0])

        Assert-True (Test-Path -LiteralPath (Join-Path $root '.runner') -PathType Leaf) '.runner must land in <RunnerRoot>'
        $cfg = [System.IO.File]::ReadAllText((Join-Path $root 'config.yaml'))
        Assert-Match $cfg '(?m)^\s*level:\s*info\s*$' 'config.yaml must set log.level'
        Assert-Match $cfg '(?m)^\s*capacity:\s*1\s*$' 'config.yaml must set capacity: 1'
        Assert-Match $cfg 'windows-labview26:host' 'config.yaml must carry the runner label'
        Assert-Match $cfg ('workdir_parent:\s*"' + [regex]::Escape($root.Replace('\', '/')) + '/_work"') 'config.yaml must point workdir_parent at <RunnerRoot>/_work'
        Assert-NoSentinel -Text $cfg -Where 'config.yaml'

        $taskLines = @(Get-Lines -Path $taskStub.Log)
        Assert-Equal 3 $taskLines.Count 'install + start + status must each be invoked once'
        Assert-Match $taskLines[0] 'verb=install task=MicaGiteaRunner' 'the task must be named MicaGiteaRunner'
        Assert-Match $taskLines[0] 'user=SYSTEM' 'the task principal must be SYSTEM'
        Assert-Match $taskLines[0] 'trigger=AtStartup' 'the task must be triggered at startup'
        Assert-Match $taskLines[0] 'execute=cmd\.exe' 'the task action must run through cmd.exe'
        Assert-Match $taskLines[0] 'daemon' 'the task action must start the runner daemon'
        Assert-Match $taskLines[1] 'verb=start task=MicaGiteaRunner' 'the task must be started immediately'
        Assert-Match $taskLines[2] 'verb=status task=MicaGiteaRunner.*proc=runner-stub' 'the daemon process must be probed by binary name'
        Assert-Match $taskLines[2] 'timeout=30' 'the process probe must carry the -StartVerifyTimeoutSec budget'
        Write-Evidence ('task verbs: ' + ($taskLines -join ' || '))

        $marker = Join-Path $stage '.phase2-runner.done'
        Assert-True (Test-Path -LiteralPath $marker -PathType Leaf) 'the phase-2 marker must be written'
        Assert-Match ([System.IO.File]::ReadAllText($marker)) '"phase":\s*"2-runner"' 'the marker must identify the phase'
        Assert-NoSentinel -Text ([System.IO.File]::ReadAllText($marker)) -Where 'phase-2 marker'
        Assert-Match $r.Output 'Online' 'success output must ask for the Online confirmation'
        Write-Evidence ('markers: ' + ((@(Get-ChildItem -LiteralPath $stage -Force -File | ForEach-Object { $_.Name })) -join ', '))
    }

    # ------------------------------------------------------------------ T03 -----
    Test-Case 'T03-phase3-raw-deps' 'kit via the GitHub contents route, dragon via the Gitea raw route, both byte-identical; the real bootstrap-deps.ps1 runs against the staged dragon' {
        $sandbox = New-Sandbox 't03'
        $stage = Join-Path $sandbox 'stage'
        $root = Join-Path $sandbox 'runner-root'
        $deps = New-DepsFixture -Sandbox $sandbox
        $stub = Start-ApiStub -Sandbox $sandbox -RawDir $deps.Served
        $taskStub = New-TaskStub -Sandbox $sandbox
        $env = @{
            STUB_TASK_LOG          = $taskStub.Log
            STUB_TASK_INSTALL_EXIT = '0'
            STUB_TASK_START_EXIT   = '0'
            STUB_TASK_STATUS_EXIT  = '0'
            STUB_ARGV_LOG          = $deps.ArgvLog
            STUB_LIST_FILE         = $deps.ListFile
            STUB_INSTALL_OUTPUT_FILE = ''
            STUB_EXIT_CODE         = '0'
            STUB_SLEEP_SEC         = '0'
            STUB_SLEEP_SUBCOMMAND  = ''
        }
        $r = Invoke-Bootstrap -Sandbox $sandbox -StageDir $stage -RunnerRoot $root -Instance $stub.Base `
            -KitApiBase $stub.Base `
            -TaskBackend $taskStub.Script -VipmPath $VipmStubCmd -LabViewPath $deps.LabView -NiRoot $deps.NiRoot `
            -Env $env -ExtraArgs @('-SkipNode', '-SkipRunner')
        Assert-Equal 0 $r.ExitCode ("Phase 3 run must exit 0; output:`n" + (Sanitize-Output $r.Output))
        Assert-NoSentinel -Text $r.Output -Where 'stdout/stderr'
        Assert-NoSentinelUnder -Dir $sandbox

        $stagedDeps = Join-Path $stage 'bootstrap-deps.ps1'
        $stagedDragon = Join-Path $stage 'Lab_Super.dragon'
        Assert-True (Test-Path -LiteralPath $stagedDeps -PathType Leaf) 'bootstrap-deps.ps1 must be staged'
        Assert-True (Test-Path -LiteralPath $stagedDragon -PathType Leaf) 'Lab_Super.dragon must be staged'
        $servedDepsHash = (Get-FileHash -LiteralPath (Join-Path $deps.Served 'ci\bootstrap-deps.ps1') -Algorithm SHA256).Hash
        $servedDragonHash = (Get-FileHash -LiteralPath (Join-Path $deps.Served 'Lab_Super.dragon') -Algorithm SHA256).Hash
        Assert-Equal $servedDepsHash (Get-FileHash -LiteralPath $stagedDeps -Algorithm SHA256).Hash 'the staged script must be byte-identical to the served one'
        Assert-Equal $servedDragonHash (Get-FileHash -LiteralPath $stagedDragon -Algorithm SHA256).Hash 'the staged dragon file must be byte-identical to the served one'

        $raw = @(Get-ApiRequests -LogPath $stub.Log -RawOnly)
        Assert-Equal 2 $raw.Count 'exactly two raw file requests expected'
        Assert-Equal 'ci/bootstrap-deps.ps1' $raw[0].rawPath 'the first fetch must be the dependency script'
        Assert-Equal 'Lab_Super.dragon' $raw[1].rawPath 'the second fetch must be the dragon file'
        Assert-Equal 'contents' $raw[0].rawKind 'the kit fetch must use the GitHub contents API shape'
        Assert-Equal '/repos/mica-home/LabVIEW-CI/contents/ci/bootstrap-deps.ps1' $raw[0].path 'the dependency script must come from the kit repository via the GitHub contents route'
        Assert-Equal '/api/v1/repos/MICA/MICA/raw/Lab_Super.dragon' $raw[1].path 'the dragon must come from the MICA repository via the Gitea raw route'
        Assert-Equal 'main' $raw[0].ref 'the kit fetch must carry the kit ref (-KitRef)'
        Assert-Equal 'dev' $raw[1].ref 'the dragon fetch must keep the MICA ref (-Ref)'
        Assert-Equal 'application/vnd.github.raw' $raw[0].accept 'the kit fetch must ask for the raw file via the GitHub media type'
        Assert-Equal 'Bearer' $raw[0].auth 'the kit fetch must authenticate with the Bearer scheme (GitHub)'
        Assert-Equal (Get-StringSha256 -Text $GhSentinel) $raw[0].authSha256 'the kit fetch must use the dedicated GitHub token, not the registration token (hash proof)'
        Assert-Equal 'token' $raw[1].auth 'the dragon fetch must authenticate with the Gitea token scheme'
        Assert-Equal $SentinelSha $raw[1].authSha256 'the dragon fetch must use the registration token (hash proof)'

        $install = @(Get-Lines -Path $deps.ArgvLog -Pattern 'argv: install ')
        Assert-Equal 1 $install.Count 'bootstrap-deps.ps1 must have invoked vipm install exactly once'
        Assert-Match $install[0] ('argv: install -y --labview-version 2026 --timeout 3600 --color-mode never .*') 'the install argv must follow the documented shape'
        $vipmSafeCopy = Join-Path (Join-Path $env:TEMP 'vipm-public-cwd') 'Lab_Super.dragon'
        Assert-Match $install[0] ([regex]::Escape($vipmSafeCopy) + '$') 'the install must run from the public-repo copy of the dragon (-VipmSafeRemote)'
        Assert-Equal (Get-FileHash -LiteralPath $stagedDragon -Algorithm SHA256).Hash (Get-FileHash -LiteralPath $vipmSafeCopy -Algorithm SHA256).Hash 'the public-repo copy must be byte-identical to the staged dragon'
        Assert-NotMatch $install[0] '--vipm' 'the --vipm filter must stay off for dragon inputs (vipm 2026.3.1 rejects it)'
        Assert-True (@(Get-Lines -Path $deps.ArgvLog -Pattern 'argv: list ').Count -ge 1) 'bootstrap-deps.ps1 must reconcile with vipm list'
        Write-Evidence ('vipm: ' + $install[0])

        $marker = Join-Path $stage '.phase3-deps.done'
        Assert-True (Test-Path -LiteralPath $marker -PathType Leaf) 'the phase-3 marker must be written'
        Assert-Match ([System.IO.File]::ReadAllText($marker)) '"phase":\s*"3-deps"' 'the marker must identify the phase'
        Write-Evidence ('api raw requests: ' + (($raw | ForEach-Object { $_.path + ' -> ' + $_.status }) -join ' | '))
    }

    # ------------------------------------------------------------------ T04 -----
    Test-Case 'T04-idempotency-resume' 'second run skips both phases; a missing phase marker resumes only that phase; -Force redoes' {
        $sandbox = New-Sandbox 't04'
        $stage = Join-Path $sandbox 'stage'
        $root = Join-Path $sandbox 'runner-root'
        $deps = New-DepsFixture -Sandbox $sandbox
        $stub = Start-ApiStub -Sandbox $sandbox -RawDir $deps.Served
        $taskStub = New-TaskStub -Sandbox $sandbox
        $argvLog = Join-Path $sandbox 'stub\runner-argv.log'
        $env = @{
            STUB_ARGV_LOG            = $argvLog
            STUB_EXIT_CODE           = '0'
            STUB_CREATE_RUNNER       = '1'
            STUB_ECHO_TOKEN          = '0'
            STUB_ECHO_ENV_TOKEN      = '0'
            STUB_TASK_LOG            = $taskStub.Log
            STUB_TASK_INSTALL_EXIT   = '0'
            STUB_TASK_START_EXIT     = '0'
            STUB_TASK_STATUS_EXIT    = '0'
            STUB_LIST_FILE           = $deps.ListFile
            STUB_INSTALL_OUTPUT_FILE = ''
            STUB_SLEEP_SEC           = '0'
            STUB_SLEEP_SUBCOMMAND    = ''
        }
        $common = @{
            Sandbox = $sandbox; StageDir = $stage; RunnerRoot = $root; Instance = $stub.Base
            KitApiBase = $stub.Base
            TaskBackend = $taskStub.Script; VipmPath = $VipmStubCmd; LabViewPath = $deps.LabView
            NiRoot = $deps.NiRoot; RunnerBinary = $RunnerStubCmd; Env = $env
        }
        $runArgs = @('-SkipNode')

        $r1 = Invoke-Bootstrap @common -ExtraArgs $runArgs
        Assert-Equal 0 $r1.ExitCode ("first run must exit 0; output:`n" + (Sanitize-Output $r1.Output))
        $regAfter1 = @(Get-Lines -Path $argvLog -Pattern ' argv: register( |$)').Count
        $rawAfter1 = @(Get-ApiRequests -LogPath $stub.Log -RawOnly).Count
        Assert-Equal 1 $regAfter1 'one registration after the first run'
        Assert-Equal 2 $rawAfter1 'two raw fetches after the first run'

        $r2 = Invoke-Bootstrap @common -ExtraArgs $runArgs
        Assert-Equal 0 $r2.ExitCode ("idempotent rerun must exit 0; output:`n" + (Sanitize-Output $r2.Output))
        Assert-Match $r2.Output 'already done \(marker' 'the rerun must report the phases as already done'
        Assert-Match $r2.Output '\-Force' 'the skip path must tell the operator about -Force'
        Assert-Equal $regAfter1 (@(Get-Lines -Path $argvLog -Pattern ' argv: register( |$)').Count) 'registration must be skipped on the second run'
        Assert-Equal $rawAfter1 (@(Get-ApiRequests -LogPath $stub.Log -RawOnly).Count) 'the raw fetch must be skipped on the second run'
        Assert-Equal 1 (@(Get-Lines -Path $taskStub.Log -Pattern 'verb=install').Count) 'the scheduled task must not be re-registered on the second run'

        # cancel-resume: an interrupted Phase 3 (marker missing, files already staged) is
        # redone from the staged files - no new fetch, no new token needed.
        Remove-Item -LiteralPath (Join-Path $stage '.phase3-deps.done') -Force
        $r3 = Invoke-Bootstrap @common -ProvideToken $false -ExtraArgs $runArgs
        Assert-Equal 0 $r3.ExitCode ("resume run must exit 0 without a token; output:`n" + (Sanitize-Output $r3.Output))
        Assert-Equal $rawAfter1 (@(Get-ApiRequests -LogPath $stub.Log -RawOnly).Count) 'the resume run must reuse the staged files instead of refetching'
        Assert-True (Test-Path -LiteralPath (Join-Path $stage '.phase3-deps.done') -PathType Leaf) 'the resumed phase must write its marker again'

        # stale state + -Force: everything is redone on purpose.
        $r4 = Invoke-Bootstrap @common -ExtraArgs @('-SkipNode', '-Force')
        Assert-Equal 0 $r4.ExitCode ("forced rerun must exit 0; output:`n" + (Sanitize-Output $r4.Output))
        Assert-Equal ($regAfter1 + 1) (@(Get-Lines -Path $argvLog -Pattern ' argv: register( |$)').Count) '-Force must re-register'
        Assert-Equal ($rawAfter1 + 2) (@(Get-ApiRequests -LogPath $stub.Log -RawOnly).Count) '-Force must refetch both files'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.runner.bak'))) 'a successful -Force must not leave .runner.bak behind'
        Write-Evidence ('register calls: 1st=' + $regAfter1 + ' after -Force=' + (@(Get-Lines -Path $argvLog -Pattern ' argv: register( |$)').Count) + '; raw fetches: 1st=' + $rawAfter1 + ' resume=' + $rawAfter1 + ' after -Force=' + (@(Get-ApiRequests -LogPath $stub.Log -RawOnly).Count))
    }

    # ------------------------------------------------------------------ T05 -----
    Test-Case 'T05-phase1-node' 'skip when >= 20; winget install + re-probe; failure -> exit 6 with the MSI page; hung winget -> exit 6' {
        # (a) old node -> winget installs -> re-probe passes -> marker written
        $s1 = New-Sandbox 't05a'
        $nodeStub = New-NodeStub -Sandbox $s1
        $wingetStub = New-WingetStub -Sandbox $s1 -ExitCode 0 -FlipMarker $nodeStub.FlipMarker
        $r1 = Invoke-Bootstrap -Sandbox $s1 -StageDir (Join-Path $s1 'stage') -RunnerRoot (Join-Path $s1 'rr') `
            -NodeCommand $nodeStub.Cmd -WingetCommand $wingetStub.Cmd -ExtraArgs @('-SkipRunner', '-SkipDeps')
        Assert-Equal 0 $r1.ExitCode ("winget path must exit 0; output:`n" + (Sanitize-Output $r1.Output))
        Assert-Match $r1.Output 'winget install OpenJS\.NodeJS\.LTS --silent' 'the winget command shape must be printed'
        Assert-Match $r1.Output 'timeout budget 900 s' 'the winget timeout budget must be printed'
        $w1 = @(Get-Lines -Path $wingetStub.Log)
        Assert-Equal 1 $w1.Count 'winget must be invoked exactly once'
        Assert-Match $w1[0] 'argv: install OpenJS\.NodeJS\.LTS --silent' 'winget must be asked for the LTS package'
        Assert-Match $r1.Output 'v24\.19\.0' 'the re-probe must show the installed version (banner is not trusted)'
        Assert-True (Test-Path -LiteralPath (Join-Path $s1 'stage\.phase1-node.done') -PathType Leaf) 'the phase-1 marker must be written after a successful install'
        Write-Evidence ('winget argv: ' + $w1[0] + ' | marker written, re-probe v24.19.0')

        # (b) winget fails -> exit 6 with the official MSI route
        $s2 = New-Sandbox 't05b'
        $nodeStub2 = New-NodeStub -Sandbox $s2
        $wingetStub2 = New-WingetStub -Sandbox $s2 -ExitCode 1 -FlipMarker $nodeStub2.FlipMarker
        $r2 = Invoke-Bootstrap -Sandbox $s2 -StageDir (Join-Path $s2 'stage') -RunnerRoot (Join-Path $s2 'rr') `
            -NodeCommand $nodeStub2.Cmd -WingetCommand $wingetStub2.Cmd -ExtraArgs @('-SkipRunner', '-SkipDeps')
        Assert-Equal 6 $r2.ExitCode ("a failed Node install must exit 6; output:`n" + (Sanitize-Output $r2.Output))
        Assert-Match $r2.Output 'nodejs\.org' 'the MSI route must name nodejs.org'
        Assert-Match $r2.Output '\.msi' 'the MSI file must be named'
        Assert-NotMatch $r2.Output 'Bootstrap complete' 'a failed phase must not print the success summary'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $s2 'stage\.phase1-node.done'))) 'no phase-1 marker may survive a failed install'
        Write-Evidence 'winget exit 1 -> script exit 6, MSI guidance printed, no marker'

        # (c) node already >= 20 -> winget never runs
        $s3 = New-Sandbox 't05c'
        $nodeStub3 = New-NodeStub -Sandbox $s3
        $wingetStub3 = New-WingetStub -Sandbox $s3 -ExitCode 0 -FlipMarker $nodeStub3.FlipMarker
        New-Item -ItemType File -Path $nodeStub3.FlipMarker -Force | Out-Null
        $r3 = Invoke-Bootstrap -Sandbox $s3 -StageDir (Join-Path $s3 'stage') -RunnerRoot (Join-Path $s3 'rr') `
            -NodeCommand $nodeStub3.Cmd -WingetCommand $wingetStub3.Cmd -ExtraArgs @('-SkipRunner', '-SkipDeps')
        Assert-Equal 0 $r3.ExitCode 'a satisfied Node must exit 0'
        Assert-Equal 0 (@(Get-Lines -Path $wingetStub3.Log)).Count 'winget must not run when Node is already >= 20'
        Assert-True (Test-Path -LiteralPath (Join-Path $s3 'stage\.phase1-node.done') -PathType Leaf) 'the phase-1 marker must be written'
        Write-Evidence 'node v24.19.0 -> winget invocations=0, marker written'

        # (d) hung winget -> killed at the budget, exit 6
        $s4 = New-Sandbox 't05d'
        $nodeStub4 = New-NodeStub -Sandbox $s4
        $wingetStub4 = New-WingetStub -Sandbox $s4 -ExitCode 0 -SleepSec 30 -FlipMarker $nodeStub4.FlipMarker
        $r4 = Invoke-Bootstrap -Sandbox $s4 -StageDir (Join-Path $s4 'stage') -RunnerRoot (Join-Path $s4 'rr') `
            -NodeCommand $nodeStub4.Cmd -WingetCommand $wingetStub4.Cmd `
            -ExtraArgs @('-SkipRunner', '-SkipDeps', '-WingetTimeoutSec', '3')
        Assert-Equal 6 $r4.ExitCode ("a hung winget must end in exit 6; output:`n" + (Sanitize-Output $r4.Output))
        Assert-Match $r4.Output 'did not return' 'the timeout must be reported'
        Assert-True ($r4.Seconds -lt 25) ('the hung child must be killed at the budget, not after 30s (took ' + $r4.Seconds + 's)')
        Write-Evidence ('hung winget (30s sleep) with -WingetTimeoutSec 3 -> exit 6 after ' + $r4.Seconds + 's')
    }

    # ------------------------------------------------------------------ T06 -----
    Test-Case 'T06-fetch-failures' '401 / 404 / hung raw fetch -> exit 3 + manual fallback, nothing executed, no marker' {
        foreach ($variant in @(
                # ExtraExpect pins the status-specific remedy: a rejected token points at
                # dropping the token for the public kit; a 404 points at "not public".
                [pscustomobject]@{ Tag = 't06-401'; Status = 401; Hang = ''; Expect = '401'; ExtraExpect = 'omit -GitHubToken'; Extra = @() },
                [pscustomobject]@{ Tag = 't06-404'; Status = 404; Hang = ''; Expect = '404'; ExtraExpect = 'not public'; Extra = @() },
                [pscustomobject]@{ Tag = 't06-hang'; Status = 0; Hang = 'GET /repos/mica-home/LabVIEW-CI/contents/ci/bootstrap-deps.ps1'; Expect = 'fetch failed'; ExtraExpect = ''; Extra = @('-DownloadTimeoutSec', '3') }
            )) {
            $sandbox = New-Sandbox $variant.Tag
            $stage = Join-Path $sandbox 'stage'
            $root = Join-Path $sandbox 'runner-root'
            $deps = New-DepsFixture -Sandbox $sandbox
            $stub = Start-ApiStub -Sandbox $sandbox -RawDir $deps.Served -RawStatus $variant.Status -HangOn $variant.Hang
            $taskStub = New-TaskStub -Sandbox $sandbox
            $env = @{ STUB_TASK_LOG = $taskStub.Log; STUB_ARGV_LOG = $deps.ArgvLog; STUB_LIST_FILE = $deps.ListFile }
            $extra = @('-SkipNode', '-SkipRunner') + $variant.Extra
            $r = Invoke-Bootstrap -Sandbox $sandbox -StageDir $stage -RunnerRoot $root -Instance $stub.Base `
                -KitApiBase $stub.Base `
                -TaskBackend $taskStub.Script -VipmPath $VipmStubCmd -LabViewPath $deps.LabView -NiRoot $deps.NiRoot `
                -Env $env -ExtraArgs $extra
            Assert-Equal 3 $r.ExitCode ("raw failure '" + $variant.Tag + "' must exit 3; output:`n" + (Sanitize-Output $r.Output))
            Assert-Contains $r.Output $variant.Expect ("the diagnostic must name the failure kind (" + $variant.Tag + ")")
            if (-not [string]::IsNullOrWhiteSpace($variant.ExtraExpect)) {
                Assert-Contains $r.Output $variant.ExtraExpect ("the '" + $variant.Tag + "' diagnostic must name the remedy (" + $variant.ExtraExpect + ")")
            }
            Assert-Match $r.Output 'manual fallback' 'the manual fallback must be offered'
            Assert-Match $r.Output '\-SkipRunner' 'the fallback must name the -SkipRunner re-run'
            Assert-Contains $r.Output 'bootstrap-deps.ps1' 'the fallback must name the file to copy'
            Assert-Contains $r.Output 'Lab_Super.dragon' 'the fallback must name the dragon file to copy'
            Assert-NotMatch $r.Output 'Bootstrap complete' 'a failed fetch must not claim success'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage 'bootstrap-deps.ps1'))) 'no half-downloaded script may survive'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage 'Lab_Super.dragon'))) 'no half-downloaded dragon may survive'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage '.phase3-deps.done'))) 'no phase-3 marker may be written'
            Assert-Equal 0 (@(Get-Lines -Path $deps.ArgvLog)).Count 'bootstrap-deps.ps1 must never run when the fetch failed'
            Assert-NoSentinelUnder -Dir $sandbox
            Write-Evidence ("'" + $variant.Tag + "' -> exit 3, fallback printed, no staged files, vipm untouched")
        }
    }

    # ------------------------------------------------------------------ T07 -----
    Test-Case 'T07-misleading-success' 'exit 0 without .runner, task install/start/status failures, echoing child: all red + cleanup' {
        $taskStub = $null
        # (a) runner exits 0 but writes no .runner -> red (exit 5), no task, no leftovers
        $s1 = New-Sandbox 't07a'
        $stage1 = Join-Path $s1 'stage'
        $root1 = Join-Path $s1 'runner-root'
        $log1 = Join-Path $s1 'stub\runner-argv.log'
        $taskStub1 = New-TaskStub -Sandbox $s1
        $env1 = @{
            STUB_ARGV_LOG = $log1; STUB_EXIT_CODE = '0'; STUB_CREATE_RUNNER = '0'; STUB_ECHO_TOKEN = '0'; STUB_ECHO_ENV_TOKEN = '0'
            STUB_TASK_LOG = $taskStub1.Log; STUB_TASK_INSTALL_EXIT = '0'; STUB_TASK_START_EXIT = '0'; STUB_TASK_STATUS_EXIT = '0'
        }
        $r1 = Invoke-Bootstrap -Sandbox $s1 -StageDir $stage1 -RunnerRoot $root1 -RunnerBinary $RunnerStubCmd `
            -TaskBackend $taskStub1.Script -Env $env1 -ExtraArgs @('-SkipNode', '-SkipDeps')
        Assert-Equal 5 $r1.ExitCode ("exit 0 from the runner without .runner must still fail; output:`n" + (Sanitize-Output $r1.Output))
        Assert-Match $r1.Output '\.runner' 'the failure must name the missing state file'
        Assert-NotMatch $r1.Output 'Bootstrap complete' 'no success summary may be printed'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root1 '.runner'))) '.runner must not exist after the failure'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root1 'config.yaml'))) 'config created by the failed run must be removed'
        Assert-True (-not (Test-Path -LiteralPath $root1)) 'a runner root created by the failed run must be removed'
        Assert-Equal 0 (@(Get-Lines -Path $taskStub1.Log -Pattern 'verb=install').Count) 'the task must not be installed when registration failed'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage1 '.phase2-runner.done'))) 'no phase-2 marker may be written'
        Write-Evidence 'runner exit 0 + no .runner -> exit 5, .runner/config/root removed, task never installed'

        # (b) task install fails -> exit 5, task cleaned up, valid registration preserved
        $s2 = New-Sandbox 't07b'
        $stage2 = Join-Path $s2 'stage'
        $root2 = Join-Path $s2 'runner-root'
        $log2 = Join-Path $s2 'stub\runner-argv.log'
        $taskStub2 = New-TaskStub -Sandbox $s2
        $env2 = @{
            STUB_ARGV_LOG = $log2; STUB_EXIT_CODE = '0'; STUB_CREATE_RUNNER = '1'; STUB_ECHO_TOKEN = '0'; STUB_ECHO_ENV_TOKEN = '0'
            STUB_TASK_LOG = $taskStub2.Log; STUB_TASK_INSTALL_EXIT = '1'; STUB_TASK_START_EXIT = '0'; STUB_TASK_STATUS_EXIT = '0'
        }
        $r2 = Invoke-Bootstrap -Sandbox $s2 -StageDir $stage2 -RunnerRoot $root2 -RunnerBinary $RunnerStubCmd `
            -TaskBackend $taskStub2.Script -Env $env2 -ExtraArgs @('-SkipNode', '-SkipDeps')
        Assert-Equal 5 $r2.ExitCode 'a failing task install must exit 5'
        Assert-Match $r2.Output 'scheduled task registration failed' 'the failing step must be named'
        Assert-Equal 1 (@(Get-Lines -Path $taskStub2.Log -Pattern 'verb=install').Count) 'install must have been attempted once'
        Assert-Equal 1 (@(Get-Lines -Path $taskStub2.Log -Pattern 'verb=uninstall').Count) 'the broken task must be uninstalled'
        Assert-True (Test-Path -LiteralPath (Join-Path $root2 '.runner') -PathType Leaf) 'the valid registration must be preserved (token is single-use)'
        Assert-True (Test-Path -LiteralPath (Join-Path $root2 'config.yaml') -PathType Leaf) 'config.yaml must be preserved'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage2 '.phase2-runner.done'))) 'no phase-2 marker may be written'
        Write-Evidence 'task install exit 1 -> exit 5, uninstall issued, .runner+config kept'

        # (c) the task claims to start but the daemon process never appears -> exit 5
        $s3 = New-Sandbox 't07c'
        $stage3 = Join-Path $s3 'stage'
        $root3 = Join-Path $s3 'runner-root'
        $log3 = Join-Path $s3 'stub\runner-argv.log'
        $taskStub3 = New-TaskStub -Sandbox $s3
        $env3 = @{
            STUB_ARGV_LOG = $log3; STUB_EXIT_CODE = '0'; STUB_CREATE_RUNNER = '1'; STUB_ECHO_TOKEN = '0'; STUB_ECHO_ENV_TOKEN = '0'
            STUB_TASK_LOG = $taskStub3.Log; STUB_TASK_INSTALL_EXIT = '0'; STUB_TASK_START_EXIT = '0'; STUB_TASK_STATUS_EXIT = '1'
        }
        $r3 = Invoke-Bootstrap -Sandbox $s3 -StageDir $stage3 -RunnerRoot $root3 -RunnerBinary $RunnerStubCmd `
            -TaskBackend $taskStub3.Script -Env $env3 -ExtraArgs @('-SkipNode', '-SkipDeps')
        Assert-Equal 5 $r3.ExitCode ("a task that reports running without a process must fail; output:`n" + (Sanitize-Output $r3.Output))
        Assert-Match $r3.Output 'auto-start verification failed' 'the failed verification must be named'
        Assert-Equal 1 (@(Get-Lines -Path $taskStub3.Log -Pattern 'verb=status').Count) 'the process probe must have run'
        Assert-True (Test-Path -LiteralPath (Join-Path $root3 '.runner') -PathType Leaf) 'the registration must survive an autostart failure'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage3 '.phase2-runner.done'))) 'no phase-2 marker may be written'
        Write-Evidence 'task status exit 1 -> exit 5, registration preserved, marker absent'

        # (d) adversarial child: the runner echoes the token it got through the environment
        $s4 = New-Sandbox 't07d'
        $stage4 = Join-Path $s4 'stage'
        $root4 = Join-Path $s4 'runner-root'
        $log4 = Join-Path $s4 'stub\runner-argv.log'
        $taskStub4 = New-TaskStub -Sandbox $s4
        $env4 = @{
            STUB_ARGV_LOG = $log4; STUB_EXIT_CODE = '1'; STUB_CREATE_RUNNER = '1'; STUB_ECHO_TOKEN = '0'; STUB_ECHO_ENV_TOKEN = '1'
            STUB_TASK_LOG = $taskStub4.Log; STUB_TASK_INSTALL_EXIT = '0'; STUB_TASK_START_EXIT = '0'; STUB_TASK_STATUS_EXIT = '0'
        }
        $r4 = Invoke-Bootstrap -Sandbox $s4 -StageDir $stage4 -RunnerRoot $root4 -RunnerBinary $RunnerStubCmd `
            -TaskBackend $taskStub4.Script -Env $env4 -ExtraArgs @('-SkipNode', '-SkipDeps')
        Assert-Equal 5 $r4.ExitCode 'a failing registration must exit 5'
        Assert-NoSentinel -Text $r4.Output -Where 'stdout/stderr of the echoing-child case'
        Assert-Match $r4.Output '<redacted>' 'the echoed credential must be redacted in the transcript'
        Assert-NoSentinelUnder -Dir $s4
        Write-Evidence 'child echoed the env token on stderr -> transcript shows <redacted>, sentinel absent everywhere'
    }

    # ------------------------------------------------------------------ T08 -----
    Test-Case 'T08-zero-external-calls' 'every HTTP request went to the loopback stub; no binary download when -RunnerBinaryPath is given' {
        $sandbox = New-Sandbox 't08'
        $stage = Join-Path $sandbox 'stage'
        $root = Join-Path $sandbox 'runner-root'
        $deps = New-DepsFixture -Sandbox $sandbox
        $stub = Start-ApiStub -Sandbox $sandbox -RawDir $deps.Served
        $taskStub = New-TaskStub -Sandbox $sandbox
        $argvLog = Join-Path $sandbox 'stub\runner-argv.log'
        $env = @{
            STUB_ARGV_LOG = $argvLog; STUB_EXIT_CODE = '0'; STUB_CREATE_RUNNER = '1'
            STUB_ECHO_TOKEN = '0'; STUB_ECHO_ENV_TOKEN = '0'
            STUB_TASK_LOG = $taskStub.Log; STUB_TASK_INSTALL_EXIT = '0'; STUB_TASK_START_EXIT = '0'; STUB_TASK_STATUS_EXIT = '0'
            STUB_LIST_FILE = $deps.ListFile; STUB_INSTALL_OUTPUT_FILE = ''; STUB_SLEEP_SEC = '0'; STUB_SLEEP_SUBCOMMAND = ''
        }
        $r = Invoke-Bootstrap -Sandbox $sandbox -StageDir $stage -RunnerRoot $root -Instance $stub.Base `
            -KitApiBase $stub.Base `
            -RunnerBinary $RunnerStubCmd -TaskBackend $taskStub.Script -VipmPath $VipmStubCmd `
            -LabViewPath $deps.LabView -NiRoot $deps.NiRoot -Env $env -ExtraArgs @('-SkipNode')
        Assert-Equal 0 $r.ExitCode ("the loopback run must exit 0; output:`n" + (Sanitize-Output $r.Output))

        $all = @(Get-ApiRequests -LogPath $stub.Log)
        Assert-True ($all.Count -ge 3) 'the stub log must contain the readiness probe plus the raw fetches'
        $expectedHost = '127.0.0.1:' + $stub.Port
        foreach ($req in $all) {
            if ($req.PSObject.Properties.Name -contains 'raw') {
                Assert-Equal $expectedHost $req.host ('every raw request must have been sent to the loopback stub, saw: ' + [string]$req.host)
            }
            Assert-Match ([string]$req.path) '^/' 'every logged request must be a stub-served path'
        }
        $raw = @(Get-ApiRequests -LogPath $stub.Log -RawOnly)
        Assert-Equal 2 $raw.Count 'exactly the two raw fetches may be issued'
        Assert-NotMatch $r.Output 'dl\.gitea\.com' '-RunnerBinaryPath must suppress the binary download entirely'
        Assert-NotMatch $r.Output 'nodejs\.org' 'no Node download may be attempted on this path'
        Assert-NotMatch $r.Output 'gitea\.sevenology\.top' 'the run must only ever talk to the instance it was given (the stub)'
        Write-Evidence ('requests: ' + $all.Count + ', all loopback (' + $expectedHost + '), raw=' + $raw.Count + ', no dl.gitea.com/nodejs.org references in the transcript')
    }

    # ------------------------------------------------------------------ T09 -----
    Test-Case 'T09-kit-anonymous' 'no -GitHubToken: the public kit is fetched with NO Authorization header (scheme none, no credential); the same fetch with -GitHubToken sends Bearer + the sha proof' {
        # (a) no GitHub token anywhere (the harness scrubs GITHUB_TOKEN from the child env):
        # the contents request carries no Authorization header at all and Phase 3 still
        # completes - the kit repository is public.
        $s1 = New-Sandbox 't09-anon'
        $stage1 = Join-Path $s1 'stage'
        $root1 = Join-Path $s1 'runner-root'
        $deps1 = New-DepsFixture -Sandbox $s1
        $stub1 = Start-ApiStub -Sandbox $s1 -RawDir $deps1.Served
        $taskStub1 = New-TaskStub -Sandbox $s1
        $env1 = @{
            STUB_TASK_LOG = $taskStub1.Log; STUB_TASK_INSTALL_EXIT = '0'; STUB_TASK_START_EXIT = '0'; STUB_TASK_STATUS_EXIT = '0'
            STUB_ARGV_LOG = $deps1.ArgvLog; STUB_LIST_FILE = $deps1.ListFile; STUB_INSTALL_OUTPUT_FILE = ''
            STUB_EXIT_CODE = '0'; STUB_SLEEP_SEC = '0'; STUB_SLEEP_SUBCOMMAND = ''
        }
        $r1 = Invoke-Bootstrap -Sandbox $s1 -StageDir $stage1 -RunnerRoot $root1 -Instance $stub1.Base `
            -KitApiBase $stub1.Base -GitHubToken '' `
            -TaskBackend $taskStub1.Script -VipmPath $VipmStubCmd -LabViewPath $deps1.LabView -NiRoot $deps1.NiRoot `
            -Env $env1 -ExtraArgs @('-SkipNode', '-SkipRunner')
        Assert-Equal 0 $r1.ExitCode ("the anonymous kit fetch must exit 0; output:`n" + (Sanitize-Output $r1.Output))
        Assert-Match $r1.Output 'anonymous' 'the plan must report the kit fetch as anonymous'
        Assert-NoSentinel -Text $r1.Output -Where 'stdout/stderr (anonymous run)'

        $stagedDeps1 = Join-Path $stage1 'bootstrap-deps.ps1'
        Assert-True (Test-Path -LiteralPath $stagedDeps1 -PathType Leaf) 'the kit script must be staged without a token'
        Assert-Equal (Get-FileHash -LiteralPath (Join-Path $deps1.Served 'ci\bootstrap-deps.ps1') -Algorithm SHA256).Hash (Get-FileHash -LiteralPath $stagedDeps1 -Algorithm SHA256).Hash 'the anonymously staged script must be byte-identical to the served one'

        $raw1 = @(Get-ApiRequests -LogPath $stub1.Log -RawOnly)
        Assert-Equal 2 $raw1.Count 'exactly two raw file requests expected (both files are still fetched)'
        Assert-Equal 'contents' $raw1[0].rawKind 'the kit fetch must use the GitHub contents API shape'
        Assert-Equal '/repos/mica-home/LabVIEW-CI/contents/ci/bootstrap-deps.ps1' $raw1[0].path 'the anonymous kit fetch must still target the kit repository'
        Assert-True ($null -eq $raw1[0].auth) 'the anonymous kit fetch must send NO Authorization header (scheme none)'
        Assert-True ($null -eq $raw1[0].authSha256) 'the anonymous kit fetch must present no credential (no sha proof)'
        Assert-Equal 'token' $raw1[1].auth 'the dragon fetch must keep the Gitea token scheme (its repository is private)'
        Assert-Equal $SentinelSha $raw1[1].authSha256 'the dragon fetch must still use the registration token (hash proof)'
        Write-Evidence ('anonymous kit fetch: auth=' + [string]$raw1[0].auth + ' authSha256=' + [string]$raw1[0].authSha256 + ' | dragon auth=' + $raw1[1].auth + ' sha=' + ([string]$raw1[1].authSha256).Substring(0, 16) + '...')

        # (b) the token stays optional: supplied via -GitHubToken it travels as Bearer and is
        # proven by its sha256 in the stub log (the dedicated GH sentinel, not the Gitea one).
        $s2 = New-Sandbox 't09-token'
        $stage2 = Join-Path $s2 'stage'
        $root2 = Join-Path $s2 'runner-root'
        $deps2 = New-DepsFixture -Sandbox $s2
        $stub2 = Start-ApiStub -Sandbox $s2 -RawDir $deps2.Served
        $taskStub2 = New-TaskStub -Sandbox $s2
        $env2 = @{
            STUB_TASK_LOG = $taskStub2.Log; STUB_TASK_INSTALL_EXIT = '0'; STUB_TASK_START_EXIT = '0'; STUB_TASK_STATUS_EXIT = '0'
            STUB_ARGV_LOG = $deps2.ArgvLog; STUB_LIST_FILE = $deps2.ListFile; STUB_INSTALL_OUTPUT_FILE = ''
            STUB_EXIT_CODE = '0'; STUB_SLEEP_SEC = '0'; STUB_SLEEP_SUBCOMMAND = ''
        }
        $r2 = Invoke-Bootstrap -Sandbox $s2 -StageDir $stage2 -RunnerRoot $root2 -Instance $stub2.Base `
            -KitApiBase $stub2.Base -GitHubToken $GhSentinel `
            -TaskBackend $taskStub2.Script -VipmPath $VipmStubCmd -LabViewPath $deps2.LabView -NiRoot $deps2.NiRoot `
            -Env $env2 -ExtraArgs @('-SkipNode', '-SkipRunner')
        Assert-Equal 0 $r2.ExitCode ("the token kit fetch must exit 0; output:`n" + (Sanitize-Output $r2.Output))
        $raw2 = @(Get-ApiRequests -LogPath $stub2.Log -RawOnly)
        Assert-Equal 2 $raw2.Count 'exactly two raw file requests expected (token run)'
        Assert-Equal 'Bearer' $raw2[0].auth 'a supplied -GitHubToken must be sent with the Bearer scheme'
        Assert-Equal (Get-StringSha256 -Text $GhSentinel) $raw2[0].authSha256 'the token run must use the dedicated GitHub token (hash proof)'
        Assert-Equal 'token' $raw2[1].auth 'the dragon fetch must keep the Gitea token scheme'
        Assert-Equal $SentinelSha $raw2[1].authSha256 'the dragon fetch must use the registration token (hash proof)'
        Write-Evidence ('token kit fetch: kit auth=' + $raw2[0].auth + ' sha matches GH sentinel; dragon auth=' + $raw2[1].auth)
    }

    # ------------------------------------------------------------------ T10 -----
    Test-Case 'T10-manual-fallback' 'pre-staged files + -SkipRunner: Phase 3 runs offline with no token' {
        $sandbox = New-Sandbox 't10'
        $stage = Join-Path $sandbox 'stage'
        $root = Join-Path $sandbox 'runner-root'
        $deps = New-DepsFixture -Sandbox $sandbox
        $stub = Start-ApiStub -Sandbox $sandbox -RawDir $deps.Served
        $taskStub = New-TaskStub -Sandbox $sandbox
        # The operator copies the two repository files in by hand (the documented fallback).
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Copy-Item -LiteralPath $RealDeps -Destination (Join-Path $stage 'bootstrap-deps.ps1') -Force
        Copy-Item -LiteralPath $RealDragon -Destination (Join-Path $stage 'Lab_Super.dragon') -Force
        $env = @{
            STUB_ARGV_LOG = $deps.ArgvLog; STUB_LIST_FILE = $deps.ListFile; STUB_INSTALL_OUTPUT_FILE = ''
            STUB_EXIT_CODE = '0'; STUB_SLEEP_SEC = '0'; STUB_SLEEP_SUBCOMMAND = ''
            STUB_TASK_LOG = $taskStub.Log; STUB_TASK_INSTALL_EXIT = '0'; STUB_TASK_START_EXIT = '0'; STUB_TASK_STATUS_EXIT = '0'
        }
        $r = Invoke-Bootstrap -Sandbox $sandbox -StageDir $stage -RunnerRoot $root -Instance $stub.Base `
            -ProvideToken $false -TaskBackend $taskStub.Script -VipmPath $VipmStubCmd `
            -LabViewPath $deps.LabView -NiRoot $deps.NiRoot -Env $env -ExtraArgs @('-SkipNode', '-SkipRunner')
        Assert-Equal 0 $r.ExitCode ("the offline fallback must exit 0 without a token; output:`n" + (Sanitize-Output $r.Output))
        Assert-Match $r.Output 'using the files already in the stage dir' 'the run must report that it used the staged files'
        Assert-Equal 0 (@(Get-ApiRequests -LogPath $stub.Log -RawOnly)).Count 'no raw fetch may happen when the files are already staged'
        $install = @(Get-Lines -Path $deps.ArgvLog -Pattern 'argv: install ')
        Assert-Equal 1 $install.Count 'bootstrap-deps.ps1 must still install from the staged dragon'
        $vipmSafeCopy = Join-Path (Join-Path $env:TEMP 'vipm-public-cwd') 'Lab_Super.dragon'
        Assert-Match $install[0] ([regex]::Escape($vipmSafeCopy) + '$') 'the install must run from the public-repo copy of the staged dragon'
        Assert-Equal (Get-FileHash -LiteralPath (Join-Path $stage 'Lab_Super.dragon') -Algorithm SHA256).Hash (Get-FileHash -LiteralPath $vipmSafeCopy -Algorithm SHA256).Hash 'the public-repo copy must be byte-identical to the staged dragon'
        Assert-True (Test-Path -LiteralPath (Join-Path $stage '.phase3-deps.done') -PathType Leaf) 'the phase-3 marker must be written'
        Write-Evidence ('offline fallback: raw fetches=0, vipm install -> ' + $install[0])
    }

    # ------------------------------------------------------------------ T11 -----
    Test-Case 'T11-spaced-paths' 'a runner root and stage dir containing spaces work end to end (Phase 2 + Phase 3)' {
        $sandbox = New-Sandbox 't11'
        $stage = Join-Path $sandbox 'stage dir with space'
        $root = Join-Path $sandbox 'runner root with space'
        $deps = New-DepsFixture -Sandbox $sandbox
        $stub = Start-ApiStub -Sandbox $sandbox -RawDir $deps.Served
        $taskStub = New-TaskStub -Sandbox $sandbox
        $argvLog = Join-Path $sandbox 'stub\runner-argv.log'
        # Both stubs share STUB_ARGV_LOG here (the runner registers AND the vipm stub runs in
        # this case); the "argv: register"/"argv: install" prefixes tell the lines apart.
        $env = @{
            STUB_ARGV_LOG = $argvLog; STUB_EXIT_CODE = '0'; STUB_CREATE_RUNNER = '1'
            STUB_ECHO_TOKEN = '0'; STUB_ECHO_ENV_TOKEN = '0'
            STUB_TASK_LOG = $taskStub.Log; STUB_TASK_INSTALL_EXIT = '0'; STUB_TASK_START_EXIT = '0'; STUB_TASK_STATUS_EXIT = '0'
            STUB_LIST_FILE = $deps.ListFile; STUB_INSTALL_OUTPUT_FILE = ''; STUB_SLEEP_SEC = '0'; STUB_SLEEP_SUBCOMMAND = ''
        }
        $r = Invoke-Bootstrap -Sandbox $sandbox -StageDir $stage -RunnerRoot $root -Instance $stub.Base `
            -KitApiBase $stub.Base `
            -RunnerBinary $RunnerStubCmd -TaskBackend $taskStub.Script -VipmPath $VipmStubCmd `
            -LabViewPath $deps.LabView -NiRoot $deps.NiRoot -Env $env -ExtraArgs @('-SkipNode')
        Assert-Equal 0 $r.ExitCode ("spaced paths must work end to end; output:`n" + (Sanitize-Output $r.Output))
        Assert-NoSentinel -Text $r.Output -Where 'stdout/stderr (spaced paths)'
        Assert-NoSentinelUnder -Dir $sandbox
        Assert-True (Test-Path -LiteralPath (Join-Path $root '.runner') -PathType Leaf) '.runner must land in the spaced root'
        $cfg = [System.IO.File]::ReadAllText((Join-Path $root 'config.yaml'))
        Assert-Match $cfg ('workdir_parent:\s*"' + [regex]::Escape($root.Replace('\', '/')) + '/_work"') 'the spaced workdir_parent must be rendered correctly'
        $taskLines = @(Get-Lines -Path $taskStub.Log)
        Assert-True ($taskLines.Count -ge 1) ('the task backend must have been invoked; child output:' + "`n" + (Sanitize-Output $r.Output))
        Assert-Match $taskLines[0] ([regex]::Escape('"' + (Join-Path $root 'config.yaml') + '"')) 'the task action must quote the spaced config path'
        $install = @(Get-Lines -Path $argvLog -Pattern 'argv: install ')
        Assert-True ($install.Count -ge 1) ('Phase 3 must have run bootstrap-deps.ps1; child output:' + "`n" + (Sanitize-Output $r.Output))
        $vipmSafeCopy = Join-Path (Join-Path $env:TEMP 'vipm-public-cwd') 'Lab_Super.dragon'
        Assert-Match $install[0] ([regex]::Escape($vipmSafeCopy) + '$') 'the spaced staged dragon must reach vipm through its public-repo copy'
        Assert-Equal (Get-FileHash -LiteralPath (Join-Path $stage 'Lab_Super.dragon') -Algorithm SHA256).Hash (Get-FileHash -LiteralPath $vipmSafeCopy -Algorithm SHA256).Hash 'the public-repo copy must be byte-identical to the spaced staged dragon'
        Write-Evidence ('spaced root=' + $root + ' | vipm install -> ' + $install[0])
    }

    # ------------------------------------------------------------------ T12 -----
    Test-Case 'T12-malformed-inputs' 'empty token / bad URL / capacity 0 / bad slug / bad ref / missing binary / zero timeout -> exit 2, nothing created, no HTTP request' {
        $variants = @(
            [pscustomobject]@{ Tag = 'no-token'; ProvideToken = $false; Instance = ''; RepoSlug = ''; Ref = ''; Capacity = 0; RunnerBinary = ''; Extra = @(); Expect = 'token' },
            [pscustomobject]@{ Tag = 'bad-url'; ProvideToken = $true; Instance = 'ftp://gitea.sevenology.top'; RepoSlug = ''; Ref = ''; Capacity = 0; RunnerBinary = ''; Extra = @(); Expect = 'ftp' },
            [pscustomobject]@{ Tag = 'capacity-0'; ProvideToken = $true; Instance = ''; RepoSlug = ''; Ref = ''; Capacity = 0; RunnerBinary = ''; Extra = @('-Capacity', '0'); Expect = 'Capacity' },
            [pscustomobject]@{ Tag = 'bad-slug'; ProvideToken = $true; Instance = ''; RepoSlug = 'not-a-slug'; Ref = ''; Capacity = 0; RunnerBinary = ''; Extra = @(); Expect = 'not-a-slug' },
            [pscustomobject]@{ Tag = 'bad-ref'; ProvideToken = $true; Instance = ''; RepoSlug = ''; Ref = 'dev branch'; Capacity = 0; RunnerBinary = ''; Extra = @(); Expect = 'dev branch' },
            [pscustomobject]@{ Tag = 'missing-binary'; ProvideToken = $true; Instance = ''; RepoSlug = ''; Ref = ''; Capacity = 0; RunnerBinary = 'C:\does-not-exist\gitea-runner.exe'; Extra = @(); Expect = 'does-not-exist' },
            [pscustomobject]@{ Tag = 'zero-timeout'; ProvideToken = $true; Instance = ''; RepoSlug = ''; Ref = ''; Capacity = 0; RunnerBinary = ''; Extra = @('-DownloadTimeoutSec', '0'); Expect = 'DownloadTimeoutSec' }
        )
        foreach ($v in $variants) {
            $sandbox = New-Sandbox ('t12-' + $v.Tag)
            $stage = Join-Path $sandbox 'stage'
            $root = Join-Path $sandbox 'runner-root'
            $deps = New-DepsFixture -Sandbox $sandbox
            $stub = Start-ApiStub -Sandbox $sandbox -RawDir $deps.Served
            $taskStub = New-TaskStub -Sandbox $sandbox
            $env = @{ STUB_TASK_LOG = $taskStub.Log; STUB_ARGV_LOG = (Join-Path $sandbox 'stub\argv.log') }
            $call = @{
                Sandbox = $sandbox; StageDir = $stage; RunnerRoot = $root; ProvideToken = $v.ProvideToken
                TaskBackend = $taskStub.Script; Env = $env; ExtraArgs = $v.Extra
                GitHubToken = $GhSentinel
                Instance = $(if ([string]::IsNullOrWhiteSpace($v.Instance)) { $stub.Base } else { $v.Instance })
                RepoSlug = $(if ([string]::IsNullOrWhiteSpace($v.RepoSlug)) { 'MICA/MICA' } else { $v.RepoSlug })
                Ref = $(if ([string]::IsNullOrWhiteSpace($v.Ref)) { 'dev' } else { $v.Ref })
                RunnerBinary = $v.RunnerBinary
            }
            $r = Invoke-Bootstrap @call
            Assert-Equal 2 $r.ExitCode ("malformed '" + $v.Tag + "' must exit 2; output:`n" + (Sanitize-Output $r.Output))
            Assert-Contains $r.Output $v.Expect ("the diagnostic for '" + $v.Tag + "' must name the offending value")
            Assert-True (-not (Test-Path -LiteralPath $stage)) ("nothing may be created for '" + $v.Tag + "' (stage dir)")
            Assert-True (-not (Test-Path -LiteralPath $root)) ("nothing may be created for '" + $v.Tag + "' (runner root)")
            Assert-Equal 0 (@(Get-ScriptRequests -LogPath $stub.Log)).Count ("no HTTP request may be made for '" + $v.Tag + "'")
            Assert-Equal 0 (@(Get-Lines -Path $taskStub.Log)).Count ("no task verb may run for '" + $v.Tag + "'")
            Write-Evidence ("'" + $v.Tag + "' -> exit 2, names [" + $v.Expect + "], nothing created, no request")
        }
    }

    # --- receipts -----------------------------------------------------------------
    Write-Host ''
    Write-Host '[receipt] T02 register argv:'
    $t02Roots = @($script:TmpRoots | Where-Object { $_ -match 'mica-vb-t02-' })
    if ($t02Roots.Count -gt 0) {
        foreach ($l in @(Get-Lines -Path (Join-Path $t02Roots[0] 'stub\runner-argv.log'))) { Write-Host ('    ' + (Sanitize-Output $l)) }
        $cfgPath = Join-Path $t02Roots[0] 'runner-root\config.yaml'
        if (Test-Path -LiteralPath $cfgPath) {
            Write-Host '[receipt] rendered config.yaml:'
            foreach ($cl in @([System.IO.File]::ReadAllText($cfgPath) -split "`r?`n")) { Write-Host ('    ' + $cl) }
        }
    }
    Write-Host '[receipt] T03 raw requests (api-stub log):'
    $t03Roots = @($script:TmpRoots | Where-Object { $_ -match 'mica-vb-t03-' })
    if ($t03Roots.Count -gt 0) {
        foreach ($l in @(Get-ApiRequests -LogPath (Join-Path $t03Roots[0] 'api-stub\requests.jsonl') -RawOnly)) {
            Write-Host ('    ' + ($l | ConvertTo-Json -Compress))
        }
        Write-Host '[receipt] T03 vipm stub log:'
        foreach ($l in @(Get-Lines -Path (Join-Path $t03Roots[0] 'vipm-stub\argv.log'))) { Write-Host ('    ' + $l) }
        Write-Host '[receipt] T03 staged files:'
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $t03Roots[0] 'stage') -Force -File)) {
            Write-Host ('    ' + $f.Name + '  ' + $f.Length + ' bytes  sha256=' + (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.Substring(0, 16) + '...')
        }
    }
}
finally {
    Write-Host ''
    Write-Host '[receipt] stopping stub processes:'
    foreach ($p in $script:StubProcs) {
        $alive = $false
        try { $alive = -not $p.HasExited } catch { $alive = $false }
        if ($alive) { try { $p.Kill($true) } catch { } }
        try { [void]$p.WaitForExit(5000) } catch { }
        $stillAlive = $false
        try { $stillAlive = -not $p.HasExited } catch { $stillAlive = $false }
        Write-Host ('    pid ' + $p.Id + ' -> still running: ' + $stillAlive)
    }
    foreach ($port in $script:StubPorts) {
        $listening = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
        Write-Host ('    port ' + $port + ' -> listeners: ' + $listening.Count)
    }
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
