# host-vm-autostart.ps1 - starts the encrypted build VM when the host boots.
# Registered as a SYSTEM scheduled task (MicaVmAutostart, AtStartup).
# Reads the encryption password from ci/vm.env (local, untracked); the password
# is never echoed or written anywhere else.

$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:ProgramData 'MicaVmAutostart'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'autostart.log'
function L($msg) { ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg) | Add-Content -LiteralPath $log }

try {
    $envFile = Join-Path $PSScriptRoot '..\vm.env'
    $m = @{}
    foreach ($l in (Get-Content -LiteralPath $envFile)) {
        if ($l -match '^\s*#' -or $l -notmatch '=') { continue }
        $k, $v = $l -split '=', 2
        $m[$k.Trim()] = $v.Trim()
    }
    $vmrun = $m['VMRUN_PATH']
    $vmx   = $m['VMX_PATH']
    $pwd_  = $m['VMX_ENCRYPTION_PASSWORD']
    if (-not $vmrun -or -not $vmx -or -not $pwd_) {
        L 'missing VMRUN_PATH / VMX_PATH / VMX_ENCRYPTION_PASSWORD in ci\vm.env'
        exit 2
    }
    if (-not (Test-Path -LiteralPath $vmrun)) { L "vmrun not found: $vmrun"; exit 2 }

    # Already running?
    $state = & $vmrun '-vp' $pwd_ 'list' 2>&1
    L ('vmrun list: ' + ($state -join ' | '))
    if (($state -join "`n") -match [regex]::Escape($vmx)) {
        L 'VM already running - nothing to do'
        exit 0
    }
    L 'starting VM (nogui)...'
    $r = & $vmrun '-vp' $pwd_ 'start' $vmx 'nogui' 2>&1
    L ('start exit=' + $LASTEXITCODE + ' output: ' + ($r -join ' | '))
    exit $LASTEXITCODE
} catch {
    L ('ERROR: ' + $_.Exception.Message)
    exit 1
}
