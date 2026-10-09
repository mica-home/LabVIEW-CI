#Requires -Version 7.0
<#
.SYNOPSIS
    One-file bootstrap package for a fresh Windows build VM: Node -> Gitea runner -> VIPM deps.

.DESCRIPTION
    Copy this single file into the VM, run it once, paste the Gitea runner registration
    token when prompted. Everything else is downloaded or discovered by the script; no
    repository checkout and no other secret is required.

    The script runs four phases and is safe to re-run at any point:

      Phase 0  preflight report (always runs). Hostname, every IPv4 address, OS, admin
               status, free space on the system drive and D:, the Node version, LabVIEW and
               VIPM probes, plus the explicit list of things a human still has to install
               (LabVIEW 2026 Professional with Application Builder, the four NI runtimes,
               VIPM) with their expected paths. Written to <StageDir>\preflight.json.
      Phase 1  Node.js >= 20. Skipped when the probe already passes; otherwise
               `winget install OpenJS.NodeJS.LTS --silent` (bounded by -WingetTimeoutSec),
               then a re-probe. When that fails the official MSI download page and the
               latest-lts directory are printed and the script exits 6 (re-runnable).
      Phase 2  gitea-runner. Resolve/download the windows-amd64 binary, render
               <RunnerRoot>\config.yaml (labels windows-labview26:host, capacity 1,
               host.workdir_parent <RunnerRoot>\_work - never a credential), register the
               runner, install the scheduled task `MicaGiteaRunner` (SYSTEM, AtStartup),
               start it and verify the daemon PROCESS exists. The registration token is
               passed to the runner ONLY through the environment variable
               GITEA_RUNNER_REGISTRATION_TOKEN: never on the command line, never written to
               a file, never echoed (every child output line is redacted first).
      Phase 3  dependencies. Fetch ci/bootstrap-deps.ps1 from the kit's home on GitHub (this
               repository: mica-home/LabVIEW-CI@main - -KitRepoSlug/-KitRef) through the
               GitHub contents API (Accept: application/vnd.github.raw). The kit repository
               is public, so this fetch is ANONYMOUS by default; -GitHubToken / env
               GITHUB_TOKEN is optional and adds an Authorization: Bearer header (higher
               rate limits, or a private fork). -KitForge gitea switches back to the legacy
               Gitea raw route, which keeps requiring the registration token. Lab_Super.dragon
               comes from the MICA repository (-RepoSlug/-Ref) through the Gitea raw API with
               the runner registration token, into <StageDir>, then run bootstrap-deps.ps1
               -DragonFile <StageDir>\Lab_Super.dragon with the operator parameters passed
               through. The four NI runtimes are installed by hand per the Phase 0 checklist,
               so the child runs with -SkipNipm unless -WithNipm is given.

    Idempotency / resumability:
      * every phase writes a marker in <StageDir> (.phase1-node.done, .phase2-runner.done,
        .phase3-deps.done) and a re-run skips the phases that are already done; -Force
        redoes them;
      * a registration that already exists (<RunnerRoot>\.runner) is never repeated - that
        matters because a Gitea registration token is single-use;
      * Phase 3 uses <StageDir>\bootstrap-deps.ps1 and <StageDir>\Lab_Super.dragon when they
        are already there (that is the documented manual fallback when the raw fetch fails),
        so re-running with -SkipRunner converges without a token; -Force refetches them;
      * an interrupted phase leaves no marker and is simply redone; a failed registration
        cleans up its own half-products, while a failed autostart removes only the broken
        task and deliberately KEEPS the valid .runner/config (a Gitea registration token is
        single-use, so deleting the state would force a new token).

    Exit codes:
      0  every active phase finished
      2  usage/config error: bad -InstanceUrl/-RepoSlug/-Ref/-KitForge/-KitApiBase/-KitRepoSlug/-KitRef/-Name/-Labels/-Capacity/-RunnerRoot
         (or a path inside a git repository), missing -RunnerBinaryPath, bad timeout value,
         or a required registration token that could not be obtained
      3  Phase 3: the kit file (GitHub contents API) or the dragon file (Gitea raw API)
         could not be fetched (401 = token rejected, 403 = rate-limited or forbidden,
         404 = wrong repo/ref/path or a non-public repository without a token, or a
         network/timeout failure). The manual fallback is printed.
      4  Phase 2: the gitea-runner binary could not be obtained (download failure)
      5  Phase 2: registration or autostart failed (half-products cleaned up)
      6  Phase 1: Node >= 20 is missing and winget could not install it
      7  Phase 3: bootstrap-deps.ps1 ran but did not finish cleanly (non-zero exit/timeout)

.NOTES
    Windows only (the runner and VIPM are Windows components). Requires PowerShell 7+.

    Test seams (empty/absent = the real system behaviour; ci/tests/vm-bootstrap.tests.ps1
    uses them so the suite never touches a real Gitea, dl.gitea.com, VIPM, Node install or
    the Task Scheduler):
      -RunnerBinaryPath  use a local gitea-runner (offline install / stub binary)
      -NodeCommand       executable used for the Node probe (default: `node` from PATH)
      -WingetCommand     executable used for the Node install (default: `winget`)
      -TaskBackend       PowerShell script implementing the scheduled-task verbs
                         install/start/status/uninstall (default: Windows Task Scheduler)
      -DepsScript        run this local bootstrap-deps.ps1 instead of the fetched copy
      -KitApiBase        base URL of the GitHub API for the kit fetch
                         (default: https://api.github.com; tests point it at a loopback stub)

    Runbook: docs/vm-runner.md section 7.0 ("one-shot bootstrap").

.EXAMPLE
    # VM, the documented one-liner (token typed at the prompt, never echoed):
    pwsh -NoProfile -File vm-bootstrap.ps1

.EXAMPLE
    # token supplied out-of-band (keeps it out of the shell history), offline binary:
    $env:GITEA_RUNNER_REGISTRATION_TOKEN = (Read-Host -Prompt 'token' -MaskInput)
    pwsh -NoProfile -File vm-bootstrap.ps1 -RunnerBinaryPath D:\gitea-runner\gitea-runner.exe

.EXAMPLE
    # fetch failed? copy the kit file and the dragon into the stage dir and re-run:
    pwsh -NoProfile -File vm-bootstrap.ps1 -SkipRunner
#>
[CmdletBinding()]
param(
    [string]$InstanceUrl = 'https://gitea.sevenology.top',
    [string]$RepoSlug = 'MICA/MICA',
    [string]$Ref = 'dev',

    # Source of the kit file itself (ci/bootstrap-deps.ps1): the kit's home on GitHub (this
    # repository), fetched through the GitHub contents API at -KitApiBase. -KitForge gitea
    # switches back to the legacy Gitea raw route through -InstanceUrl (for a Gitea mirror
    # of the kit). -RepoSlug/-Ref stay the MICA source of the dragon file; the runner
    # registration target is still -RepoSlug/-Ref.
    [string]$KitForge = 'github',
    [string]$KitApiBase = 'https://api.github.com',
    [string]$KitRepoSlug = 'mica-home/LabVIEW-CI',
    [string]$KitRef = 'main',

    [string]$RunnerRoot = 'D:\gitea-runner',
    [string]$StageDir = 'D:\mica-bootstrap',
    [string]$Name = $env:COMPUTERNAME,
    [string]$Labels = 'windows-labview26:host',
    [int]$Capacity = 1,
    [string]$RegistrationToken = '',
    # Optional GitHub token for the github kit fetch (-KitForge github): -GitHubToken, else
    # the GITHUB_TOKEN environment variable. The kit repository is public, so without it the
    # fetch is anonymous; a token adds an Authorization: Bearer header (higher rate limits,
    # or a private fork) and travels only in that header.
    [string]$GitHubToken = '',
    [string]$RunnerBinaryPath = '',
    [string]$RunnerVersion = 'latest',

    # LabVIEW / VIPM / NI product locations. Same defaults as ci/bootstrap-deps.ps1 so the
    # Phase 0 probes and the Phase 3 child agree; override for a custom install.
    [string]$LabViewPath = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe',
    [int]$LabViewVersion = 2026,
    [string]$VipmPath = 'C:\Program Files\JKI\VI Package Manager\support\vipm.exe',
    [string]$NiRoot = 'C:\Program Files (x86)\National Instruments',

    # Wall-clock caps (seconds). Every value is printed when it is used, and the download
    # and registration caps are what keeps a wedged network call from blocking the VM.
    [int]$WingetTimeoutSec = 900,
    [int]$DownloadTimeoutSec = 300,
    [int]$RegisterTimeoutSec = 120,
    [int]$StartVerifyTimeoutSec = 30,
    [int]$TaskBackendTimeoutSec = 60,
    [int]$DepsTimeoutSec = 7200,

    # Scheduled task: SYSTEM + AtStartup per the design. -TaskUserId is the escape hatch for
    # environments where the LabVIEW build needs the interactive session instead.
    [string]$TaskUserId = 'SYSTEM',

    # Phase skips (each phase keeps its own -Skip* flag) and the re-run controls.
    [switch]$SkipNode,
    [switch]$SkipRunner,
    [switch]$SkipDeps,
    # Phase 3 forwards -SkipNipm to bootstrap-deps.ps1 by default (the four NI runtimes are on
    # the Phase 0 manual checklist); -WithNipm lets VIPM handle the dragon file's nipm entries.
    [switch]$WithNipm,
    # Phase 3 forwards -VerifyOnly (read-only reconciliation, no install).
    [switch]$VerifyOnly,
    [switch]$Force,

    # Test seams (see .NOTES).
    [string]$NodeCommand = '',
    [string]$WingetCommand = '',
    [string]$TaskBackend = '',
    [string]$DepsScript = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# A non-zero exit of a native command is data here (we inspect exit codes), not a throw.
$PSNativeCommandUseErrorActionPreference = $false

$ExitOk = 0
$ExitUsage = 2
$ExitFetch = 3
$ExitRunnerBinary = 4
$ExitRunner = 5
$ExitNode = 6
$ExitDeps = 7

$TaskName = 'MicaGiteaRunner'
$script:LogPrefix = '[bootstrap] '
$script:TmpFiles = [System.Collections.Generic.List[string]]::new()

# --- logging ---------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ($script:LogPrefix + $Message) -ForegroundColor $Color
}
function Write-Err {
    param([string]$Message)
    [Console]::Error.WriteLine($script:LogPrefix + $Message)
}
function Write-Phase {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=== ' + $Title + ' ===') -ForegroundColor Cyan
}
function Write-Hint {
    param([string[]]$Lines)
    Write-Host ''
    Write-Host ($script:LogPrefix + 'next steps:')
    foreach ($l in $Lines) { Write-Host ('  ' + $l) }
}
function Stop-Usage {
    param([string]$Message, [string[]]$Hints = @())
    Write-Err ('usage/configuration error: ' + $Message)
    Write-Host ''
    Write-Host 'usage:'
    Write-Host '  pwsh -File ci/runner/vm-bootstrap.ps1 [-InstanceUrl <url>] [-RepoSlug <owner/repo>] [-Ref <branch|tag>]'
    Write-Host '       [-KitForge github|gitea] [-KitRepoSlug <owner/repo>] [-KitRef <branch|tag>]   (kit source; default github mica-home/LabVIEW-CI@main)'
    Write-Host '       [-GitHubToken <t> | env GITHUB_TOKEN]   (optional: the public kit fetches anonymously; a token adds Bearer for rate limits or a private fork)'
    Write-Host '       [-RunnerRoot <dir>] [-StageDir <dir>] [-Name <runner name>] [-Labels <l>] [-Capacity <n>]'
    Write-Host '       [-RegistrationToken <t> | env GITEA_RUNNER_REGISTRATION_TOKEN | interactive prompt]'
    Write-Host '       [-RunnerBinaryPath <local gitea-runner>] [-SkipNode] [-SkipRunner] [-SkipDeps] [-Force]'
    Write-Host 'full guide: docs/vm-runner.md, section 7.0.'
    foreach ($h in $Hints) { Write-Host ('  - ' + $h) }
    exit $ExitUsage
}
function Protect-Secret {
    param([string]$Text, [string]$Secret)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ([string]::IsNullOrEmpty($Secret) -or $Secret.Length -lt 4) { return $Text }
    return $Text.Replace($Secret, '<redacted>')
}

# --- small helpers ----------------------------------------------------------------

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
    # Structural check (.git entry on the parent chain) - works for paths that do not exist.
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

function Get-StringSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Update-SessionPath {
    # winget installs machine-wide; the running process still has the old PATH snapshot, so
    # a re-probe would miss a freshly installed Node without this refresh.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($machine)) { $parts += $machine }
    if (-not [string]::IsNullOrWhiteSpace($user)) { $parts += $user }
    if ($parts.Count -gt 0) { $env:PATH = ($parts -join ';') }
}

function Get-PwshExe {
    $candidate = ''
    try { $candidate = (Get-Process -Id $PID).Path } catch { $candidate = '' }
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    $fallback = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
    return 'pwsh'
}

# --- child processes (bounded, never leak a secret into the console) ---------------

function Invoke-ChildProcess {
    <#
      Runs $Exe with $Arguments, draining stdout/stderr line by line so a wedged child can
      be killed at $TimeoutSec instead of blocking the run. -Live streams the lines as they
      arrive (long installs); otherwise the text is returned for the caller to print after
      redaction. Returns {Started,ExitCode,TimedOut,Output,BudgetSec}.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkDir = '',
        [int]$TimeoutSec = 120,
        [string]$Label = 'command',
        [string]$Secret = '',
        [switch]$Live
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    foreach ($a in @($Arguments)) { [void]$psi.ArgumentList.Add([string]$a) }
    if (-not [string]::IsNullOrWhiteSpace($WorkDir)) { $psi.WorkingDirectory = $WorkDir }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $collected = [System.Text.StringBuilder]::new()
    $proc = $null
    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch {
        return [pscustomobject]@{ Started = $false; ExitCode = 127; TimedOut = $false; BudgetSec = $TimeoutSec; Output = ('failed to start process ' + $Exe + ': ' + $_.Exception.Message) }
    }
    try { $proc.StandardInput.Close() } catch { }

    $outTask = $null
    $errTask = $null
    try { $outTask = $proc.StandardOutput.ReadLineAsync() } catch { $outTask = $null }
    try { $errTask = $proc.StandardError.ReadLineAsync() } catch { $errTask = $null }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $timedOut = $false
    while ($true) {
        $pending = @()
        if ($null -ne $outTask) { $pending += $outTask }
        if ($null -ne $errTask) { $pending += $errTask }
        if ($pending.Count -eq 0) { break }
        $remainingMs = [Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remainingMs -le 0) { $timedOut = $true; break }
        $slice = [int][Math]::Min($remainingMs, 500)
        $idx = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$pending, $slice)
        if ($idx -lt 0) { continue }
        $task = $pending[$idx]
        $line = $null
        try { $line = $task.Result } catch { $line = $null }
        if ($task -eq $outTask) {
            if ($null -eq $line) { $outTask = $null }
            else {
                [void]$collected.AppendLine($line)
                if ($Live) { Write-Host ('    ' + (Protect-Secret -Text $line -Secret $Secret)) }
                $outTask = $proc.StandardOutput.ReadLineAsync()
            }
        }
        else {
            if ($null -eq $line) { $errTask = $null }
            else {
                [void]$collected.AppendLine($line)
                if ($Live) { Write-Host ('    ' + (Protect-Secret -Text $line -Secret $Secret)) -ForegroundColor DarkGray }
                $errTask = $proc.StandardError.ReadLineAsync()
            }
        }
    }

    if ($timedOut) {
        try { $proc.Kill($true) } catch { }
    }
    try { [void]$proc.WaitForExit(5000) } catch { }
    $exitCode = 127
    if (-not $timedOut) {
        try { $exitCode = $proc.ExitCode } catch { $exitCode = 127 }
    }
    try { $proc.Dispose() } catch { }
    return [pscustomobject]@{
        Started   = $true
        ExitCode  = $exitCode
        TimedOut  = $timedOut
        BudgetSec = $TimeoutSec
        Output    = $collected.ToString()
    }
}

# --- probes ------------------------------------------------------------------------

function Get-IPv4Addresses {
    $result = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($ip in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$ip.IPAddress)) { $result.Add([string]$ip.IPAddress) }
        }
    }
    catch { }
    if ($result.Count -eq 0) {
        try {
            foreach ($a in [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())) {
                if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $result.Add($a.IPAddressToString) }
            }
        }
        catch { }
    }
    return @($result | Select-Object -Unique)
}

function Get-DiskInfo {
    param([string]$Root)
    $info = [ordered]@{ drive = $Root; exists = $false; freeGb = $null; totalGb = $null }
    try {
        $di = [System.IO.DriveInfo]::new($Root)
        $info.exists = $true
        $info.freeGb = [Math]::Round($di.AvailableFreeSpace / 1GB, 2)
        $info.totalGb = [Math]::Round($di.TotalSize / 1GB, 2)
    }
    catch {
        $info.exists = $false
    }
    return [pscustomobject]$info
}

function Get-NodeProbe {
    # Returns {Found,Command,Version,Major,Ok,Detail}. Missing Node is data, not a throw.
    param([string]$NodeCommand)
    $probe = [ordered]@{ found = $false; command = $NodeCommand; version = ''; major = -1; ok = $false; detail = '' }
    $resolved = $null
    try {
        $cmd = Get-Command -Name $NodeCommand -ErrorAction Stop
        $resolved = [string]$cmd.Source
    }
    catch {
        if (Test-Path -LiteralPath $NodeCommand -PathType Leaf) { $resolved = $NodeCommand }
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $probe.detail = 'command not found: ' + $NodeCommand
        return [pscustomobject]$probe
    }
    $probe.found = $true
    $probe.command = $resolved
    $raw = ''
    try { $raw = (@(& $resolved --version 2>&1) | Out-String).Trim() }
    catch {
        $probe.detail = 'execution failed: ' + $_.Exception.Message
        return [pscustomobject]$probe
    }
    $probe.version = $raw
    if ($raw -match 'v?(\d+)\.') {
        $probe.major = [int]$Matches[1]
        if ($probe.major -ge 20) { $probe.ok = $true }
        else { $probe.detail = 'version too old (need >= 20)' }
    }
    else {
        $probe.detail = 'cannot parse version: ' + $raw
    }
    return [pscustomobject]$probe
}

function Get-NiRuntimeProbes {
    # Same four products the MICA Installer build spec packages (docs/vm-runner.md 5.2).
    $products = @(
        [pscustomobject]@{ Name = 'NI-VISA Runtime'; Candidates = @('NI-VISA', 'Shared\NI-VISA') },
        [pscustomobject]@{ Name = 'NI-DAQmx Runtime'; Candidates = @('NI-DAQ', 'NI-DAQmx', 'Shared\NI-DAQmx') },
        [pscustomobject]@{ Name = 'NI-488.2 Runtime'; Candidates = @('NI-488.2', 'Shared\NI-488.2') },
        [pscustomobject]@{ Name = ('NI LabVIEW Runtime ' + $LabViewVersion); Candidates = @(('Shared\LabVIEW Run-Time\' + $LabViewVersion), ('Shared\LabVIEW Runtime\' + $LabViewVersion)) }
    )
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $products) {
        $found = $false
        $lookedFor = [System.Collections.Generic.List[string]]::new()
        foreach ($c in $p.Candidates) {
            $path = Join-Path $NiRoot $c
            $lookedFor.Add($path)
            if (Test-Path -LiteralPath $path) { $found = $true }
        }
        $out.Add([pscustomobject]@{ name = $p.Name; found = $found; lookedFor = @($lookedFor) })
    }
    return @($out)
}

# --- phase markers -----------------------------------------------------------------

function Get-PhaseMarkerPath {
    param([string]$MarkerName)
    return (Join-Path $StageDirFull $MarkerName)
}

function Test-PhaseDone {
    # A marker only counts when -Force was not given.
    param([string]$MarkerName)
    if ($Force) { return $false }
    return (Test-Path -LiteralPath (Get-PhaseMarkerPath -MarkerName $MarkerName) -PathType Leaf)
}

function Write-PhaseMarker {
    param([string]$MarkerName, [string]$Phase, [string]$Detail)
    $payload = [ordered]@{
        phase  = $Phase
        doneAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        detail = $Detail
        script = 'ci/runner/vm-bootstrap.ps1'
    }
    Write-Utf8NoBom -Path (Get-PhaseMarkerPath -MarkerName $MarkerName) -Text (($payload | ConvertTo-Json -Depth 4) + "`n")
    Write-Log ('phase marker written: ' + (Get-PhaseMarkerPath -MarkerName $MarkerName))
}

# --- config.yaml -------------------------------------------------------------------

function Get-ConfigYaml {
    param([string]$LabelsCsv, [int]$Capacity, [string]$WorkDirPath)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Generated by ci/runner/vm-bootstrap.ps1 - re-run the script instead of editing by hand.')
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

# --- scheduled task backend --------------------------------------------------------

function Invoke-TaskBackend {
    <#
      install / start / status / uninstall. With -TaskBackend the verbs go to that script
      (test seam); otherwise they are the real Windows Task Scheduler operations.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Verb,
        [string]$Execute = '',
        [string]$ActionArgs = '',
        [string]$WorkingDirectory = '',
        [string]$LogPath = '',
        [string]$ProcessName = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($TaskBackend)) {
        $argv = @('-NoProfile', '-NonInteractive', '-File', $TaskBackend, '-Verb', $Verb, '-TaskName', $TaskName)
        switch ($Verb) {
            'install' {
                $argv += @('-Execute', $Execute, '-Arguments', $ActionArgs, '-WorkingDirectory', $WorkingDirectory,
                    '-Trigger', 'AtStartup', '-UserId', $TaskUserId, '-LogPath', $LogPath)
                if ($Force) { $argv += '-Force' }
            }
            'status' { $argv += @('-ProcessName', $ProcessName, '-TimeoutSec', "$StartVerifyTimeoutSec") }
        }
        $r = Invoke-ChildProcess -Exe $PwshExe -Arguments $argv -TimeoutSec $TaskBackendTimeoutSec -Label ('task ' + $Verb)
        foreach ($line in @($r.Output -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Host ($script:LogPrefix + '[task:' + $Verb + '] ' + $line) }
        }
        if (-not $r.Started) { return [pscustomobject]@{ Ok = $false; Detail = $r.Output } }
        if ($r.TimedOut) { return [pscustomobject]@{ Ok = $false; Detail = ('scheduled task backend did not return within ' + $r.BudgetSec + ' s (timeout budget -TaskBackendTimeoutSec)') } }
        if ($r.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Detail = ('scheduled task backend exit code ' + $r.ExitCode + ' (verb=' + $Verb + ')') } }
        return [pscustomobject]@{ Ok = $true; Detail = '' }
    }

    switch ($Verb) {
        'install' {
            $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $ActionArgs -WorkingDirectory $WorkingDirectory
            $triggers = @((New-ScheduledTaskTrigger -AtStartup))
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
            if ($TaskUserId -eq 'SYSTEM') {
                $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            }
            else {
                $principal = New-ScheduledTaskPrincipal -UserId $TaskUserId -LogonType Interactive -RunLevel Highest
            }
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal `
                -Description ('MICA Gitea Actions runner daemon - managed by ci/runner/vm-bootstrap.ps1') -Force | Out-Null
            Write-Log ('registered scheduled task: ' + $TaskName + ' (trigger: at boot; principal: ' + $TaskUserId + ')')
        }
        'start' {
            Start-ScheduledTask -TaskName $TaskName
            Write-Log ('started scheduled task: ' + $TaskName)
        }
        'status' {
            # A task can report "Running" while the daemon died on startup, so the probe is
            # the process itself, polled for up to -StartVerifyTimeoutSec.
            $deadline = [DateTime]::UtcNow.AddSeconds($StartVerifyTimeoutSec)
            while ($true) {
                $found = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
                if ($found.Count -gt 0) {
                    return [pscustomobject]@{ Ok = $true; Detail = ('process ' + $ProcessName + ' is running (PID ' + $found[0].Id + ')') }
                }
                if ([DateTime]::UtcNow -ge $deadline) { break }
                Start-Sleep -Milliseconds 500
            }
            return [pscustomobject]@{ Ok = $false; Detail = ('process ' + $ProcessName + ' not found after waiting ' + $StartVerifyTimeoutSec + ' s') }
        }
        'uninstall' {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log ('deleted scheduled task: ' + $TaskName)
        }
    }
    return [pscustomobject]@{ Ok = $true; Detail = '' }
}

# --- banner -----------------------------------------------------------------------

Write-Host '== MICA VM one-shot bootstrap (vm-bootstrap.ps1) =='
Write-Log ('script      : ' + $PSCommandPath)
Write-Log ('platform    : ' + [System.Environment]::OSVersion.VersionString)

if (-not $IsWindows) {
    Stop-Usage 'this bootstraps the windows-amd64 gitea-runner and the Windows VIPM; Windows only.'
}
$PwshExe = Get-PwshExe

# --- validation (nothing is created before this block passes) ----------------------

if ([string]::IsNullOrWhiteSpace($RunnerRoot)) { Stop-Usage '-RunnerRoot must not be empty.' }
try { $RunnerRootFull = Resolve-AbsolutePath -Path $RunnerRoot } catch { Stop-Usage $_.Exception.Message }
if ([string]::IsNullOrWhiteSpace($StageDir)) { Stop-Usage '-StageDir must not be empty.' }
try { $StageDirFull = Resolve-AbsolutePath -Path $StageDir } catch { Stop-Usage $_.Exception.Message }

foreach ($pair in @(@('RunnerRoot', $RunnerRootFull), @('StageDir', $StageDirFull))) {
    $repo = Find-EnclosingGitRepo -Path $pair[1]
    if ($null -ne $repo) {
        Stop-Usage (('-' + $pair[0] + ' is inside a git repository, refusing to run: ' + $pair[1] + ' (repo root: ' + $repo + ').')) @(
            'runner state/staging dirs keep producing files; placing them inside a repo pollutes the working tree.',
            'use a directory outside the repository (recommended: keep the default for ' + $pair[0] + ').'
        )
    }
}

if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    Stop-Usage ('invalid -Name: "' + $Name + '". Allowed: letters, digits, dot, underscore, hyphen; must start with a letter or digit.') @(
        'the default is $env:COMPUTERNAME; if the host name contains characters like underscores, pass an explicit valid name.'
    )
}
if ([string]::IsNullOrWhiteSpace($Labels)) { Stop-Usage '-Labels must not be empty.' }
$labelList = @()
foreach ($item in @($Labels.Split(','))) {
    $label = $item.Trim()
    if ($label.Length -eq 0) { continue }
    if ($label -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*:[A-Za-z0-9][A-Za-z0-9._/@:-]*$') {
        Stop-Usage ('invalid -Labels entry: "' + $label + '". Expected "<name>:<type>", e.g. windows-labview26:host.')
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
if ($RepoSlug -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') {
    Stop-Usage ('invalid -RepoSlug: "' + $RepoSlug + '". Expected owner/repo form, e.g. MICA/MICA.')
}
if ($KitRepoSlug -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') {
    Stop-Usage ('invalid -KitRepoSlug: "' + $KitRepoSlug + '". Expected owner/repo form, e.g. mica-home/LabVIEW-CI.')
}
if ($KitForge -notin @('github', 'gitea')) {
    Stop-Usage ('invalid -KitForge: "' + $KitForge + '". Expected "github" or "gitea".') @(
        'github (default): the kit file comes from the GitHub contents API (-KitApiBase, -KitRepoSlug/-KitRef), fetched anonymously by default; -GitHubToken / env GITHUB_TOKEN is optional (rate limits, or a private fork).',
        'gitea (legacy): the kit file comes from the raw API of -InstanceUrl (for a Gitea mirror of the kit).'
    )
}
$KitApiBaseNormalized = $KitApiBase.TrimEnd('/')
$parsedKitUri = $null
if (-not [Uri]::TryCreate($KitApiBaseNormalized, [UriKind]::Absolute, [ref]$parsedKitUri) -or
    ($parsedKitUri.Scheme -ne 'http' -and $parsedKitUri.Scheme -ne 'https') -or
    [string]::IsNullOrWhiteSpace($parsedKitUri.Host)) {
    Stop-Usage ('invalid -KitApiBase: "' + $KitApiBase + '". An absolute http(s) base URL is required, e.g. https://api.github.com.')
}
if ([string]::IsNullOrWhiteSpace($Ref) -or $Ref -match '[\s?#]') {
    Stop-Usage ('invalid -Ref: "' + $Ref + '". Expected a branch or tag name (no whitespace, ?, #).')
}
if ([string]::IsNullOrWhiteSpace($KitRef) -or $KitRef -match '[\s?#]') {
    Stop-Usage ('invalid -KitRef: "' + $KitRef + '". Expected a branch or tag name (no whitespace, ?, #).')
}
foreach ($t in @(
        [pscustomobject]@{ Name = '-WingetTimeoutSec'; Value = $WingetTimeoutSec },
        [pscustomobject]@{ Name = '-DownloadTimeoutSec'; Value = $DownloadTimeoutSec },
        [pscustomobject]@{ Name = '-RegisterTimeoutSec'; Value = $RegisterTimeoutSec },
        [pscustomobject]@{ Name = '-StartVerifyTimeoutSec'; Value = $StartVerifyTimeoutSec },
        [pscustomobject]@{ Name = '-TaskBackendTimeoutSec'; Value = $TaskBackendTimeoutSec },
        [pscustomobject]@{ Name = '-DepsTimeoutSec'; Value = $DepsTimeoutSec })) {
    if ($t.Value -lt 1) { Stop-Usage ($t.Name + ' must be a positive integer number of seconds, got: ' + $t.Value) }
}

$BinaryFull = ''
if (-not [string]::IsNullOrWhiteSpace($RunnerBinaryPath)) {
    try { $BinaryFull = Resolve-AbsolutePath -Path $RunnerBinaryPath } catch { Stop-Usage $_.Exception.Message }
    if (-not (Test-Path -LiteralPath $BinaryFull -PathType Leaf)) {
        Stop-Usage ('-RunnerBinaryPath points at a missing file: ' + $BinaryFull) @(
            'download gitea-runner (windows-amd64) inside the VM first, then point -RunnerBinaryPath at it;',
            'or drop the parameter to let the script download it (requires access to dl.gitea.com).'
        )
    }
}
if (-not [string]::IsNullOrWhiteSpace($DepsScript)) {
    try { $DepsScriptFull = Resolve-AbsolutePath -Path $DepsScript } catch { Stop-Usage $_.Exception.Message }
    if (-not (Test-Path -LiteralPath $DepsScriptFull -PathType Leaf)) {
        Stop-Usage ('-DepsScript points at a missing file: ' + $DepsScriptFull)
    }
}
else { $DepsScriptFull = '' }

$NodeExe = $NodeCommand
if ([string]::IsNullOrWhiteSpace($NodeExe)) { $NodeExe = 'node' }
$WingetExe = $WingetCommand
if ([string]::IsNullOrWhiteSpace($WingetExe)) { $WingetExe = 'winget' }

$configPath = Join-Path $RunnerRootFull 'config.yaml'
$statePath = Join-Path $RunnerRootFull '.runner'
$backupPath = Join-Path $RunnerRootFull '.runner.bak'
$workDirFull = Join-Path $RunnerRootFull '_work'
$daemonLogPath = Join-Path $RunnerRootFull 'runner-daemon.log'
$depsScriptPath = Join-Path $StageDirFull 'bootstrap-deps.ps1'
$dragonPath = Join-Path $StageDirFull 'Lab_Super.dragon'

# Token is only required when something actually needs it: a registration that will run, or
# a raw fetch that has to happen. A re-run that only retries the autostart needs none.
$runnerWillRegister = (-not $SkipRunner) -and ($Force -or -not (Test-Path -LiteralPath $statePath -PathType Leaf))
$depsFilesPresent = (Test-Path -LiteralPath $depsScriptPath -PathType Leaf) -and (Test-Path -LiteralPath $dragonPath -PathType Leaf)
$depsWillFetch = (-not $SkipDeps) -and ([string]::IsNullOrWhiteSpace($DepsScriptFull)) -and (-not $depsFilesPresent)
$needToken = $runnerWillRegister -or $depsWillFetch

$token = $RegistrationToken
$tokenSource = '-RegistrationToken'
if ([string]::IsNullOrWhiteSpace($token)) {
    $token = [Environment]::GetEnvironmentVariable('GITEA_RUNNER_REGISTRATION_TOKEN', 'Process')
    $tokenSource = 'environment variable GITEA_RUNNER_REGISTRATION_TOKEN'
}
if ($needToken -and [string]::IsNullOrWhiteSpace($token)) {
    if ([Console]::IsInputRedirected) {
        Stop-Usage 'missing registration token, and standard input is not a console (cannot prompt interactively).' @(
            'how to get one: Gitea web UI -> repository (or organization) Settings -> Actions -> Runners -> Create new runner; copy the token (shown only once).',
            'for non-interactive runs use the environment variable (it never enters command-line history):',
            '  $env:GITEA_RUNNER_REGISTRATION_TOKEN = (Read-Host -Prompt ''token'' -MaskInput)',
            '  pwsh -File ci/runner/vm-bootstrap.ps1'
        )
    }
    Write-Host ''
    Write-Log 'a Gitea runner registration token is required (Gitea web UI -> Settings -> Actions -> Runners -> Create new runner).' -Color Yellow
    Write-Log 'note: input is hidden; the token stays in memory only - not written to files, not in the command line, not printed.' -Color Yellow
    $secure = $null
    try { $secure = Read-Host -Prompt 'paste the registration token (hidden)' -AsSecureString }
    catch {
        Stop-Usage ('failed to read the registration token: ' + $_.Exception.Message) @(
            'rerun this script in a real console, or use the environment variable GITEA_RUNNER_REGISTRATION_TOKEN / -RegistrationToken.'
        )
    }
    if ($null -eq $secure -or $secure.Length -eq 0) {
        Stop-Usage 'no registration token entered (empty value).'
    }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $tokenSource = 'interactive Read-Host -AsSecureString'
}
if (-not [string]::IsNullOrWhiteSpace($token)) { $token = $token.Trim() }
if ($needToken -and [string]::IsNullOrWhiteSpace($token)) { Stop-Usage 'registration token is empty.' }

# The github kit fetch is ANONYMOUS by default: the kit repository is public, so the
# contents request carries no Authorization header unless a token is supplied
# (-GitHubToken, else the GITHUB_TOKEN environment variable). A token is optional - it
# raises the rate limit and is needed only for a private fork or a private API host.
$ghToken = $GitHubToken
$ghTokenSource = '-GitHubToken'
if ([string]::IsNullOrWhiteSpace($ghToken)) {
    $ghToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'Process')
    $ghTokenSource = 'environment variable GITHUB_TOKEN'
}
if (-not [string]::IsNullOrWhiteSpace($ghToken)) { $ghToken = $ghToken.Trim() }
$ghTokenProvided = -not [string]::IsNullOrWhiteSpace($ghToken)

# --- plan summary ------------------------------------------------------------------

$skipNodePhase = $SkipNode
$skipRunnerPhase = $SkipRunner
$skipDepsPhase = $SkipDeps

Write-Log ('instance      : ' + $InstanceUrlNormalized + ' (repo ' + $RepoSlug + ', ref ' + $Ref + ')')
Write-Log ('kit source    : ' + $KitForge + ' ' + $KitRepoSlug + ' (ref ' + $KitRef + ')' + $(if ($KitForge -eq 'github') { ' via ' + $KitApiBaseNormalized } else { ' (legacy raw route via -InstanceUrl)' }) + ' for ci/bootstrap-deps.ps1; dragon from ' + $RepoSlug + ' (ref ' + $Ref + ')')
Write-Log ('runner root  : ' + $RunnerRootFull)
Write-Log ('stage dir    : ' + $StageDirFull)
Write-Log ('runner name  : ' + $Name)
Write-Log ('labels        : ' + ($labelList -join ','))
Write-Log ('capacity     : ' + $Capacity)
Write-Log ('scheduled task: ' + $TaskName + ' (at-boot trigger, principal ' + $TaskUserId + ')')
Write-Log ('token        : ' + $(if ($needToken) { 'ready (source: ' + $tokenSource + '; never echoed, never written to disk)' } else { 'not needed this run (nothing to register or download)' }))
Write-Log ('github token : ' + $(if ($KitForge -ne 'github') { 'not used this run (the gitea kit route authenticates with the registration token)' } elseif ($ghTokenProvided) { 'ready (source: ' + $ghTokenSource + '; never echoed, never written to disk)' } else { 'not provided - fetching the kit anonymously (public repository; add -GitHubToken/env GITHUB_TOKEN for rate limits or a private fork)' }))
Write-Log ('timeout budgets (s): winget=' + $WingetTimeoutSec + ' download=' + $DownloadTimeoutSec + ' register=' + $RegisterTimeoutSec + ' start-verify=' + $StartVerifyTimeoutSec + ' deps=' + $DepsTimeoutSec)
Write-Log ('phases       : Phase0 precheck (always)' + $(if ($skipNodePhase) { ' | Phase1 skipped via -SkipNode' } else { ' | Phase1 Node' }) + $(if ($skipRunnerPhase) { ' | Phase2 skipped via -SkipRunner' } else { ' | Phase2 runner' }) + $(if ($skipDepsPhase) { ' | Phase3 skipped via -SkipDeps' } else { ' | Phase3 deps' }))
Write-Log ('force redo   : ' + [bool]$Force)

# --- Phase 0: preflight report -----------------------------------------------------

Write-Phase 'Phase 0/3 environment precheck'

$osCaption = ''
$osBuild = ''
try {
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $osCaption = [string]$cv.ProductName
    $osBuild = [string]$cv.CurrentBuild
}
catch { }

$isAdmin = $false
try {
    $isAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
catch { }

$systemDrive = [System.IO.Path]::GetPathRoot($env:SystemRoot)
$diskSystem = Get-DiskInfo -Root $systemDrive
$diskD = Get-DiskInfo -Root 'D:\'
$ipv4 = Get-IPv4Addresses
$nodeProbe = Get-NodeProbe -NodeCommand $NodeExe
$labviewPresent = Test-Path -LiteralPath $LabViewPath -PathType Leaf
$vipmPresent = Test-Path -LiteralPath $VipmPath -PathType Leaf
$niProbes = Get-NiRuntimeProbes

$manualItems = [System.Collections.Generic.List[object]]::new()
$manualItems.Add([pscustomobject]@{
        item         = 'LabVIEW 2026 Professional (32-bit, including Application Builder)'
        expectedPath = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'
        present      = $labviewPresent
        why          = 'the only compiler for build/package; Application Builder provides the build spec'
    })
foreach ($p in $niProbes) {
    $manualItems.Add([pscustomobject]@{
            item         = $p.name + ' (packaged into the MICA installer)'
            expectedPath = ($p.lookedFor -join ' or ')
            present      = $p.found
            why          = 'docs/vm-runner.md 5.2: one-to-one with the DistPart[*] entries in Lab_Super.lvproj'
        })
}
$manualItems.Add([pscustomobject]@{
        item         = 'VIPM (JKI VI Package Manager, community edition is fine)'
        expectedPath = 'C:\Program Files\JKI\VI Package Manager\support\vipm.exe'
        present      = $vipmPresent
        why          = 'Phase 3 uses it to install the 20 VIPM dependencies'
    })

$preflight = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    script      = 'ci/runner/vm-bootstrap.ps1'
    hostname    = $env:COMPUTERNAME
    ipv4        = @($ipv4)
    os          = [ordered]@{
        caption = $osCaption
        version = [System.Environment]::OSVersion.VersionString
        build   = $osBuild
    }
    isAdmin     = $isAdmin
    disks       = @(
        [ordered]@{ drive = 'system'; root = $systemDrive; exists = $diskSystem.exists; freeGb = $diskSystem.freeGb; totalGb = $diskSystem.totalGb },
        [ordered]@{ drive = 'D:'; root = 'D:\'; exists = $diskD.exists; freeGb = $diskD.freeGb; totalGb = $diskD.totalGb }
    )
    node        = [ordered]@{ command = $nodeProbe.command; found = $nodeProbe.found; version = $nodeProbe.version; major = $nodeProbe.major; ok = $nodeProbe.ok; detail = $nodeProbe.detail }
    labview     = [ordered]@{ path = $LabViewPath; exists = $labviewPresent }
    vipm        = [ordered]@{ path = $VipmPath; exists = $vipmPresent }
    niRuntimes  = @($niProbes)
    manualItems = @($manualItems)
    plan        = [ordered]@{
        instanceUrl   = $InstanceUrlNormalized
        repoSlug      = $RepoSlug
        ref           = $Ref
        kitRepoSlug   = $KitRepoSlug
        kitRef        = $KitRef
        kitForge      = $KitForge
        kitApiBase    = $KitApiBaseNormalized
        runnerRoot    = $RunnerRootFull
        stageDir      = $StageDirFull
        runnerName    = $Name
        labels        = @($labelList)
        capacity      = $Capacity
        taskName      = $TaskName
        taskUserId    = $TaskUserId
        skipNode      = [bool]$SkipNode
        skipRunner    = [bool]$SkipRunner
        skipDeps      = [bool]$SkipDeps
        withNipm      = [bool]$WithNipm
        force         = [bool]$Force
        tokenRequired = $needToken
        tokenSource   = $(if ($needToken) { $tokenSource } else { '(not needed this run)' })
        ghTokenProvided = $ghTokenProvided
        ghTokenSource   = $(if ($ghTokenProvided) { $ghTokenSource } else { '(not provided - anonymous fetch)' })
    }
    timeouts    = [ordered]@{
        wingetSec          = $WingetTimeoutSec
        downloadSec        = $DownloadTimeoutSec
        registerSec        = $RegisterTimeoutSec
        startVerifySec     = $StartVerifyTimeoutSec
        taskBackendSec     = $TaskBackendTimeoutSec
        depsSec            = $DepsTimeoutSec
    }
}

if (-not (Test-Path -LiteralPath $StageDirFull -PathType Container)) {
    New-Item -ItemType Directory -Path $StageDirFull -Force | Out-Null
    Write-Log ('created stage dir: ' + $StageDirFull)
}
$preflightPath = Join-Path $StageDirFull 'preflight.json'
Write-Utf8NoBom -Path $preflightPath -Text (($preflight | ConvertTo-Json -Depth 8) + "`n")

Write-Log ('hostname     : ' + $env:COMPUTERNAME)
Write-Log ('IPv4         : ' + $(if ($ipv4.Count -gt 0) { ($ipv4 -join ', ') } else { '<none detected>' }))
Write-Log ('OS           : ' + $(if ($osCaption) { $osCaption + ' ' } else { '' }) + [System.Environment]::OSVersion.VersionString + $(if ($osBuild) { ' (build ' + $osBuild + ')' } else { '' }))
Write-Log ('admin        : ' + $(if ($isAdmin) { 'yes' } else { 'no (registering the scheduled task and installing Node need admin; reopen the terminal as administrator)' })) -Color $(if ($isAdmin) { 'Gray' } else { 'Yellow' })
Write-Log ('disk free    : ' + $systemDrive + ' ' + $(if ($diskSystem.exists) { $diskSystem.freeGb.ToString() + ' GB free / ' + $diskSystem.totalGb.ToString() + ' GB' } else { '<unreadable>' }) + '   D: ' + $(if ($diskD.exists) { $diskD.freeGb.ToString() + ' GB free / ' + $diskD.totalGb.ToString() + ' GB' } else { '<missing>' }))
Write-Log ('node --version: ' + $(if ($nodeProbe.found) { $nodeProbe.version + ' (command: ' + $nodeProbe.command + ')' } else { '<not found: ' + $nodeProbe.detail + '>' })) -Color $(if ($nodeProbe.ok) { 'Gray' } else { 'Yellow' })
Write-Log ('LabVIEW probe : ' + $LabViewPath + ' -> ' + $(if ($labviewPresent) { 'present' } else { 'missing' })) -Color $(if ($labviewPresent) { 'Gray' } else { 'Yellow' })
Write-Log ('VIPM probe    : ' + $VipmPath + ' -> ' + $(if ($vipmPresent) { 'present' } else { 'missing' })) -Color $(if ($vipmPresent) { 'Gray' } else { 'Yellow' })

Write-Host ''
Write-Log 'manual install checklist (the script will not install these for you; rerun this script after installing):'
foreach ($m in $manualItems) {
    Write-Host ('  [' + $(if ($m.present) { 'present' } else { 'missing' }) + '] ' + $m.item) -ForegroundColor $(if ($m.present) { 'Gray' } else { 'Yellow' })
    Write-Host ('           expected path: ' + $m.expectedPath)
}
Write-Log ('precheck report written to: ' + $preflightPath)

# --- Phase 1: Node -----------------------------------------------------------------

Write-Phase 'Phase 1/3 Node.js >= 20'

if ($skipNodePhase) {
    Write-Log '-SkipNode: skipping Phase 1 per parameters.' -Color Yellow
}
elseif (Test-PhaseDone -MarkerName '.phase1-node.done') {
    Write-Log ('Phase 1 already done (marker ' + (Get-PhaseMarkerPath -MarkerName '.phase1-node.done') + '), skipping; -Force redoes it.')
}
else {
    $probe = Get-NodeProbe -NodeCommand $NodeExe
    if ($probe.ok) {
        Write-Log ('node already satisfies the requirement: ' + $probe.version + ' (' + $probe.command + ')')
        Write-PhaseMarker -MarkerName '.phase1-node.done' -Phase '1-node' -Detail ('node ' + $probe.version + ' via ' + $probe.command)
    }
    else {
        Write-Log ('Node >= 20 not satisfied: ' + $(if ($probe.found) { $probe.version + ' (' + $probe.detail + ')' } else { $probe.detail })) -Color Yellow
        $wingetResolved = $null
        try { $wingetResolved = [string](Get-Command -Name $WingetExe -ErrorAction Stop).Source }
        catch { $wingetResolved = $null }
        $wingetAvailable = -not [string]::IsNullOrWhiteSpace($wingetResolved)
        $installOk = $false
        if ($wingetAvailable) {
            Write-Log ('trying: winget install OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements (timeout budget ' + $WingetTimeoutSec + ' s)')
            $wingetArgs = @('install', 'OpenJS.NodeJS.LTS', '--silent', '--accept-source-agreements', '--accept-package-agreements')
            $r = Invoke-ChildProcess -Exe $wingetResolved -Arguments $wingetArgs -TimeoutSec $WingetTimeoutSec -Label 'winget install'
            foreach ($line in @($r.Output -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Host ($script:LogPrefix + '[winget] ' + $line) }
            }
            if ($r.TimedOut) {
                Write-Err ('winget did not return within ' + $r.BudgetSec + ' s (timeout budget -WingetTimeoutSec); killed.')
            }
            elseif (-not $r.Started) {
                Write-Err ('failed to start winget: ' + $r.Output)
            }
            elseif ($r.ExitCode -ne 0) {
                Write-Err ('winget exit code ' + $r.ExitCode + ' (see the [winget] output above).')
            }
            else {
                Update-SessionPath
                $reprobe = Get-NodeProbe -NodeCommand $NodeExe
                if ($reprobe.ok) {
                    $installOk = $true
                    Write-Log ('Node installed and re-verified: ' + $reprobe.version + ' (' + $reprobe.command + ')')
                    Write-PhaseMarker -MarkerName '.phase1-node.done' -Phase '1-node' -Detail ('node ' + $reprobe.version + ' installed via winget')
                }
                else {
                    Write-Err ('winget reported success, but re-verification still does not satisfy Node >= 20: ' + $(if ($reprobe.found) { $reprobe.version } else { $reprobe.detail }) + ' (installer banners are not accepted as proof of success)')
                }
            }
        }
        else {
            Write-Err ('winget command not found (' + $WingetExe + '); cannot auto-install Node.')
        }

        if (-not $installOk) {
            Write-Host ''
            Write-Err 'Phase 1 failed: Node.js >= 20 is not in place.'
            Write-Hint @(
                'install Node.js LTS manually (choose install for all users so the machine-wide PATH lets the runner resolve node):',
                '  official installer page : https://nodejs.org/en/download/prebuilt-installer',
                '  latest LTS directory   : https://nodejs.org/dist/latest-lts/   (grab the node-vX.Y.Z-x64.msi direct link)',
                'after installing, run node --version in the same terminal to confirm >= 20, then rerun this script (Phase 0/1 re-run the precheck).',
                'offline machines: copy the MSI into the VM and install by double-click, or msiexec /i node-vX.Y.Z-x64.msi /qn.'
            )
            exit $ExitNode
        }
    }
}

# --- Phase 2: runner ---------------------------------------------------------------

Write-Phase 'Phase 2/3 Gitea runner registration and auto-start'

$runnerHalfProducts = [ordered]@{
    RootCreated     = $false
    WorkDirCreated  = $false
    ConfigCreated   = $false
    StateCreated    = $false
    StateBackedUp   = $false
    TaskInstalled   = $false
    DownloadPartial = ''
}

function Clear-RunnerHalfProducts {
    # Full cleanup: only used when no valid registration can survive (registration or
    # config-write failure). Deletes the .runner this run produced, restores a displaced
    # one, deletes a config this run created, removes the task and empty dirs.
    param([string]$Reason)
    Write-Log ('cleaning up partial state (' + $Reason + '):')
    if ($runnerHalfProducts.TaskInstalled) {
        [void](Invoke-TaskBackend -Verb 'uninstall')
        $runnerHalfProducts.TaskInstalled = $false
    }
    if ($runnerHalfProducts.StateCreated -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Remove-Item -LiteralPath $statePath -Force
        Write-Log ('  deleted the .runner created by this registration: ' + $statePath)
    }
    if ($runnerHalfProducts.StateBackedUp -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        Move-Item -LiteralPath $backupPath -Destination $statePath -Force
        $runnerHalfProducts.StateBackedUp = $false
        Write-Log '  restored the pre-registration .runner (-Force backup rollback)'
    }
    if ($runnerHalfProducts.ConfigCreated -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Remove-Item -LiteralPath $configPath -Force
        Write-Log ('  deleted the config.yaml generated this run: ' + $configPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($runnerHalfProducts.DownloadPartial) -and (Test-Path -LiteralPath $runnerHalfProducts.DownloadPartial)) {
        Remove-Item -LiteralPath $runnerHalfProducts.DownloadPartial -Force -ErrorAction SilentlyContinue
        Write-Log ('  deleted the incomplete download file: ' + $runnerHalfProducts.DownloadPartial)
    }
    if ($runnerHalfProducts.WorkDirCreated -and (Test-Path -LiteralPath $workDirFull -PathType Container)) {
        if (@(Get-ChildItem -LiteralPath $workDirFull -Force).Count -eq 0) {
            Remove-Item -LiteralPath $workDirFull -Force
            Write-Log ('  deleted the empty work dir created this run: ' + $workDirFull)
        }
    }
    if ($runnerHalfProducts.RootCreated -and (Test-Path -LiteralPath $RunnerRootFull -PathType Container)) {
        if (@(Get-ChildItem -LiteralPath $RunnerRootFull -Force).Count -eq 0) {
            Remove-Item -LiteralPath $RunnerRootFull -Force
            Write-Log ('  deleted the empty root dir created this run: ' + $RunnerRootFull)
        }
    }
}

function Clear-FailedTask {
    # Autostart failure cleanup: the registration itself is valid and a Gitea registration
    # token is single-use, so .runner/config are deliberately KEPT (deleting them would
    # force the operator to mint a new token); only the broken task is removed.
    param([string]$Reason)
    Write-Log ('cleaning up partial state (' + $Reason + '):')
    if ($runnerHalfProducts.TaskInstalled) {
        [void](Invoke-TaskBackend -Verb 'uninstall')
        $runnerHalfProducts.TaskInstalled = $false
    }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Write-Log ('  kept the valid registration state: ' + $statePath + ' (the token is single-use; deleting it means requesting a new one)')
    }
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Write-Log ('  kept config.yaml: ' + $configPath)
    }
}

if ($skipRunnerPhase) {
    Write-Log '-SkipRunner: skipping Phase 2 per parameters (no registration, no scheduled-task changes).' -Color Yellow
}
elseif (Test-PhaseDone -MarkerName '.phase2-runner.done') {
    Write-Log ('Phase 2 already done (marker ' + (Get-PhaseMarkerPath -MarkerName '.phase2-runner.done') + '), skipping; -Force redoes it.')
}
else {
    # (1) binary
    $runnerHalfProducts.RootCreated = -not (Test-Path -LiteralPath $RunnerRootFull -PathType Container)
    if ($runnerHalfProducts.RootCreated) {
        New-Item -ItemType Directory -Path $RunnerRootFull -Force | Out-Null
        Write-Log ('created runner root: ' + $RunnerRootFull)
    }
    $runnerHalfProducts.WorkDirCreated = -not (Test-Path -LiteralPath $workDirFull -PathType Container)
    if ($runnerHalfProducts.WorkDirCreated) {
        New-Item -ItemType Directory -Path $workDirFull -Force | Out-Null
        Write-Log ('created work dir: ' + $workDirFull)
    }

    if (-not $BinaryFull) {
        $targetExe = Join-Path $RunnerRootFull 'gitea-runner.exe'
        if ((Test-Path -LiteralPath $targetExe -PathType Leaf) -and -not $Force) {
            $BinaryFull = $targetExe
            Write-Log ('reusing existing binary: ' + $targetExe + ' (add -Force to re-download)')
        }
        else {
            $url = 'https://dl.gitea.com/gitea-runner/' + $RunnerVersion + '/gitea-runner-' + $RunnerVersion + '-windows-amd64.exe'
            $runnerHalfProducts.DownloadPartial = $targetExe + '.download'
            Write-Log ('downloading runner binary: ' + $url + ' (timeout budget ' + $DownloadTimeoutSec + ' s)')
            if ($RunnerVersion -eq 'latest') {
                Write-Log '(-RunnerVersion latest relies on an upstream-maintained file path; on a 404, look up the version at https://dl.gitea.com/gitea-runner/ and rerun with -RunnerVersion <x.y.z>, or download manually and pass -RunnerBinaryPath.)'
            }
            try {
                Invoke-WebRequest -Uri $url -OutFile $runnerHalfProducts.DownloadPartial -MaximumRedirection 5 -TimeoutSec $DownloadTimeoutSec
            }
            catch {
                if (Test-Path -LiteralPath $runnerHalfProducts.DownloadPartial) { Remove-Item -LiteralPath $runnerHalfProducts.DownloadPartial -Force -ErrorAction SilentlyContinue }
                Write-Err ('download failed: ' + $url + ' -> ' + $_.Exception.Message)
                Write-Hint @(
                    'confirm the VM has outbound access to dl.gitea.com (NAT is enough).',
                    'download the windows-amd64 gitea-runner manually and rerun with -RunnerBinaryPath <file> (recommended: controlled source).',
                    'behind a proxy, set $env:HTTPS_PROXY before rerunning.'
                )
                exit $ExitRunnerBinary
            }
            Move-Item -LiteralPath $runnerHalfProducts.DownloadPartial -Destination $targetExe -Force
            $runnerHalfProducts.DownloadPartial = ''
            $BinaryFull = $targetExe
            Write-Log ('downloaded: ' + $targetExe)
        }
    }
    if (-not (Test-Path -LiteralPath $BinaryFull -PathType Leaf)) {
        Stop-Usage ('runner binary is not usable: ' + $BinaryFull)
    }
    $binaryHash = (Get-FileHash -LiteralPath $BinaryFull -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Log ('binary sha256 : ' + $binaryHash)

    # (2) config.yaml (never contains the token)
    $configContent = Get-ConfigYaml -LabelsCsv ($labelList -join ',') -Capacity $Capacity -WorkDirPath $workDirFull
    $runnerHalfProducts.ConfigCreated = -not (Test-Path -LiteralPath $configPath -PathType Leaf)
    $configChanged = $true
    if (-not $runnerHalfProducts.ConfigCreated) {
        if ([System.IO.File]::ReadAllText($configPath) -ceq $configContent) { $configChanged = $false }
    }
    if ($configChanged) {
        Write-Utf8NoBom -Path $configPath -Text $configContent
        Write-Log ($(if ($runnerHalfProducts.ConfigCreated) { 'generated' } else { 'updated' }) + ' config.yaml: ' + $configPath)
    }
    else {
        Write-Log ('config.yaml already up to date (not rewritten): ' + $configPath)
    }
    if ([System.IO.File]::ReadAllText($configPath) -cne $configContent) {
        Write-Err ('config.yaml read-back verification failed: ' + $configPath)
        Clear-RunnerHalfProducts -Reason 'config.yaml write failure'
        exit $ExitRunner
    }

    # (3) registration
    $alreadyRegistered = Test-Path -LiteralPath $statePath -PathType Leaf
    if ($alreadyRegistered -and -not $Force) {
        Write-Log ('existing registration state found (' + $statePath + '): skipping registration (idempotent; the token is not consumed twice).')
    }
    else {
        if ($alreadyRegistered) {
            Move-Item -LiteralPath $statePath -Destination $backupPath -Force
            $runnerHalfProducts.StateBackedUp = $true
            Write-Log ('-Force: backed up the existing .runner to ' + $backupPath + ' (automatic rollback on failure)')
        }
        # Anything written from here on belongs to this run and is removed if it fails.
        $runnerHalfProducts.StateCreated = -not $alreadyRegistered
        $registerArgs = @('register', '--no-interactive', '--instance', $InstanceUrlNormalized, '--name', $Name, '--labels', ($labelList -join ','))
        Write-Log ('registering (work dir ' + $RunnerRootFull + '; the token reaches the child process only via the environment variable GITEA_RUNNER_REGISTRATION_TOKEN):')
        Write-Log ('  ' + $BinaryFull + ' ' + ($registerArgs -join ' ') + '   [token never appears on the command line]')
        # The token travels in the child's environment only - never on argv, never in a file.
        $previousEnvToken = [Environment]::GetEnvironmentVariable('GITEA_RUNNER_REGISTRATION_TOKEN', 'Process')
        $registerResult = $null
        try {
            [Environment]::SetEnvironmentVariable('GITEA_RUNNER_REGISTRATION_TOKEN', $token, 'Process')
            $registerResult = Invoke-ChildProcess -Exe $BinaryFull -Arguments $registerArgs -WorkDir $RunnerRootFull `
                -TimeoutSec $RegisterTimeoutSec -Label 'register' -Secret $token
        }
        finally {
            [Environment]::SetEnvironmentVariable('GITEA_RUNNER_REGISTRATION_TOKEN', $previousEnvToken, 'Process')
        }
        foreach ($line in @($registerResult.Output -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Host ($script:LogPrefix + '[register] ' + (Protect-Secret -Text $line -Secret $token))
            }
        }
        if ($registerResult.TimedOut) {
            Write-Err ('registration did not return within ' + $registerResult.BudgetSec + ' s (timeout budget -RegisterTimeoutSec); process tree killed.')
        }
        elseif (-not $registerResult.Started) {
            Write-Err ('failed to start the registration process: ' + $registerResult.Output)
        }
        elseif ($registerResult.ExitCode -ne 0) {
            Write-Err ('registration failed: runner exit code ' + $registerResult.ExitCode + ' (see the [register] output above).')
        }
        $registeredNow = Test-Path -LiteralPath $statePath -PathType Leaf
        if ($registerResult.TimedOut -or -not $registerResult.Started -or $registerResult.ExitCode -ne 0 -or -not $registeredNow) {
            if (-not $registerResult.TimedOut -and $registerResult.Started -and $registerResult.ExitCode -eq 0 -and -not $registeredNow) {
                Write-Err ('the registration command reported success (exit 0) but did not produce ' + $statePath + ': incomplete state, treating as failure.')
            }
            Clear-RunnerHalfProducts -Reason 'registration failed'
            Write-Hint @(
                'confirm the registration token is valid and unexpired (get a fresh one: Gitea web UI -> repo/org Settings -> Actions -> Runners -> Create new runner).',
                ('confirm the VM can reach the instance: ' + $InstanceUrlNormalized + ' (a browser or Test-NetConnection both work).'),
                'after fixing, rerun this script: it is idempotent and can be run repeatedly.'
            )
            exit $ExitRunner
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force
            $runnerHalfProducts.StateBackedUp = $false
            Write-Log 'registration succeeded: deleted the .runner.bak created by -Force'
        }
        Write-Log ('registered: ' + $Name + ' -> ' + $InstanceUrlNormalized)
    }

    # (4) autostart: scheduled task + immediate start + process probe
    $actionLine = '/c ""' + $BinaryFull + '" -c "' + $configPath + '" daemon >> "' + $daemonLogPath + '" 2>&1"'
    # From here on a task may exist even if the verb below fails (a partial registration),
    # so the flag means "uninstall on failure", not "definitely installed".
    $runnerHalfProducts.TaskInstalled = $true
    $installResult = Invoke-TaskBackend -Verb 'install' -Execute 'cmd.exe' -ActionArgs $actionLine -WorkingDirectory $RunnerRootFull -LogPath $daemonLogPath
    if (-not $installResult.Ok) {
        Write-Err ('scheduled task registration failed: ' + $installResult.Detail)
        Clear-FailedTask -Reason 'scheduled task registration failed'
        Write-Hint @(
            'rerun elevated as administrator (scheduled-task registration requires admin).',
            'or start the daemon manually first to validate the config: Set-Location ''' + $RunnerRootFull + '''; & ''' + $BinaryFull + ''' -c ''' + $configPath + ''' daemon'
        )
        exit $ExitRunner
    }

    $startResult = Invoke-TaskBackend -Verb 'start'
    if (-not $startResult.Ok) {
        Write-Err ('scheduled task start failed: ' + $startResult.Detail)
        Clear-FailedTask -Reason 'scheduled task start failed'
        Write-Hint @(
            'rerun as administrator; or reboot the VM (the task triggers at boot).',
            'registration state kept: rerunning this script skips registration and only retries auto-start (no new token needed).'
        )
        exit $ExitRunner
    }

    $statusResult = Invoke-TaskBackend -Verb 'status' -ProcessName ([System.IO.Path]::GetFileNameWithoutExtension($BinaryFull))
    if (-not $statusResult.Ok) {
        Write-Err ('auto-start verification failed: ' + $statusResult.Detail)
        Write-Log ('daemon log (if present): ' + $daemonLogPath) -Color Yellow
        if (Test-Path -LiteralPath $daemonLogPath -PathType Leaf) {
            foreach ($line in @(Get-Content -LiteralPath $daemonLogPath -Tail 20 -ErrorAction SilentlyContinue)) {
                Write-Host ('    ' + (Protect-Secret -Text ([string]$line) -Secret $token))
            }
        }
        Clear-FailedTask -Reason 'auto-start verification failed'
        Write-Hint @(
            'first run it once in the foreground to see the real error: Set-Location ''' + $RunnerRootFull + '''; & ''' + $BinaryFull + ''' -c ''' + $configPath + ''' daemon',
            'common causes: instance unreachable, binary blocked by SmartScreen, insufficient permissions on the work dir.',
            'registration state kept: rerun after fixing (-SkipRunner also works; Phase 3 still runs).'
        )
        exit $ExitRunner
    }
    Write-Log ('auto-start verification passed: ' + $statusResult.Detail)
    Write-Log ('daemon output appended to: ' + $daemonLogPath)
    Write-PhaseMarker -MarkerName '.phase2-runner.done' -Phase '2-runner' -Detail ($Name + ' -> ' + $InstanceUrlNormalized + ' (labels ' + ($labelList -join ',') + ')')
}

# --- Phase 3: dependencies ---------------------------------------------------------

Write-Phase 'Phase 3/3 VIPM dependency bootstrap'

if ($skipDepsPhase) {
    Write-Log '-SkipDeps: skipping Phase 3 per parameters.' -Color Yellow
}
elseif (Test-PhaseDone -MarkerName '.phase3-deps.done') {
    Write-Log ('Phase 3 already done (marker ' + (Get-PhaseMarkerPath -MarkerName '.phase3-deps.done') + '), skipping; -Force redoes it.')
}
else {
    if (-not [string]::IsNullOrWhiteSpace($DepsScriptFull)) {
        $depsScriptPath = $DepsScriptFull
        $dragonPath = Join-Path $StageDirFull 'Lab_Super.dragon'
        Write-Log ('-DepsScript: using local script ' + $depsScriptPath)
        if (-not (Test-Path -LiteralPath $dragonPath -PathType Leaf)) {
            Stop-Usage ('-DepsScript requires ' + $dragonPath + ' to exist alongside it (-DragonFile points at it).') @(
                'copy the repo-root Lab_Super.dragon into ' + $StageDirFull + ' and rerun.'
            )
        }
    }
    elseif ($Force -or -not ((Test-Path -LiteralPath $depsScriptPath -PathType Leaf) -and (Test-Path -LiteralPath $dragonPath -PathType Leaf))) {
        $rawFiles = @(
            [pscustomobject]@{ RepoPath = 'ci/bootstrap-deps.ps1'; Dest = $depsScriptPath; RepoSlug = $KitRepoSlug; Ref = $KitRef; SourceHint = '-KitRepoSlug/-KitRef'; Forge = $KitForge },
            [pscustomobject]@{ RepoPath = 'Lab_Super.dragon'; Dest = $dragonPath; RepoSlug = $RepoSlug; Ref = $Ref; SourceHint = '-RepoSlug/-Ref'; Forge = 'gitea' }
        )
        if ($Force) { Write-Log '-Force: ignoring files already in the stage dir; downloading again.' }
        Write-Log ('fetching files (timeout budget ' + $DownloadTimeoutSec + ' s per file; credentials travel only in Authorization headers - the public kit sends none):')
        foreach ($f in $rawFiles) {
            if ($f.Forge -eq 'github') {
                # GitHub contents API, asked for the raw file itself. The kit repository is
                # public, so no Authorization header is sent unless a token was supplied; the
                # token travels in that header only - never on the command line, never in a file.
                $url = $KitApiBaseNormalized + '/repos/' + $f.RepoSlug + '/contents/' + $f.RepoPath + '?ref=' + [Uri]::EscapeDataString($f.Ref)
                $headers = @{ Accept = 'application/vnd.github.raw' }
                if ($ghTokenProvided) { $headers['Authorization'] = 'Bearer ' + $ghToken }
            }
            else {
                $url = $InstanceUrlNormalized + '/api/v1/repos/' + $f.RepoSlug + '/raw/' + $f.RepoPath + '?ref=' + [Uri]::EscapeDataString($f.Ref)
                $headers = @{ Authorization = 'token ' + $token }
            }
            Write-Log ('  GET [' + $f.Forge + '] ' + $url)
            $status = 0
            try {
                Invoke-WebRequest -Uri $url -Headers $headers -OutFile $f.Dest -TimeoutSec $DownloadTimeoutSec -MaximumRedirection 5
            }
            catch {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
                if (Test-Path -LiteralPath $f.Dest) { Remove-Item -LiteralPath $f.Dest -Force -ErrorAction SilentlyContinue }
                $why = 'network/timeout failure'
                if ($status -eq 401) { $why = 'HTTP 401: token invalid, expired, or not valid for this repo' }
                elseif ($status -eq 403) { $why = 'HTTP 403: access forbidden' }
                elseif ($status -eq 404) { $why = 'HTTP 404: repo/ref/path does not exist (check ' + $f.SourceHint + ' for ' + $f.RepoPath + ')' }
                elseif ($status -gt 0) { $why = 'HTTP ' + $status }
                if ($f.Forge -eq 'github') {
                    if ($status -eq 401) { $why += '; the public kit fetches anonymously - omit -GitHubToken/GITHUB_TOKEN, or supply a valid token' }
                    elseif ($status -eq 403) { $why = 'HTTP 403: rate limit exceeded or access forbidden (retry later, or supply -GitHubToken / env GITHUB_TOKEN)' }
                    elseif ($status -eq 404) { $why += '; or the kit repository is not public and no valid token was given - supply -GitHubToken/GITHUB_TOKEN' }
                }
                Write-Err ('fetch failed: ' + $f.RepoPath + ' -> ' + $why + ' (' + $_.Exception.Message + ')')
                Write-Hint @(
                    'manual fallback (recommended, no new token needed):',
                    '  1) on a machine that can reach both repositories, copy these files into ' + $StageDirFull + '\ (keep the file names):',
                    '       ci/bootstrap-deps.ps1   <- ' + $KitRepoSlug + ' (' + $(if ($KitForge -eq 'github') { 'GitHub' } else { 'Gitea' }) + ', ref ' + $KitRef + ')',
                    '       Lab_Super.dragon        <- ' + $RepoSlug + ' (Gitea, ref ' + $Ref + ')',
                    '  2) rerun: pwsh -File vm-bootstrap.ps1 -SkipRunner   (the registered runner is skipped idempotently; Phase 3 uses the local files directly)',
                    'or: retry with corrected kit/repository/ref parameters (a public kit needs no token; a private fork needs -GitHubToken / env GITHUB_TOKEN).'
                )
                exit $ExitFetch
            }
            Write-Log ('  saved: ' + $f.Dest + ' (' + (Get-Item -LiteralPath $f.Dest).Length + ' bytes)')
        }
    }
    else {
        Write-Log ('using the files already in the stage dir (skipping download; -Force re-downloads): ' + $depsScriptPath + ' / ' + $dragonPath)
    }

    if ($SkipNode) {
        Write-Log 'note: Phase 1 was skipped; bootstrap-deps.ps1 asserts Node >= 20 itself and fails with exit code 2 if not satisfied.' -Color Yellow
    }
    $depsArgs = @('-NoProfile', '-NonInteractive', '-File', $depsScriptPath,
        '-DragonFile', $dragonPath,
        '-VipmPath', $VipmPath,
        '-LabViewPath', $LabViewPath,
        '-LabViewVersion', "$LabViewVersion",
        '-NiRoot', $NiRoot)
    if (-not $WithNipm) {
        $depsArgs += '-SkipNipm'
        Write-Log '(the nipm entries in the dragon file go to the Phase 0 manual checklist; add -WithNipm to let VIPM handle them too)'
    }
    if ($VerifyOnly) { $depsArgs += '-VerifyOnly' }
    Write-Log ('executing: ' + $PwshExe + ' ' + ($depsArgs -join ' ') + ' (timeout budget ' + $DepsTimeoutSec + ' s; the child script has its own vipm invocation watchdog)')
    $depsResult = Invoke-ChildProcess -Exe $PwshExe -Arguments $depsArgs -WorkDir $StageDirFull -TimeoutSec $DepsTimeoutSec -Label 'bootstrap-deps' -Secret $token -Live

    if ($depsResult.TimedOut) {
        Write-Err ('dependency bootstrap did not finish within ' + $depsResult.BudgetSec + ' s (timeout budget -DepsTimeoutSec); process tree killed.')
        Write-Hint @(
            'VIPM installing 20 packages on a cold VM can take a long time: verify network/VIPM login, then rerun with a larger -DepsTimeoutSec.',
            'the install is idempotent and reruns converge; -VerifyOnly does a read-only reconciliation.'
        )
        exit $ExitDeps
    }
    if ($depsResult.ExitCode -ne 0) {
        Write-Err ('dependency bootstrap failed: bootstrap-deps.ps1 exit code ' + $depsResult.ExitCode + ' (0=success 2=precheck 3=install 4=reconciliation mismatch).')
        Write-Hint @(
            'fix the environment per the errors above (VIPM login/network/LabVIEW version), then rerun this script (Phases 1/2 are skipped idempotently).',
            'read-only reconciliation: pwsh -File ' + $depsScriptPath + ' -VerifyOnly -DragonFile ' + $dragonPath,
            'note: do not trust the install-phase "installed successfully" banner - the vipm list reconciliation is the source of truth.'
        )
        exit $ExitDeps
    }
    Write-PhaseMarker -MarkerName '.phase3-deps.done' -Phase '3-deps' -Detail ('bootstrap-deps.ps1 exit 0 (dragon ' + $dragonPath + ')')
}

# --- summary -----------------------------------------------------------------------

Write-Host ''
Write-Host '== Bootstrap complete ==' -ForegroundColor Green
Write-Log ('  runner root  : ' + $RunnerRootFull)
Write-Log ('  stage dir    : ' + $StageDirFull)
Write-Log ('  precheck report: ' + $preflightPath)
Write-Log ('  runner name  : ' + $Name + ' (labels ' + ($labelList -join ',') + ', capacity ' + $Capacity + ')')
Write-Log ('  scheduled task: ' + $TaskName + ' (principal ' + $TaskUserId + ', at-boot trigger)')
Write-Log ('  token        : never echoed, never written to any file (source: ' + $(if ($needToken) { $tokenSource } else { 'not used this run' }) + ')')
Write-Host ''
Write-Log 'next steps:'
Write-Log ('  1) open the Gitea web UI: ' + $InstanceUrlNormalized)
Write-Log ('     repo (or org) Settings -> Actions -> Runners and confirm "' + $Name + '" shows Online (green).')
Write-Log '     while the daemon is down the runner shows offline; jobs matching its labels queue up (they are not lost).'
Write-Log '  2) after installing LabVIEW / NI runtimes / VIPM per the Phase 0 checklist, rerun this script (idempotent), then run the end-to-end build acceptance once.'
Write-Log '  3) take a snapshot (S2: deps complete, runner registered): keep the VMware snapshot on the disk hosting the VM.'
Write-Log '  runbook (snapshots, troubleshooting, decommissioning): docs/vm-runner.md, sections 7.0 and 9.'

exit $ExitOk
