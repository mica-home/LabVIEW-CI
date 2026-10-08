#Requires -Version 7.0
<#
.SYNOPSIS
    Real executable stand-in for gitea-runner(.exe), used by ci/tests/setup-runner.tests.ps1.

.DESCRIPTION
    Contract (driven entirely by environment variables, set by the test harness):

      STUB_ARGV_LOG          required. One line per invocation is appended:
                             <iso-ts> cwd=<dir> exit=<planned> token-sha256=<hex> token-env-sha256=<hex> argv: <args>
                             The value after --token is replaced with <redacted> before it is
                             written, so no file ever contains the raw token; the SHA-256 of
                             the raw value is recorded instead, which still proves exactly
                             which token was passed on the command line.
                             token-env-sha256 is the SHA-256 of $env:GITEA_RUNNER_REGISTRATION_TOKEN
                             as inherited by this process ('-' when unset). That is the
                             environment-variable registration route used by
                             ci/runner/vm-bootstrap.ps1 (token never on argv) - the fingerprint
                             proves which token reached the child without ever writing it.
      STUB_EXIT_CODE         exit code to use (default 0).
      STUB_CREATE_RUNNER     '0' = do not create .runner even on success (adversarial case:
                             the real runner would have written it). Default: create it.
      STUB_ECHO_TOKEN        '1' = print the raw token value to stderr (adversarial case:
                             a child process leaking the credential). The setup script must
                             redact it before echoing.
      STUB_ECHO_ENV_TOKEN    '1' = print the raw value of GITEA_RUNNER_REGISTRATION_TOKEN to
                             stderr (same adversarial case for the environment-variable route).

    Behaviour mirrors the real runner where it matters to the setup script:
      * `register` writes .runner into the CURRENT DIRECTORY on success (exit 0);
      * a non-zero planned exit simulates a rejected registration (no .runner written).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logPath = $env:STUB_ARGV_LOG
if ([string]::IsNullOrWhiteSpace($logPath)) {
    [Console]::Error.WriteLine('runner-stub: STUB_ARGV_LOG is not set; refusing to run without an evidence channel')
    exit 91
}

$plannedExit = 0
if (-not [string]::IsNullOrWhiteSpace($env:STUB_EXIT_CODE)) {
    $parsed = 0
    if ([int]::TryParse($env:STUB_EXIT_CODE, [ref]$parsed)) { $plannedExit = $parsed }
}

$raw = @($args)
$redacted = [System.Collections.Generic.List[string]]::new()
$tokenValue = ''
$i = 0
while ($i -lt $raw.Count) {
    $arg = [string]$raw[$i]
    if ($arg -eq '--token' -and ($i + 1) -lt $raw.Count) {
        $tokenValue = [string]$raw[$i + 1]
        $redacted.Add($arg)
        $redacted.Add('<redacted>')
        $i += 2
        continue
    }
    $redacted.Add($arg)
    $i += 1
}

$tokenSha = '-'
if ($tokenValue.Length -gt 0) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $tokenSha = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($tokenValue))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

# Environment-variable registration route (ci/runner/vm-bootstrap.ps1): the token must never
# be on argv, so the fingerprint of the inherited variable is the only acceptable evidence.
$envToken = [string]$env:GITEA_RUNNER_REGISTRATION_TOKEN
$envTokenSha = '-'
if (-not [string]::IsNullOrWhiteSpace($envToken)) {
    $sha2 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $envTokenSha = [System.BitConverter]::ToString($sha2.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($envToken))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha2.Dispose() }
}

$cwd = (Get-Location).Path
$logLine = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') +
    ' cwd=' + $cwd +
    ' exit=' + $plannedExit +
    ' token-sha256=' + $tokenSha +
    ' token-env-sha256=' + $envTokenSha +
    ' argv: ' + ($redacted -join ' ')

$logDir = Split-Path -Parent $logPath
if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
Add-Content -LiteralPath $logPath -Value $logLine -Encoding utf8NoBOM

$subcommand = ''
if ($raw.Count -gt 0) { $subcommand = [string]$raw[0] }
if ([string]::IsNullOrWhiteSpace($subcommand)) {
    [Console]::Error.WriteLine('runner-stub: no argv received')
    exit 92
}

if ($env:STUB_ECHO_TOKEN -eq '1') {
    [Console]::Error.WriteLine('runner-stub: (simulated real-runner output) registration rejected, token=' + $tokenValue)
}
if ($env:STUB_ECHO_ENV_TOKEN -eq '1') {
    [Console]::Error.WriteLine('runner-stub: (simulated real-runner output) registration rejected, env token=' + $envToken)
}

if ($subcommand -eq 'register' -and $plannedExit -eq 0 -and $env:STUB_CREATE_RUNNER -ne '0') {
    $stateFile = Join-Path $cwd '.runner'
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText(
        $stateFile,
        '{"id":0,"uuid":"00000000-0000-0000-0000-000000000000","name":"runner-stub","token":"stub-local-state-not-a-secret"}',
        $utf8NoBom)
}

if ($plannedExit -ne 0) {
    [Console]::Error.WriteLine('runner-stub: simulated failure, exit=' + $plannedExit)
}

exit $plannedExit
