#Requires -Version 7.0
<#
.SYNOPSIS
    Real executable stand-in for vipm.exe, used by ci/tests/bootstrap-deps.tests.ps1.

.DESCRIPTION
    Contract (driven entirely by environment variables, set by the test harness):

      STUB_ARGV_LOG              required. One line per invocation is appended:
                                 <iso-ts> cwd=<dir> exit=<planned> sleep=<sec> argv: <args>
                                 The argv is recorded verbatim, which is how the tests
                                 assert the exact command shape bootstrap-deps.ps1 builds.
      STUB_LIST_FILE             `list` replays this file line by line to stdout. The
                                 fixture is shaped like the real `vipm list --installed`
                                 output (one package id per line, version next to it).
                                 A missing file means empty output, i.e. "nothing
                                 installed" - the hardest case for the verification.
      STUB_INSTALL_OUTPUT_FILE   optional; `install` replays this file line by line to
                                 stdout instead of its built-in banner. Used to simulate a
                                 MISLEADING success banner (e.g. "installed 18 packages")
                                 while the `list` output shows fewer packages.
      STUB_EXIT_CODE             exit code for every subcommand (default 0).
      STUB_SLEEP_SEC             sleep this many seconds before exiting; models a hung
                                 vipm.exe that has to be killed by the caller's watchdog.
      STUB_SLEEP_SUBCOMMAND      optional; when set, only that subcommand sleeps
                                 (install | list). Empty = every invocation sleeps.

    The stub never touches the real VI Package Manager, the network, any VIPM state or
    any file outside STUB_ARGV_LOG: it writes the log, replays fixtures and exits with
    the planned code. Both write and read subcommands are recognised (`install`,
    `list`); anything else is reported on stderr so a wrong subcommand cannot pass
    silently.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logPath = $env:STUB_ARGV_LOG
if ([string]::IsNullOrWhiteSpace($logPath)) {
    [Console]::Error.WriteLine('vipm-stub: STUB_ARGV_LOG is not set; refusing to run without an evidence channel')
    exit 91
}

$plannedExit = 0
if (-not [string]::IsNullOrWhiteSpace($env:STUB_EXIT_CODE)) {
    $parsedExit = 0
    if ([int]::TryParse($env:STUB_EXIT_CODE, [ref]$parsedExit)) { $plannedExit = $parsedExit }
}
$sleepSec = 0
if (-not [string]::IsNullOrWhiteSpace($env:STUB_SLEEP_SEC)) {
    $parsedSleep = 0
    if ([int]::TryParse($env:STUB_SLEEP_SEC, [ref]$parsedSleep)) { $sleepSec = $parsedSleep }
}

$raw = @($args)
$cwd = (Get-Location).Path
$logLine = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') +
    ' cwd=' + $cwd +
    ' exit=' + $plannedExit +
    ' sleep=' + $sleepSec +
    ' argv: ' + ($raw -join ' ')

$logDir = Split-Path -Parent $logPath
if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
Add-Content -LiteralPath $logPath -Value $logLine -Encoding utf8NoBOM

$subcommand = ''
if ($raw.Count -gt 0) { $subcommand = ([string]$raw[0]).ToLowerInvariant() }
if ([string]::IsNullOrWhiteSpace($subcommand)) {
    [Console]::Error.WriteLine('vipm-stub: no argv received')
    exit 92
}

if ($subcommand -eq 'list') {
    if (-not [string]::IsNullOrWhiteSpace($env:STUB_LIST_FILE) -and (Test-Path -LiteralPath $env:STUB_LIST_FILE -PathType Leaf)) {
        foreach ($line in [System.IO.File]::ReadAllLines($env:STUB_LIST_FILE)) { Write-Output $line }
    }
    else {
        [Console]::Error.WriteLine('vipm-stub: no STUB_LIST_FILE; replaying an empty installed-package list')
    }
}
elseif ($subcommand -eq 'install') {
    if (-not [string]::IsNullOrWhiteSpace($env:STUB_INSTALL_OUTPUT_FILE) -and (Test-Path -LiteralPath $env:STUB_INSTALL_OUTPUT_FILE -PathType Leaf)) {
        foreach ($line in [System.IO.File]::ReadAllLines($env:STUB_INSTALL_OUTPUT_FILE)) { Write-Output $line }
    }
    else {
        Write-Output ('vipm-stub: install completed: ' + ($raw -join ' '))
    }
}
else {
    [Console]::Error.WriteLine('vipm-stub: unexpected subcommand [' + $subcommand + '] - this stub only implements install and list')
}

if ($sleepSec -gt 0) {
    $sleepScope = [string]$env:STUB_SLEEP_SUBCOMMAND
    if ([string]::IsNullOrWhiteSpace($sleepScope) -or $sleepScope.ToLowerInvariant() -eq $subcommand) {
        Start-Sleep -Seconds $sleepSec
    }
}

if ($plannedExit -ne 0) {
    [Console]::Error.WriteLine('vipm-stub: simulated failure, exit=' + $plannedExit)
}
exit $plannedExit
