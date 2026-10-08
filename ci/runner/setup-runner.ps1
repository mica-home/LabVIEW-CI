#Requires -Version 7.0
<#
.SYNOPSIS
    Bootstrap and register the MICA Gitea Actions Windows runner inside the build VM (Lane 3).

.DESCRIPTION
    Idempotent, re-runnable setup for the Windows runner that executes the MICA tag
    builds (labels: windows-labview26:host, capacity 1). The script:

      1. validates every input before touching the disk (instance URL / name / labels /
         capacity / token / binary path, plus the work-directory safety guard below);
      2. resolves the gitea-runner binary: -BinaryPath when given, otherwise
         <RunnerRoot>\gitea-runner.exe (reused when already present) or downloaded from
         dl.gitea.com (windows-amd64);
      3. renders <RunnerRoot>\config.yaml (log.level, runner.capacity, runner.labels,
         host.workdir_parent - never any credential);
      4. registers the runner with
             & <binary> register --no-interactive --instance <url> --token <t> --name <name> --labels <labels>
         executed with <RunnerRoot> as the working directory, so the runner's own .runner
         state file lands next to config.yaml (the runner - not this script - owns that file);
      5. ensures autostart: -ServiceTask registers a scheduled task (startup + logon, current
         interactive user; daemon output appended to <RunnerRoot>\runner-daemon.log). Without
         -ServiceTask the manual daemon command is printed and an already-existing task is
         only re-enabled.

    Invariants (load-bearing, asserted by ci/tests/setup-runner.tests.ps1):

      * The registration token is NEVER echoed and NEVER written to any file. It is passed
        to the runner as an argv value, and every line the child process prints is redacted
        against the token value before this script echoes it.
      * Idempotency: when <RunnerRoot>\.runner exists, registration is skipped (config and
        autostart are still re-ensured) unless -Force is given.
      * Work-directory guard: the effective work dir (default <RunnerRoot>\_work) must not
        be equal to or inside any git repository (a .git entry anywhere on the parent
        chain) - the script refuses before anything is written. -RunnerRoot itself is
        guarded the same way (writing runner state into a repo would dirty a worktree).
      * A failed registration never leaves a half-registered state: a .runner written by
        this run is deleted, a pre-existing registration displaced by -Force is restored
        from .runner.bak, a config.yaml created by this run is deleted, and empty
        directories this run created are removed. Success is only reported when the runner
        exited 0 AND .runner exists afterwards (exit code alone is not trusted).

    The script itself never talks to the Gitea instance: only the runner binary it invokes
    does, and only when registration actually runs.

    Environment:
      GITEA_RUNNER_REGISTRATION_TOKEN   registration token, used when -RegistrationToken
                                        is not given. Prefer this over typing the token on
                                        the command line (see docs/vm-runner.md section 7).

.NOTES
    Exit codes:
      0  registered (or already registered) and config/autostart ensured
      2  usage/config error (bad URL / labels / name / capacity, missing token, bad
         -BinaryPath, -RunnerRoot or -WorkDir inside a git repository, ...)
      3  registration failed (non-zero runner exit, or exit 0 without .runner)
      4  the runner binary could not be obtained (download failure)
      5  scheduled task registration failed (-ServiceTask)

    Platform: Windows only (the runner is windows-amd64). Runbook: docs/vm-runner.md.

.EXAMPLE
    # VM, registration token supplied out-of-band (never typed on the command line):
    $t = Read-Host -Prompt 'Gitea registration token' -MaskInput
    $env:GITEA_RUNNER_REGISTRATION_TOKEN = $t; Remove-Variable t
    pwsh -NoProfile -File ci/runner/setup-runner.ps1 -ServiceTask
    Remove-Item Env:\GITEA_RUNNER_REGISTRATION_TOKEN
#>
[CmdletBinding()]
param(
    [string]$RunnerRoot = 'D:\gitea-runner',
    [string]$InstanceUrl = 'https://gitea.sevenology.top',
    [string]$Name = 'mica-build-01',
    [string]$Labels = 'windows-labview26:host',
    [int]$Capacity = 1,
    [string]$WorkDir = '',
    [string]$RegistrationToken = '',
    [string]$BinaryPath = '',
    [string]$RunnerVersion = 'latest',
    [switch]$ServiceTask,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# A non-zero exit of a native command is data here (we inspect $LASTEXITCODE and .runner),
# not a terminating error.
$PSNativeCommandUseErrorActionPreference = $false

$script:LogPrefix = '[runner] '
$script:ExitUsage = 2
$script:ExitRegisterFailed = 3
$script:ExitDownloadFailed = 4
$script:ExitServiceTaskFailed = 5

# --- logging / small helpers ---------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ($script:LogPrefix + $Message) -ForegroundColor $Color
}

function Write-Err {
    param([string]$Message)
    [Console]::Error.WriteLine($script:LogPrefix + $Message)
}

function Stop-Usage {
    param([string]$Message, [string[]]$Hints = @())
    Write-Err ('usage/configuration error: ' + $Message)
    Write-Host ''
    Write-Host 'usage:'
    Write-Host '  pwsh -File ci/runner/setup-runner.ps1 [-RunnerRoot <dir>] [-InstanceUrl <url>] [-Name <name>]'
    Write-Host "       [-Labels 'windows-labview26:host'] [-Capacity 1] [-WorkDir <dir>]"
    Write-Host '       [-RegistrationToken <t> | env GITEA_RUNNER_REGISTRATION_TOKEN]'
    Write-Host '       [-BinaryPath <local gitea-runner(.exe)>] [-RunnerVersion <ver|latest>]'
    Write-Host '       [-ServiceTask] [-Force]'
    Write-Host 'full guide: docs/vm-runner.md, section 7.'
    foreach ($h in $Hints) { Write-Host ('  - ' + $h) }
    exit $script:ExitUsage
}

function Protect-Secret {
    param([string]$Text, [string]$Secret)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ([string]::IsNullOrEmpty($Secret) -or $Secret.Length -lt 4) { return $Text }
    return $Text.Replace($Secret, '<redacted>')
}

function Resolve-AbsolutePath {
    param([string]$Path)
    try {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }
    catch {
        throw ('cannot resolve path "' + $Path + '": ' + $_.Exception.Message)
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) { throw ('path resolved to empty: ' + $Path) }
    return $resolved
}

function Find-EnclosingGitRepo {
    # Returns the repo root when $Path is equal to or inside a git repository, else $null.
    # Structural check (.git entry on the parent chain) - works for paths that do not exist yet.
    param([string]$Path)
    $dir = $null
    try { $dir = [System.IO.DirectoryInfo]::new($Path) } catch { return $null }
    while ($null -ne $dir) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName '.git')) {
            return $dir.FullName.TrimEnd([char[]]@('\', '/'))
        }
        $dir = $dir.Parent
    }
    return $null
}

function Get-ConfigYaml {
    param([string]$LabelsCsv, [int]$Capacity, [string]$WorkDirPath)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Generated by ci/runner/setup-runner.ps1 - re-run the script instead of editing by hand.')
    [void]$sb.AppendLine('# Contains no credentials: the registration token is never persisted by the script.')
    [void]$sb.AppendLine('log:')
    [void]$sb.AppendLine('  level: info')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('runner:')
    [void]$sb.AppendLine('  file: .runner')
    [void]$sb.AppendLine('  capacity: ' + $Capacity)
    [void]$sb.AppendLine('  timeout: 3h')
    [void]$sb.AppendLine('  labels:')
    foreach ($item in @($LabelsCsv.Split(','))) {
        $label = $item.Trim()
        if ($label.Length -gt 0) { [void]$sb.AppendLine('    - "' + $label + '"') }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('host:')
    [void]$sb.AppendLine('  workdir_parent: "' + $WorkDirPath.Replace('\', '/') + '"')
    return $sb.ToString()
}

# --- banner and input validation ------------------------------------------------

Write-Host '== MICA Gitea runner setup =='
Write-Log ('script        : ' + $PSCommandPath)
Write-Log ('platform      : ' + [System.Environment]::OSVersion.VersionString)

if (-not $IsWindows) {
    Stop-Usage 'gitea-runner is a windows-amd64 binary; this script supports Windows only.'
}

if ([string]::IsNullOrWhiteSpace($RunnerRoot)) { Stop-Usage '-RunnerRoot must not be empty.' }
try { $RunnerRootFull = Resolve-AbsolutePath -Path $RunnerRoot }
catch { Stop-Usage $_.Exception.Message }

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $WorkDirFull = Join-Path $RunnerRootFull '_work'
}
else {
    try { $WorkDirFull = Resolve-AbsolutePath -Path $WorkDir }
    catch { Stop-Usage $_.Exception.Message }
}

# Safety guard: runner state / work directories must never live in a git working tree.
$workDirRepo = Find-EnclosingGitRepo -Path $WorkDirFull
if ($null -ne $workDirRepo) {
    Stop-Usage ('work dir is inside a git repository, refusing to run: ' + $WorkDirFull + ' (repo root: ' + $workDirRepo + ').') @(
        'the runner work dir continuously creates and deletes files; placing it inside a repo pollutes the working tree.',
        'keep the default <RunnerRoot>\_work (outside any repo) or pass an explicit -WorkDir outside the repository.'
    )
}
$runnerRootRepo = Find-EnclosingGitRepo -Path $RunnerRootFull
if ($null -ne $runnerRootRepo) {
    Stop-Usage ('-RunnerRoot is inside a git repository, refusing to run: ' + $RunnerRootFull + ' (repo root: ' + $runnerRootRepo + ').') @(
        'the .runner state and work dir must not live inside a repo; point -RunnerRoot at a directory outside any repository (recommended D:\gitea-runner).'
    )
}

if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    Stop-Usage ('invalid -Name: "' + $Name + '". Allowed: letters, digits, dot, underscore, hyphen; must start with a letter or digit.')
}

if ([string]::IsNullOrWhiteSpace($Labels)) { Stop-Usage '-Labels must not be empty.' }
$labelList = @()
foreach ($item in @($Labels.Split(','))) {
    $label = $item.Trim()
    if ($label.Length -eq 0) { continue }
    if ($label -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*:[A-Za-z0-9][A-Za-z0-9._/@:-]*$') {
        Stop-Usage ('invalid -Labels entry: "' + $label + '". Expected "<name>:<type>", e.g. windows-labview26:host.') @(
            'separate multiple labels with commas; type host means steps execute directly on the VM (this project usage).'
        )
    }
    $labelList += $label
}
if ($labelList.Count -eq 0) { Stop-Usage '-Labels resolved to an empty list.' }

if ($Capacity -lt 1 -or $Capacity -gt 64) {
    Stop-Usage ('invalid -Capacity: ' + $Capacity + ' (allowed 1..64).') @(
        'this project recommends keeping 1: one job at a time, so concurrent builds never fight over LabVIEW and the VI Server port.'
    )
}

$parsedUri = $null
if (-not [Uri]::TryCreate($InstanceUrl, [UriKind]::Absolute, [ref]$parsedUri)) {
    Stop-Usage ('invalid -InstanceUrl: "' + $InstanceUrl + '". An absolute URL is required, e.g. https://gitea.example.com.')
}
if ($parsedUri.Scheme -ne 'http' -and $parsedUri.Scheme -ne 'https') {
    Stop-Usage ('invalid -InstanceUrl scheme: "' + $parsedUri.Scheme + '". Only http/https are supported.')
}
if ([string]::IsNullOrWhiteSpace($parsedUri.Host)) {
    Stop-Usage ('invalid -InstanceUrl: missing host name (' + $InstanceUrl + ').')
}
$InstanceUrlNormalized = $InstanceUrl.TrimEnd('/')

$token = $RegistrationToken
$tokenSource = '-RegistrationToken'
if ([string]::IsNullOrWhiteSpace($token)) {
    $token = [Environment]::GetEnvironmentVariable('GITEA_RUNNER_REGISTRATION_TOKEN', 'Process')
    $tokenSource = 'environment variable GITEA_RUNNER_REGISTRATION_TOKEN'
}
if ([string]::IsNullOrWhiteSpace($token)) {
    Stop-Usage 'missing registration token: pass -RegistrationToken or set the environment variable GITEA_RUNNER_REGISTRATION_TOKEN.' @(
        'how to get one: Gitea web UI -> repository (or organization) Settings -> Actions -> Runners -> Create new runner; copy the token (shown only once).',
        'prefer reading it with Read-Host -MaskInput into an environment variable so it never lands in command-line history (see docs/vm-runner.md, section 7).'
    )
}
$token = $token.Trim()

$BinaryFull = ''
if (-not [string]::IsNullOrWhiteSpace($BinaryPath)) {
    try { $BinaryFull = Resolve-AbsolutePath -Path $BinaryPath }
    catch { Stop-Usage $_.Exception.Message }
    if (-not (Test-Path -LiteralPath $BinaryFull -PathType Leaf)) {
        Stop-Usage ('-BinaryPath points at a missing file: ' + $BinaryFull) @(
            'download gitea-runner (windows-amd64) inside the VM first, then point -BinaryPath at the file.'
        )
    }
}

$configPath = Join-Path $RunnerRootFull 'config.yaml'
$statePath = Join-Path $RunnerRootFull '.runner'
$backupPath = Join-Path $RunnerRootFull '.runner.bak'
$taskName = 'MICA Gitea Runner (' + $Name + ')'

Write-Log ('runner root   : ' + $RunnerRootFull)
Write-Log ('instance      : ' + $InstanceUrlNormalized)
Write-Log ('name          : ' + $Name)
Write-Log ('labels        : ' + ($labelList -join ','))
Write-Log ('capacity     : ' + $Capacity)
Write-Log ('work dir      : ' + $WorkDirFull)
Write-Log ('token         : provided (source: ' + $tokenSource + '; never echoed, never written to disk)')
Write-Log ('binary        : ' + $(if ($BinaryFull) { $BinaryFull } else { '<default: download to ' + (Join-Path $RunnerRootFull 'gitea-runner.exe') + '>' }))
Write-Log ('auto-start    : ' + $(if ($ServiceTask) { 'register a scheduled task (at boot + at logon)' } else { 'none (only the manual start command is printed)' }))
Write-Log ('force re-register: ' + [bool]$Force)

$runnerRootDrive = [System.IO.Path]::GetPathRoot($RunnerRootFull)
if ($runnerRootDrive -match '^[Cc]:') {
    Write-Log ('warning: -RunnerRoot is on C: (' + $RunnerRootFull + '). The VM system drive is usually tight on space; prefer D: or E: (see docs/vm-runner.md, section 2).') -Color Yellow
}

# --- filesystem setup -----------------------------------------------------------

$script:RootCreatedByUs = -not (Test-Path -LiteralPath $RunnerRootFull -PathType Container)
if ($script:RootCreatedByUs) {
    New-Item -ItemType Directory -Path $RunnerRootFull -Force | Out-Null
    Write-Log ('created runner root: ' + $RunnerRootFull)
}
$script:WorkDirCreatedByUs = -not (Test-Path -LiteralPath $WorkDirFull -PathType Container)
if ($script:WorkDirCreatedByUs) {
    New-Item -ItemType Directory -Path $WorkDirFull -Force | Out-Null
    Write-Log ('created work dir: ' + $WorkDirFull)
}

# --- resolve the runner binary ---------------------------------------------------

$script:DownloadPartial = ''
if (-not $BinaryFull) {
    $targetExe = Join-Path $RunnerRootFull 'gitea-runner.exe'
    if ((Test-Path -LiteralPath $targetExe -PathType Leaf) -and -not $Force) {
        $BinaryFull = $targetExe
        Write-Log ('reusing existing binary: ' + $targetExe + ' (add -Force to re-download)')
    }
    else {
        # NOTE: this branch performs a real download. It is deliberately never exercised by
        # the test suite (tests always pass -BinaryPath pointing at the stub fixture).
        $url = 'https://dl.gitea.com/gitea-runner/' + $RunnerVersion + '/gitea-runner-' + $RunnerVersion + '-windows-amd64.exe'
        $script:DownloadPartial = $targetExe + '.download'
        Write-Log ('downloading runner binary: ' + $url)
        if ($RunnerVersion -eq 'latest') {
            Write-Log '(-RunnerVersion latest relies on an upstream-maintained file path; on a 404, look up the version at https://dl.gitea.com/gitea-runner/ and rerun with -RunnerVersion <x.y.z>, or download manually and pass -BinaryPath.)'
        }
        try {
            Invoke-WebRequest -Uri $url -OutFile $script:DownloadPartial -MaximumRedirection 5
        }
        catch {
            if (Test-Path -LiteralPath $script:DownloadPartial) { Remove-Item -LiteralPath $script:DownloadPartial -Force -ErrorAction SilentlyContinue }
            Write-Err ('download failed: ' + $url + ' -> ' + $_.Exception.Message)
            Write-Host ($script:LogPrefix + 'troubleshooting:')
            Write-Host '  1) confirm the VM has outbound access to dl.gitea.com / github.com (NAT is enough; see docs/vm-runner.md, section 2).'
            Write-Host '  2) download the windows-amd64 gitea-runner manually and rerun this script with -BinaryPath <file> (recommended: controlled source, no script network access).'
            Write-Host '  3) behind a proxy, set $env:HTTPS_PROXY in this session and rerun.'
            exit $script:ExitDownloadFailed
        }
        Move-Item -LiteralPath $script:DownloadPartial -Destination $targetExe -Force
        $script:DownloadPartial = ''
        $BinaryFull = $targetExe
        Write-Log ('downloaded: ' + $targetExe)
    }
}
if (-not (Test-Path -LiteralPath $BinaryFull -PathType Leaf)) {
    Stop-Usage ('runner binary is not usable: ' + $BinaryFull)
}
$binaryHash = (Get-FileHash -LiteralPath $BinaryFull -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Log ('binary sha256 : ' + $binaryHash)

# --- config.yaml (never contains the token) --------------------------------------

$configContent = Get-ConfigYaml -LabelsCsv ($labelList -join ',') -Capacity $Capacity -WorkDirPath $WorkDirFull

$script:ConfigCreatedByUs = -not (Test-Path -LiteralPath $configPath -PathType Leaf)
$configChanged = $true
if (-not $script:ConfigCreatedByUs) {
    $existing = [System.IO.File]::ReadAllText($configPath)
    if ($existing -ceq $configContent) { $configChanged = $false }
}
if ($configChanged) {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($configPath, $configContent, $utf8NoBom)
    if ($script:ConfigCreatedByUs) { Write-Log ('generated config.yaml: ' + $configPath) }
    else { Write-Log ('updated config.yaml: ' + $configPath) }
}
else {
    Write-Log ('config.yaml already up to date (not rewritten): ' + $configPath)
}
# Read back: a truncated/odd write must fail loudly here, not inside the runner.
$postConfig = [System.IO.File]::ReadAllText($configPath)
if ($postConfig -cne $configContent) {
    Write-Err ('config.yaml read-back verification failed: ' + $configPath)
    exit $script:ExitUsage
}

# --- registration ----------------------------------------------------------------

$alreadyRegistered = Test-Path -LiteralPath $statePath -PathType Leaf
$skippedRegistration = $false

function Clear-FailedRegistration {
    # Removes everything THIS run produced; restores a registration displaced by -Force.
    param([string]$Reason)
    Write-Log ('cleaning up partial state (' + $Reason + '):')
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Remove-Item -LiteralPath $statePath -Force
        Write-Log ('  deleted the .runner created by this registration: ' + $statePath)
    }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        Move-Item -LiteralPath $backupPath -Destination $statePath -Force
        Write-Log ('  restored the pre-registration .runner (-Force backup rollback)')
    }
    if ($script:ConfigCreatedByUs -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Remove-Item -LiteralPath $configPath -Force
        Write-Log ('  deleted the config.yaml generated this run: ' + $configPath)
    }
    if ($script:DownloadPartial -and (Test-Path -LiteralPath $script:DownloadPartial)) {
        Remove-Item -LiteralPath $script:DownloadPartial -Force -ErrorAction SilentlyContinue
        Write-Log ('  deleted the incomplete download file: ' + $script:DownloadPartial)
    }
    if ($script:WorkDirCreatedByUs -and (Test-Path -LiteralPath $WorkDirFull -PathType Container)) {
        if (@(Get-ChildItem -LiteralPath $WorkDirFull -Force).Count -eq 0) {
            Remove-Item -LiteralPath $WorkDirFull -Force
            Write-Log ('  deleted the empty work dir created this run: ' + $WorkDirFull)
        }
        else {
            Write-Log ('  work dir not empty, kept: ' + $WorkDirFull)
        }
    }
    if ($script:RootCreatedByUs -and (Test-Path -LiteralPath $RunnerRootFull -PathType Container)) {
        if (@(Get-ChildItem -LiteralPath $RunnerRootFull -Force).Count -eq 0) {
            Remove-Item -LiteralPath $RunnerRootFull -Force
            Write-Log ('  deleted the empty root dir created this run: ' + $RunnerRootFull)
        }
        else {
            Write-Log ('  root dir not empty (e.g. a downloaded binary), kept: ' + $RunnerRootFull)
        }
    }
}

if ($alreadyRegistered -and -not $Force) {
    $skippedRegistration = $true
    Write-Log ('existing registration state found (' + $statePath + '): skipping registration (idempotent). Add -Force to re-register.')
    Write-Log 'note: the runner name on the Gitea side follows the existing .runner; -Name only affects the first registration.'
}
else {
    if ($alreadyRegistered) {
        Move-Item -LiteralPath $statePath -Destination $backupPath -Force
        Write-Log ('-Force: backed up the existing .runner to ' + $backupPath + ' (automatic rollback on failure)')
    }

    $displayArgs = @('register', '--no-interactive', '--instance', $InstanceUrlNormalized, '--token', '<redacted>', '--name', $Name, '--labels', ($labelList -join ','))
    Write-Log ('registering (work dir ' + $RunnerRootFull + '):')
    Write-Log ('  ' + $BinaryFull + ' ' + ($displayArgs -join ' '))

    $registerArgs = @('register', '--no-interactive', '--instance', $InstanceUrlNormalized, '--token', $token, '--name', $Name, '--labels', ($labelList -join ','))
    $registerOut = @()
    $exitCode = 127
    Push-Location -LiteralPath $RunnerRootFull
    try {
        $registerOut = @(& $BinaryFull @registerArgs 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        $registerOut = @('the registration command threw an exception: ' + $_.Exception.Message)
        $exitCode = 127
    }
    finally {
        Pop-Location
    }
    foreach ($line in $registerOut) {
        Write-Host ($script:LogPrefix + '[register] ' + (Protect-Secret -Text ([string]$line) -Secret $token))
    }

    $registeredNow = Test-Path -LiteralPath $statePath -PathType Leaf
    if ($exitCode -ne 0 -or -not $registeredNow) {
        if ($exitCode -ne 0) {
            Write-Err ('registration failed: runner exit code ' + $exitCode + ' (see the [register] output above).')
        }
        else {
            Write-Err ('the registration command reported success (exit 0) but did not produce ' + $statePath + ': incomplete state, treating as failure.')
        }
        Clear-FailedRegistration -Reason 'registration failed'
        Write-Host ''
        Write-Host ($script:LogPrefix + 'troubleshooting:')
        Write-Host '  1) confirm the registration token is valid and unexpired (get a fresh one: Gitea web UI -> repo/org Settings -> Actions -> Runners -> Create new runner).'
        Write-Host ('  2) confirm the VM can reach the instance: ' + $InstanceUrlNormalized + ' (a browser or Test-NetConnection both work).')
        Write-Host '  3) after fixing, rerun this script: it is idempotent and never deletes an already-registered state.'
        exit $script:ExitRegisterFailed
    }

    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        Remove-Item -LiteralPath $backupPath -Force
        Write-Log 'registration succeeded: deleted the .runner.bak created by -Force'
    }
    Write-Log ('registered: ' + $Name + ' -> ' + $InstanceUrlNormalized)
}

# --- autostart -------------------------------------------------------------------

$daemonLogPath = Join-Path $RunnerRootFull 'runner-daemon.log'
$manualDaemonCommand = "Set-Location -LiteralPath '" + $RunnerRootFull + "'; & '" + $BinaryFull + "' -c '" + $configPath + "' daemon"

if ($ServiceTask) {
    try {
        $argLine = '/c ""' + $BinaryFull + '" -c "' + $configPath + '" daemon >> "' + $daemonLogPath + '" 2>&1"'
        $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $argLine -WorkingDirectory $RunnerRootFull
        $triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn))
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal `
            -Description ('MICA Gitea Actions runner daemon (' + $Name + ') - managed by ci/runner/setup-runner.ps1') -Force | Out-Null
        Write-Log ('registered scheduled task: ' + $taskName + ' (triggers: at boot + at logon; principal: current user interactive session)')
        Write-Log ('daemon output appended to: ' + $daemonLogPath)
        try {
            Start-ScheduledTask -TaskName $taskName
            Write-Log 'scheduled task started immediately (once the VM can reach Gitea, the runner turns Online shortly).'
        }
        catch {
            Write-Log ('warning: scheduled task registered, but the immediate start failed: ' + $_.Exception.Message + '; run Start-ScheduledTask manually later or reboot the VM.') -Color Yellow
        }
    }
    catch {
        Write-Err ('registering the scheduled task failed: ' + $_.Exception.Message)
        Write-Host ($script:LogPrefix + 'troubleshooting:')
        Write-Host '  1) rerun elevated as administrator (scheduled-task registration usually requires it);'
        Write-Host '  2) or drop -ServiceTask, start the daemon manually with the command below, and configure auto-start yourself (Task Scheduler GUI / WinSW).'
        Write-Host ('     ' + $manualDaemonCommand)
        exit $script:ExitServiceTaskFailed
    }
}
else {
    $existingTask = $null
    try { $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch { $existingTask = $null }
    if ($null -ne $existingTask) {
        Write-Log ('scheduled task already exists: ' + $taskName + ' (current state: ' + $existingTask.State + ')')
        if ("$($existingTask.State)" -eq 'Disabled') {
            try {
                Enable-ScheduledTask -TaskName $taskName | Out-Null
                Write-Log 'scheduled task was disabled; re-enabled it (keeps auto-start working).'
            }
            catch {
                Write-Log ('warning: could not enable the scheduled task: ' + $_.Exception.Message) -Color Yellow
            }
        }
    }
    else {
        Write-Log '-ServiceTask not given: no auto-start created. Start the daemon manually (foreground, Ctrl+C to stop):'
        Write-Log ('  ' + $manualDaemonCommand)
        Write-Log '(for auto-start at boot: rerun this script with -ServiceTask.)'
    }
}

# --- success summary ---------------------------------------------------------------

Write-Host ''
Write-Log 'Done. Summary:' 
Write-Log ('  runner root   : ' + $RunnerRootFull)
if ($configChanged) { Write-Log ('  config.yaml   : ' + $configPath + ' (written this run)') }
else { Write-Log ('  config.yaml   : ' + $configPath + ' (unchanged)') }
Write-Log ('  work dir      : ' + $WorkDirFull)
Write-Log ('  labels        : ' + ($labelList -join ','))
Write-Log ('  capacity      : ' + $Capacity)
if ($skippedRegistration) { Write-Log '  registration  : existing state found (registration skipped this run; -Force forces a re-register)' }
else { Write-Log '  registration  : succeeded this run' }
Write-Log ('  token         : never echoed, never written to any file (source: ' + $tokenSource + ')')
Write-Host ''
Write-Log 'next steps: after starting the daemon, open the Gitea web UI:'
Write-Log ('  ' + $InstanceUrlNormalized)
Write-Log ('  go to repo (or org) Settings -> Actions -> Runners and confirm runner "' + $Name + '" shows Online (green).')
Write-Log '  note: while the daemon is down the runner shows offline; jobs matching its labels queue up (they are not lost) and are picked up once the daemon is back.'
Write-Log '  runbook (snapshots, troubleshooting, decommissioning): docs/vm-runner.md'

exit 0
