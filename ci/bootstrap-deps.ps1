#Requires -Version 7.0
<#
.SYNOPSIS
    One-shot bootstrap (and proof) of the MICA build VM's VIPM dependencies - Lane 3.

.DESCRIPTION
    This is the executable form of docs/vm-runner.md section 5 ("20 VIPM dependencies"):
    install the VIPM packages declared in Lab_Super.dragon, then ASSERT that every one of
    them really is installed. The assertion is the point of the script - "installed half
    of the dependencies and assumed the rest went fine" must not be able to pass.

    Only two VIPM subcommands are ever run:
      * install  (write) - vipm.exe install -y --labview-version <YYYY> <dragon>
      * list     (read)  - vipm.exe list --installed --labview-version <YYYY>
    The script never removes, downgrades, cleans or upgrades anything, and it never asks
    for "latest" behind the versions pinned in the dragon file. Re-running it on a
    machine that already has the packages is a no-op: `install -y` re-evaluates the same
    pinned set and `list` only reads. Idempotency is asserted by the test suite (T05).

    The argv contract below was read off the real `vipm.exe install --help` and
    `vipm.exe list --help` output on the maintainer machine (2026-09-17), not guessed:
      install  "Installs packages from vipm.toml, .vipc, .dragon files, or by name"
               options used here: -y/--yes (documented for install); the --vipm filter is rejected for dragon inputs on vipm 2026.3.1 - measured 2026-10-02);
               --labview-version <YYYY>, --timeout <SECONDS>, --color-mode <never>
               (documented under "Global Options").
      list     "Lists packages from a configuration file or shows installed packages"
               options used here: --installed plus the same global options.
    `--timeout <SECONDS>` is what keeps a hung CLI from blocking an unattended VM run;
    the wall-clock watchdog in Invoke-Vipm is a second line of defence for the case where
    the flag is ignored or the process wedges before it can honour it.

    Verification matches the declared package IDS against the raw output of `list`. That
    is deliberately format-agnostic: it works for the plain listing and for the
    experimental --json layout without pinning a schema, and the full listing is printed
    when the check fails so a format change is immediately visible to the operator.

.NOTES
    Exit codes:
      0  every declared VIPM package is installed (install skipped with -VerifyOnly)
      2  preflight/config failure: missing VIPM CLI, unreadable or malformed/empty
         [vipm.dependencies] in the dragon file, missing LabVIEW, missing or too-old
         Node, bad parameter value
      3  the install command failed: non-zero VIPM exit, or VIPM did not return within
         its timeout plus the watchdog grace period
      4  verification failed: the installed-package list could not be read, or one or
         more declared ids are missing from it

    Platform: Windows only (VIPM is a Windows application).
    Runbook: docs/vm-runner.md section 5.5. Manual QA (needs a real VM, takes tens of
    minutes because it installs 20 real packages) is recorded in the task results.

.EXAMPLE
    # VM, repository default paths (the documented one-liner):
    pwsh -NoProfile -File ci/bootstrap-deps.ps1

.EXAMPLE
    # VM, read-only re-check of an environment that is already bootstrapped:
    pwsh -NoProfile -File ci/bootstrap-deps.ps1 -VerifyOnly

.EXAMPLE
    # VIPM installed elsewhere, and skip the NIPM half of the dragon file:
    pwsh -NoProfile -File ci/bootstrap-deps.ps1 -VipmPath 'D:\VIPM\support\vipm.exe' -SkipNipm
#>
[CmdletBinding()]
param(
    # Single source of truth for the VIPM dependency list (repository root by default).
    [string]$DragonFile = (Join-Path $PSScriptRoot '..\Lab_Super.dragon'),

    # VIPM CLI. The vendor default install location; override for a custom install.
    [string]$VipmPath = 'C:\Program Files\JKI\VI Package Manager\support\vipm.exe',

    [int]$LabViewVersion = 2026,

    # LabVIEW development environment (used for a preflight existence assertion only).
    [string]$LabViewPath = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe',

    # Tripwire against a truncated/emptied [vipm.dependencies] section: the section must
    # declare exactly this many ids. -1 accepts any non-zero count.
    [int]$ExpectedPackageCount = 20,

    # Root of the NI product tree; the four runtime products are probed underneath it.
    # Soft check: a miss warns (the Installer spec needs those runtimes) but never fails
    # this script - the authoritative check is `nipkg list --installed`.
    [string]$NiRoot = 'C:\Program Files (x86)\National Instruments',

    # Optional; when set, forwarded as --labview-bitness <32|64>. Left empty the bitness
    # is resolved by VIPM from the project/dragon file itself.
    [string]$LabViewBitness = '',

    # Community-edition gate: vipm.exe refuses to run when its working directory is
    # inside a private repository - including read-only calls like list --installed
    # (error: "This feature of VIPM Community Edition can only be used in public
    # <host> repositories"; visibility is verified online via git ls-remote on the
    # remote). Invoke-Vipm relocates the vipm child process to a directory whose
    # origin remote is this PUBLIC repository URL, created on first use under TEMP.
    # The URL names a public repository of this project's Gitea host by the same
    # convention already used by ci/release-local.ps1 and ci/runner/*.
    [string]$VipmSafeRemote = 'https://gitea.sevenology.top/MICA/MICA_instrument.git',

    # Passed to the CLI as --timeout <sec> for the install (20 packages can take tens of
    # minutes on a cold VM) and for the read-only list call.
    [int]$InstallTimeoutSec = 3600,
    [int]$ListTimeoutSec = 120,

    # Extra wall-clock allowance on top of --timeout before the caller kills the CLI
    # process tree (the CLI does not always honour --timeout while wedged).
    [int]$WatchdogGraceSec = 60,

    # Install only the VIPM half of the dragon file (the NIPM half is a manual install; see the -SkipNipm note at the install call).
    # The NIPM half of the dragon file (NI runtimes) is installed manually per
    # docs/vm-runner.md section 5 step 2, so skipping it here is a supported path.
    [switch]$SkipNipm,

    # Skip the install step and only re-run the verification (read-only).
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- exit codes (the contract) --------------------------------------------------

$ExitOk = 0
$ExitPreflight = 2
$ExitInstall = 3
$ExitVerify = 4

# --- output helpers -------------------------------------------------------------

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host ('== ' + $Text + ' ==')
}
function Write-Info {
    param([string]$Text)
    Write-Host ('  ' + $Text)
}
function Write-WarnLine {
    param([string]$Text)
    Write-Host ('  [WARN] ' + $Text)
}
function Stop-Bootstrap {
    param(
        [int]$Code,
        [string]$Message,
        [string[]]$Hint = @()
    )
    Write-Host ''
    Write-Host ('[FAIL] ' + $Message)
    foreach ($line in $Hint) { Write-Host ('       ' + $line) }
    Write-Host ('       exit ' + $Code)
    exit $Code
}
function Write-OutputDump {
    param(
        [string]$Label,
        [string]$Text,
        [int]$MaxLines = 60
    )
    $lines = @()
    if (-not [string]::IsNullOrEmpty($Text)) { $lines = @($Text -split "\r?\n") }
    Write-Host ('  --- ' + $Label + ' (' + $lines.Count + ' lines) ---')
    $shown = 0
    foreach ($line in $lines) {
        if ($shown -ge $MaxLines) {
            Write-Host ('      | ... (' + ($lines.Count - $MaxLines) + ' more lines)')
            break
        }
        Write-Host ('      | ' + $line)
        $shown += 1
    }
}

# --- path helpers ---------------------------------------------------------------

# Absolute form of a path for messages, whether or not it exists.
function Get-FullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    try { return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath }
    catch {
        try { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
        catch { return $Path }
    }
}

function Format-CommandLine {
    param([string]$Exe, [string[]]$Arguments)
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('"' + $Exe + '"')
    foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') { $parts.Add('"' + $argument + '"') } else { $parts.Add($argument) }
    }
    return ($parts -join ' ')
}

# --- dragon file parsing --------------------------------------------------------

# Returns an ordered map id -> version for every entry of [vipm.dependencies].
# Throws (message carries the line number) on anything that is not a plain
# `id = "version"` entry, so a malformed dependency list fails loudly instead of
# silently verifying a shorter list than the project actually needs.
function Read-VipmDependencyIds {
    param([string]$Path)
    $lines = [System.IO.File]::ReadAllLines($Path)
    $section = ''
    $seenSection = $false
    $deps = [ordered]@{}
    $lineNo = 0
    foreach ($line in $lines) {
        $lineNo += 1
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed.StartsWith('[')) {
            if (-not $trimmed.EndsWith(']')) {
                throw ('line ' + $lineNo + ": unterminated section header [" + $trimmed + "]")
            }
            $section = $trimmed.Substring(1, $trimmed.Length - 2).Trim().ToLowerInvariant()
            if ($section -eq 'vipm.dependencies') { $seenSection = $true }
            continue
        }
        if ($section -ne 'vipm.dependencies') { continue }
        $match = [regex]::Match($trimmed, '^(?<key>"[^"]+"|[A-Za-z0-9_.\-]+)\s*=\s*(?<value>.*)$')
        if (-not $match.Success) {
            throw ('line ' + $lineNo + ": malformed entry in [vipm.dependencies]: " + $trimmed)
        }
        $id = $match.Groups['key'].Value.Trim('"')
        $version = $match.Groups['value'].Value.Trim()
        if ($version.StartsWith('"')) {
            $closing = $version.IndexOf('"', 1)
            if ($closing -lt 0) { throw ('line ' + $lineNo + ": unterminated quoted version for '" + $id + "'") }
            $version = $version.Substring(1, $closing - 1)
        }
        elseif ($version.Contains('#')) {
            $version = $version.Split('#')[0].Trim()
        }
        if ([string]::IsNullOrWhiteSpace($version)) {
            throw ('line ' + $lineNo + ": no version for package id '" + $id + "'")
        }
        if ($deps.Contains($id)) {
            throw ('line ' + $lineNo + ": duplicate package id '" + $id + "'")
        }
        $deps[$id] = $version
    }
    if (-not $seenSection) {
        throw ('no [vipm.dependencies] section found - the file must contain a [vipm.dependencies] table with one "id = ""version""" entry per package')
    }
    return $deps
}

# Number of entries in [nipm.dependencies] (used for the -SkipNipm note only).
function Get-NipmDependencyCount {
    param([string]$Path)
    $section = ''
    $count = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed.StartsWith('[')) {
            $section = $trimmed.Trim('[', ']').Trim().ToLowerInvariant()
            continue
        }
        if ($section -eq 'nipm.dependencies' -and $trimmed.Contains('=')) { $count += 1 }
    }
    return $count
}

# --- process execution ----------------------------------------------------------

function ConvertTo-CmdArgument {
    param([string]$Value)
    # cmd.exe's own quoting rules: wrap in double quotes and double any embedded quote.
    if ($Value -match '[\s"]') { return '"' + $Value.Replace('"', '""') + '"' }
    return $Value
}

# Returns a directory whose git origin remote is a PUBLIC repository (see the
# -VipmSafeRemote param note), creating it on first use under TEMP. A stale or partial
# directory (e.g. an interrupted `git init` left a .git without HEAD, measured
# 2026-10-09) is rebuilt instead of trusted. Returns '' when git is unavailable; the
# caller then keeps the current working directory, which reproduces the pre-fix
# behavior (the Community gate will reject private CWDs).
function Ensure-VipmSafeCwd {
    param([string]$Remote)
    $dir = Join-Path $env:TEMP 'vipm-public-cwd'
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $hasHead = Test-Path (Join-Path $dir '.git\HEAD')
            $configPath = Join-Path $dir '.git\config'
            $remoteOk = (Test-Path $configPath) -and [bool](Select-String -LiteralPath $configPath -SimpleMatch ('url = ' + $Remote) -Quiet)
            if ($hasHead -and $remoteOk) { return $dir }
            # The directory is a throwaway gate fixture, never user data: rebuild it.
            if (Test-Path $dir) {
                Write-Info ('rebuilding stale vipm safe-cwd: ' + $dir)
                Remove-Item -Recurse -Force $dir -ErrorAction Stop
            }
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            git -C $dir init 2>$null | Out-Null
            git -C $dir remote add origin $Remote 2>$null | Out-Null
            if (Test-Path (Join-Path $dir '.git\HEAD')) { return $dir }
        }
        catch {
            # retry once, then fall through to the degraded return below
        }
    }
    return ''
}

# Runs the CLI and returns { Started; TimedOut; ExitCode; StdOut; StdErr; BudgetSec }.
# stdout/stderr are captured separately (the verification parses stdout only) and the
# child gets VIPM_NONINTERACTIVE=1 so it never waits on a prompt in an unattended run.
# The child's working directory is relocated to the public-repo directory (Community
# gate, see -VipmSafeRemote); the dragon/paths passed in $Arguments must therefore be
# absolute - $dragonPath already is (Get-FullPath).
function Invoke-Vipm {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [int]$TimeoutSec,
        [int]$WatchdogGraceSec,
        [string]$Label
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $extension = [System.IO.Path]::GetExtension($Exe).ToLowerInvariant()
    if ($extension -eq '.cmd' -or $extension -eq '.bat') {
        # cmd needs the interpreter named explicitly, and the command line has to be one
        # raw string so cmd's quoting rules apply (backslash escapes are not cmd syntax).
        $inner = (@($Exe) + $Arguments | ForEach-Object { ConvertTo-CmdArgument $_ }) -join ' '
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/d /s /c "' + $inner + '"'
    }
    else {
        $psi.FileName = $Exe
        foreach ($argument in $Arguments) { $psi.ArgumentList.Add($argument) }
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    # Community gate: run vipm from a public-repo working directory (see -VipmSafeRemote).
    $safeCwd = if ($script:vipmSafeCwd) { $script:vipmSafeCwd } else { Ensure-VipmSafeCwd -Remote $VipmSafeRemote }
    if ($safeCwd) { $psi.WorkingDirectory = $safeCwd }
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.Environment['VIPM_NONINTERACTIVE'] = '1'
    # Cold-cache batch installs sit silent far longer than the default 60 s
    # liveliness window while vipm Desktop downloads each package (measured on
    # dev 2026-10-01 and in CI 2026-10-06); without this the CLI aborts with
    # "'package_set_install' made no progress for 60.0s". Honor an existing
    # setting; otherwise give downloads 15 minutes of silence each.
    if (-not $psi.Environment['VIPM_DESKTOP_LIVELINESS_TIMEOUT']) {
        $psi.Environment['VIPM_DESKTOP_LIVELINESS_TIMEOUT'] = '900'
    }

    $budgetSec = $TimeoutSec + $WatchdogGraceSec
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        $null = $process.Start()
    }
    catch {
        $process.Dispose()
        return [pscustomobject]@{
            Started = $false; TimedOut = $false; ExitCode = -1; StdOut = ''; BudgetSec = $budgetSec
            StdErr = ('failed to start ' + $Label + ': ' + $_.Exception.Message)
        }
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $exited = $process.WaitForExit($budgetSec * 1000)
    if (-not $exited) {
        # Kill the whole tree: the launcher (cmd) owns the real child.
        try { $null = & taskkill.exe /PID $process.Id /T /F 2>&1 } catch { }
        $null = $process.WaitForExit(10000)
        $drainedOut = ''
        $drainedErr = ''
        if ($stdoutTask.Wait(5000)) { $drainedOut = $stdoutTask.GetAwaiter().GetResult() }
        if ($stderrTask.Wait(5000)) { $drainedErr = $stderrTask.GetAwaiter().GetResult() }
        $process.Dispose()
        return [pscustomobject]@{
            Started = $true; TimedOut = $true; ExitCode = -1; StdOut = $drainedOut; StdErr = $drainedErr
            BudgetSec = $budgetSec
        }
    }

    $process.WaitForExit()   # flush the redirected streams
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{
        Started = $true; TimedOut = $false; ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr
        BudgetSec = $budgetSec
    }
}

# --- parameter sanity -----------------------------------------------------------

$parameterErrors = [System.Collections.Generic.List[string]]::new()
if ($LabViewVersion -lt 2000 -or $LabViewVersion -gt 2100) {
    $parameterErrors.Add('-LabViewVersion must be a 4-digit LabVIEW year (e.g. 2026), got: ' + $LabViewVersion)
}
if (-not [string]::IsNullOrWhiteSpace($LabViewBitness) -and @('32', '64') -notcontains $LabViewBitness) {
    $parameterErrors.Add('-LabViewBitness must be 32 or 64 (or empty), got: ' + $LabViewBitness)
}
if ($InstallTimeoutSec -le 0) { $parameterErrors.Add('-InstallTimeoutSec must be positive, got: ' + $InstallTimeoutSec) }
if ($ListTimeoutSec -le 0) { $parameterErrors.Add('-ListTimeoutSec must be positive, got: ' + $ListTimeoutSec) }
if ($WatchdogGraceSec -lt 0) { $parameterErrors.Add('-WatchdogGraceSec must not be negative, got: ' + $WatchdogGraceSec) }

$dragonPath = Get-FullPath $DragonFile
$vipmPath = Get-FullPath $VipmPath
# Community gate (measured 2026-10-02): the licensing check inspects the git context of
# the INPUT FILE's directory for dragon installs - a dragon inside a private checkout is
# rejected even when the process CWD is a public repository. Pre-place a copy of the
# dragon inside the safe public-repo directory and install from that copy.
$vipmSafeCwd = Ensure-VipmSafeCwd -Remote $VipmSafeRemote
$dragonForInstall = $dragonPath
if ($vipmSafeCwd) {
    Copy-Item -LiteralPath $dragonPath -Destination (Join-Path $vipmSafeCwd 'Lab_Super.dragon') -Force
    $dragonForInstall = Join-Path $vipmSafeCwd 'Lab_Super.dragon'
}
$labViewPath = Get-FullPath $LabViewPath
$niRootPath = Get-FullPath $NiRoot
$mode = 'install + verify'
if ($VerifyOnly) { $mode = 'verify only (-VerifyOnly: no install)' }
$nipmMode = 'included (dragon file as-is)'
if ($SkipNipm) { $nipmMode = 'skipped (-SkipNipm: the NIPM half is the manual docs/vm-runner.md install)' }

Write-Section 'MICA bootstrap-deps (Lane 3 build VM)'
Write-Info ('dragon file    : ' + $dragonPath)
Write-Info ('vipm cli       : ' + $vipmPath)
Write-Info ('labview        : ' + $labViewPath)
Write-Info ('labview version: ' + $LabViewVersion + ' (bitness: ' + $(if ($LabViewBitness) { $LabViewBitness } else { 'resolved by VIPM from the project' }) + ')')
Write-Info ('ni root        : ' + $niRootPath + '  (soft check only)')
Write-Info ('mode           : ' + $mode)
Write-Info ('nipm           : ' + $nipmMode)
Write-Info ('timeouts       : install ' + $InstallTimeoutSec + 's / list ' + $ListTimeoutSec + 's, watchdog grace ' + $WatchdogGraceSec + 's')

if ($parameterErrors.Count -gt 0) {
    Stop-Bootstrap -Code $ExitPreflight -Message 'invalid parameters' -Hint (@($parameterErrors) + @('run "Get-Help ./ci/bootstrap-deps.ps1 -Full" for the parameter contract'))
}

# --- [1/4] preflight assertions -------------------------------------------------

Write-Section '[1/4] preflight'

if (-not (Test-Path -LiteralPath $vipmPath -PathType Leaf)) {
    Stop-Bootstrap -Code $ExitPreflight -Message ('the VIPM CLI was not found: ' + $vipmPath) -Hint @(
        'install VI Package Manager (JKI) on this machine first, then re-run this script.',
        'download: https://www.vipm.io/download/ (or the offline installer) - default CLI path is',
        '          "C:\Program Files\JKI\VI Package Manager\support\vipm.exe".',
        'if VIPM is installed somewhere else, re-run with -VipmPath "<path to vipm.exe>".',
        'after installing, open a NEW shell so the updated PATH/registry is visible.'
    )
}
Write-Info ('vipm cli       : OK')

if (-not (Test-Path -LiteralPath $dragonPath -PathType Leaf)) {
    Stop-Bootstrap -Code $ExitPreflight -Message ('the dragon file was not found: ' + $dragonPath) -Hint @(
        'this script must run from a repository checkout (default: <repo>\Lab_Super.dragon).',
        'pass -DragonFile <path> to point at another .dragon file.'
    )
}
$dependencies = $null
try {
    $dependencies = Read-VipmDependencyIds -Path $dragonPath
}
catch {
    Stop-Bootstrap -Code $ExitPreflight -Message ('cannot read the VIPM dependency list from ' + $dragonPath + ': ' + $_.Exception.Message) -Hint @(
        'the file must contain a [vipm.dependencies] table with one entry per package:',
        '    [vipm.dependencies]',
        '    oglib_appcontrol = "6.0.0.10"',
        'repair the file (or re-clone the repository) and re-run; nothing was installed.'
    )
}
if ($dependencies.Count -eq 0) {
    Stop-Bootstrap -Code $ExitPreflight -Message ('[vipm.dependencies] in ' + $dragonPath + ' is empty - there is nothing to install or verify') -Hint @(
        'this is the single source of truth for the VM dependency list; restore it from git.'
    )
}
if ($ExpectedPackageCount -gt 0 -and $dependencies.Count -ne $ExpectedPackageCount) {
    Stop-Bootstrap -Code $ExitPreflight -Message ('[vipm.dependencies] declares ' + $dependencies.Count + ' package ids, but this script expects ' + $ExpectedPackageCount + ' (tripwire against a truncated dependency list)') -Hint @(
        'if the dependency list legitimately changed, update -ExpectedPackageCount (and',
        'packages/VIPM Package List.txt, docs/vm-runner.md) in the same commit.',
        'pass -ExpectedPackageCount -1 to accept any non-zero count.'
    )
}
Write-Info ('dragon file    : OK - ' + $dependencies.Count + ' vipm package ids declared')

if (-not (Test-Path -LiteralPath $labViewPath -PathType Leaf)) {
    Stop-Bootstrap -Code $ExitPreflight -Message ('LabVIEW was not found: ' + $labViewPath) -Hint @(
        'install LabVIEW ' + $LabViewVersion + ' Professional (32-bit, with Application Builder) first',
        '(docs/vm-runner.md section 5, step 1), or pass -LabViewPath "<path to LabVIEW.exe>".',
        'the build/package scripts refuse to run without it, so bootstrapping dependencies here'
        'would give a false sense of readiness.'
    )
}
Write-Info ('labview        : OK')

$nodeVersion = ''
$nodeMajor = -1
$nodeCommand = Get-Command -Name node -CommandType Application -ErrorAction SilentlyContinue
if ($null -ne $nodeCommand) {
    $nodeOutput = (& node --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) {
        $nodeVersion = $nodeOutput
        $nodeMatch = [regex]::Match($nodeOutput, '^v(?<major>[0-9]+)\.')
        if ($nodeMatch.Success) { $nodeMajor = [int]$nodeMatch.Groups['major'].Value }
    }
}
if ($nodeMajor -lt 20) {
    Stop-Bootstrap -Code $ExitPreflight -Message ('Node.js 20 or newer is required, but ' + $(if ($nodeVersion) { 'the found version is ' + $nodeVersion } else { 'node was not found on PATH' })) -Hint @(
        'install Node 20 LTS or newer (https://nodejs.org/en/download) with the',
        '"for all users" option so the runner service resolves "node" from PATH.',
        'verify with: node --version   (expected v20.x or newer)',
        'the runner executes ci/version.mjs in the release workflow, which is why the VM needs it.'
    )
}
Write-Info ('node           : OK - ' + $nodeVersion)

# Soft check: the four NI runtimes the MICA Installer build spec packages. A missing one
# never fails this script - it is a warning with the authoritative follow-up command.
$niProducts = @(
    [pscustomobject]@{ Name = 'NI-VISA Runtime'; Candidates = @('NI-VISA', 'Shared\NI-VISA') },
    [pscustomobject]@{ Name = 'NI-DAQmx Runtime'; Candidates = @('NI-DAQ', 'NI-DAQmx', 'Shared\NI-DAQmx') },
    [pscustomobject]@{ Name = 'NI-488.2 Runtime'; Candidates = @('NI-488.2', 'Shared\NI-488.2') },
    [pscustomobject]@{ Name = ('LabVIEW ' + $LabViewVersion + ' Run-Time'); Candidates = @(('Shared\LabVIEW Run-Time\' + $LabViewVersion), ('Shared\LabVIEW Runtime\' + $LabViewVersion)) }
)
$niMissing = [System.Collections.Generic.List[string]]::new()
foreach ($product in $niProducts) {
    $found = ''
    foreach ($candidate in $product.Candidates) {
        $probe = Join-Path $niRootPath $candidate
        if (Test-Path -LiteralPath $probe) { $found = $probe; break }
    }
    if ($found) {
        Write-Info ('ni runtime     : OK - ' + $product.Name)
    }
    else {
        Write-WarnLine ('ni runtime     : MISSING - ' + $product.Name + ' (looked for: ' + ($product.Candidates -join ', ') + ' under ' + $niRootPath + ')')
        $niMissing.Add($product.Name + ' (looked for: ' + ($product.Candidates -join ', ') + ')')
    }
}
if ($niMissing.Count -gt 0) {
    Write-WarnLine ('NI runtime check: ' + $niMissing.Count + ' of ' + $niProducts.Count + ' products not found - the "MICA Installer" build spec packages them,')
    Write-WarnLine ('so packaging will fail until they are installed (docs/vm-runner.md section 5 step 2).')
    Write-WarnLine ('authoritative check: & "C:\Program Files\National Instruments\NI Package Manager\nipkg.exe" list --installed')
    Write-WarnLine ('                     | Select-String -Pattern "ni-visa|labview-runtime|ni-daqmx|ni-488"')
    Write-WarnLine ('this is a SOFT check on purpose: it warns and continues (the VIPM bootstrap is still valid).')
}
else {
    Write-Info ('ni runtimes    : OK - all ' + $niProducts.Count + ' probed products present')
}

# --- [2/4] install --------------------------------------------------------------

$installArguments = [System.Collections.Generic.List[string]]::new()
$installArguments.Add('install')
$installArguments.Add('-y')
$installArguments.Add('--labview-version')
$installArguments.Add("$LabViewVersion")
if (-not [string]::IsNullOrWhiteSpace($LabViewBitness)) {
    $installArguments.Add('--labview-bitness')
    $installArguments.Add($LabViewBitness)
}
# Note: --vipm is NOT forwarded - vipm 2026.3.1 rejects it for dragon inputs
# ("filter flags are only meaningful when the input can contain packages from both
# managers" - measured 2026-10-02); a dragon file is VIPM-only anyway, and -SkipNipm
# stays documentation-only for the manual NIPM half.
$installArguments.Add('--timeout')
$installArguments.Add("$InstallTimeoutSec")
$installArguments.Add('--color-mode')
$installArguments.Add('never')
$installArguments.Add($dragonForInstall)
$installArgv = @($installArguments)
$installResult = $null

Write-Section '[2/4] install'
if ($VerifyOnly) {
    Write-Info 'skipped: -VerifyOnly was given; only the installed-package listing is read.'
    if (-not $SkipNipm) {
        $nipmCount = Get-NipmDependencyCount -Path $dragonPath
        if ($nipmCount -gt 0) {
            Write-Info ('note: ' + $nipmCount + ' nipm entr' + $(if ($nipmCount -eq 1) { 'y' } else { 'ies' }) + ' in the dragon file are NOT checked by the verification (only the vipm ids are).')
        }
    }
}
else {
    if ($SkipNipm) {
        $nipmCount = Get-NipmDependencyCount -Path $dragonPath
        Write-Info ('-SkipNipm: the NIPM half of the dragon file (' + $nipmCount + ' entries) is left to the manual NI runtime installation of docs/vm-runner.md section 5 step 2 (vipm 2026.3.1 rejects --vipm for dragon inputs - measured).')
    }
    Write-Info ('running: ' + (Format-CommandLine -Exe $vipmPath -Arguments $installArgv))
    $installResult = Invoke-Vipm -Exe $vipmPath -Arguments $installArgv -TimeoutSec $InstallTimeoutSec -WatchdogGraceSec $WatchdogGraceSec -Label 'vipm install'
    if (-not $installResult.Started) {
        Stop-Bootstrap -Code $ExitInstall -Message ('the VIPM CLI could not be started: ' + $vipmPath) -Hint @(
            'the file exists but could not be executed: ' + $installResult.StdErr,
            'check that the path is a real executable (not a shortcut) and that it is not blocked,',
            'then re-run; nothing was installed.'
        )
    }
    if ($installResult.TimedOut) {
        Stop-Bootstrap -Code $ExitInstall -Message ('vipm install did not return within ' + $installResult.BudgetSec + 's (' + $InstallTimeoutSec + 's --timeout + ' + $WatchdogGraceSec + 's watchdog) - the process tree was killed') -Hint @(
            'the VM may be offline/behind a proxy, or VIPM may be waiting on a login/feed:',
            'open VIPM once by hand, sign in, confirm it can reach vipm.io, then re-run this script.',
            'a slow first install of 20 packages on a cold VM can exceed the default budget:',
            're-run with a larger -InstallTimeoutSec (e.g. -InstallTimeoutSec 7200).',
            'installing is idempotent, so re-running after a partial install converges.'
        )
    }
    if ($installResult.ExitCode -ne 0) {
        Write-OutputDump -Label 'vipm install stdout' -Text $installResult.StdOut
        Write-OutputDump -Label 'vipm install stderr' -Text $installResult.StdErr
        Stop-Bootstrap -Code $ExitInstall -Message ('vipm install exited ' + $installResult.ExitCode + ' (see the output above)') -Hint @(
            'common causes: no VIPM login/licence, an unreachable package feed (network/proxy),',
            'or a missing LabVIEW version. Fix the cause and re-run - installing is idempotent.',
            'if VIPM is not installed at all, install it first and re-run this script.'
        )
    }
    Write-Info 'install: OK (exit 0)'
}

# --- [3/4] verify ---------------------------------------------------------------

$listArguments = @('list', '--installed', '--labview-version', "$LabViewVersion")
# bitness applies to the read-only listing too: without it vipm resolves a bare year to
# 64-bit and fails on 32-bit-only machines ("2026 (64-bit) not found" - measured 2026-10-04).
if (-not [string]::IsNullOrWhiteSpace($LabViewBitness)) {
    $listArguments += @('--labview-bitness', $LabViewBitness)
}
$listArguments += @('--timeout', "$ListTimeoutSec", '--color-mode', 'never')

Write-Section '[3/4] verify'
Write-Info ('running: ' + (Format-CommandLine -Exe $vipmPath -Arguments $listArguments))
$listResult = Invoke-Vipm -Exe $vipmPath -Arguments $listArguments -TimeoutSec $ListTimeoutSec -WatchdogGraceSec $WatchdogGraceSec -Label 'vipm list'
if (-not $listResult.Started) {
    Stop-Bootstrap -Code $ExitVerify -Message ('the VIPM CLI could not be started for the verification: ' + $vipmPath) -Hint @(
        'the file exists but could not be executed: ' + $listResult.StdErr,
        'nothing was verified - this is a failure, not a pass.'
    )
}
if ($listResult.TimedOut) {
    Stop-Bootstrap -Code $ExitVerify -Message ('vipm list did not return within ' + $listResult.BudgetSec + 's - the process tree was killed') -Hint @(
        'the installed-package list could not be read, so the verification did NOT pass.',
        'try again; if it keeps hanging, run "vipm list --installed" by hand to see what it waits on.'
    )
}
if ($listResult.ExitCode -ne 0) {
    Write-OutputDump -Label 'vipm list stdout' -Text $listResult.StdOut
    Write-OutputDump -Label 'vipm list stderr' -Text $listResult.StdErr
    Stop-Bootstrap -Code $ExitVerify -Message ('vipm list exited ' + $listResult.ExitCode + ' - the installed packages could not be listed, so the verification did NOT pass') -Hint @(
        'fix the list error above (e.g. LabVIEW ' + $LabViewVersion + ' missing) and re-run.',
        'a failed verification is a red result: do not treat the VM as ready.'
    )
}
$installedListing = $listResult.StdOut

$missing = [System.Collections.Generic.List[string]]::new()
$foundIds = [System.Collections.Generic.List[string]]::new()
foreach ($id in $dependencies.Keys) {
    # Token match: the id must appear as a whole token, so "oglib_appcontrol" cannot be
    # satisfied by "oglib_appcontrol_extra". Works for the plain listing and for a JSON
    # layout (the id appears as a quoted string in both).
    $pattern = '(?<![A-Za-z0-9_.\-])' + [regex]::Escape($id) + '(?![A-Za-z0-9_.\-])'
    if ([regex]::IsMatch($installedListing, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $foundIds.Add($id)
    }
    else {
        $missing.Add($id)
    }
}

if ($missing.Count -gt 0) {
    if ($null -ne $installResult -and -not [string]::IsNullOrWhiteSpace($installResult.StdOut)) {
        # Show what the install step claimed next to what the machine actually has: the
        # "installed 20 packages" banner is exactly the misleading-success case this
        # verification exists for.
        Write-OutputDump -Label 'vipm install stdout from this run' -Text $installResult.StdOut -MaxLines 20
    }
    Write-OutputDump -Label ('vipm list --installed output for LabVIEW ' + $LabViewVersion) -Text $installedListing
    Write-Host ''
    Write-Host ('[FAIL] ' + $missing.Count + ' of ' + $dependencies.Count + ' declared VIPM package ids are missing from the installed-package list:')
    foreach ($id in $missing) {
        Write-Host ('         - ' + $id + '  (declared version ' + $dependencies[$id] + ')')
    }
    Write-Host '       the environment is NOT ready: the build would fail on these missing dependencies.'
    Write-Host '       next steps:'
    Write-Host ('         1) re-run the install: pwsh -NoProfile -File ci/bootstrap-deps.ps1')
    Write-Host ('         2) if package ids above are not what VIPM printed, compare the dump above with')
    Write-Host ('            "' + $dragonPath + '"')
    Write-Host '            - a listing that uses display names instead of ids is a tooling change, not a pass.'
    Write-Host ('         3) install the missing ids by hand: vipm.exe install --labview-version ' + $LabViewVersion + ' <id>')
    Write-Host ('       exit ' + $ExitVerify)
    exit $ExitVerify
}

# --- [4/4] result ---------------------------------------------------------------

Write-Section '[4/4] result'
Write-Info ('OK: all ' + $dependencies.Count + ' VIPM package ids declared in ' + $dragonPath)
Write-Info ('    are installed for LabVIEW ' + $LabViewVersion + ' (verified against "vipm list --installed").')
if (-not $VerifyOnly) { Write-Info 'install was idempotent: only `install` (with the pinned versions) and the read-only `list` were run.' }
Write-Info 'next steps on this VM:'
Write-Info "  compile check   : pwsh -NoProfile -File ci/labview.ps1 -BuildSpec 'Launcher-Debug'"
Write-Info '  register runner : pwsh -NoProfile -File ci/runner/setup-runner.ps1 -ServiceTask'
Write-Info '  runbook         : docs/vm-runner.md section 5.5'
exit $ExitOk
