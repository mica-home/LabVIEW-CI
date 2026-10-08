# VM Build-Runner Operations Manual (MICA / Lane 3)

> Scope: run a **Windows build VM** (VMware or Hyper-V) on the host machine, install
> LabVIEW 2026 and all build dependencies inside it, and register it as a **Gitea Actions
> Windows runner** (label `windows-labview26:host`, capacity 1), so the tag-triggered
> build / package / dual-write release (Lane 3) can run.
> Audience: maintainers (administrator rights needed on both the host and the VM).
> General CI documentation (the three lanes, the Linux runner, the local release sequence,
> credential rotation) remains in **`docs/ci.md`**; this file only covers VM- and
> runner-specific operations. On any conflict, **`docs/ci.md` wins** and the conflict is
> flagged here (see section 10).
>
> Check free disk space on your own machine before starting — the VM disk should live on
> a drive with ample free space (see section 2).

## 1. Goal and topology

**Goal (Lane 3)**: upgrade "compile / package / dual-write release" from manual execution
by the maintainer (Lane 2) to **tag-triggered, automatic execution on a Windows runner**;
CI (the Linux runner) keeps doing only LabVIEW-free static verification.

- **CI checks (Linux runner)**: `node ci/version.mjs check` + `node ci/repo-integrity.mjs --strict`
  (`verify.yml`), read-only, no LabVIEW.
- **Build / package / release (Windows runner inside the VM)**: a tag (`v*`) triggers
  `release.yml`, `runs-on: windows-labview26`, steps reuse `ci/labview.ps1` →
  `ci/package.ps1` → `ci/release-local.ps1`.
- **Host machine**: continues to carry Lane 2 local releases and everyday development;
  the host can keep using LabVIEW while the VM builds (the two are different machines /
  different licensed instances, see section 6).

```
                 git push tag v*                ┌────────────────────────────────────────┐
  maintainer/host ────────────────────────────► │ Gitea (gitea.sevenology.top)           │
    └─ everyday dev / Lane 2 local release       │  ├─ Actions scheduler: label matching  │
                                                 │  ├─ Linux runner: verify.yml (static)  │
                                                 │  └─ Windows runner: release.yml        │
                                                 └───────────────┬────────────────────────┘
                                                                 │ job dispatch (outbound 443)
    Host Windows 11 (Hypervisor enabled)                          ▼
    ├─ LabVIEW 2026 32-bit (host license, VI Server port 3364) ┌─────────────────────────────┐
    ├─ Docker Desktop + WSL2 (occupies the Hyper-V layer)      │ Windows VM (suggest 6-8 vCPU│
    ├─ VM disk image on a roomy data drive                     │  / 16 GB / 120 GB)          │
    └─ VM hypervisor: VMware Workstation 17 + WHP, or Hyper-V  │  ├─ LabVIEW 2026 + AB       │
                                                               │  ├─ NI runtimes ×4 + VIPM   │
                                                               │  ├─ Node.js ≥ 20            │
                                                               │  ├─ 20 VIPM dependencies    │
                                                               │  └─ gitea-runner (scheduled │
                                                               │     task, auto-start)       │
                                                               └─────────────────────────────┘
```

## 2. VM sizing recommendations

| Item | Recommendation | Rationale |
| --- | --- | --- |
| vCPU | **6-8** | LabVIEW compiles are mostly single/few-threaded; leave headroom for the host (Docker + everyday dev) |
| RAM | **16 GB** | LabVIEW + Application Builder + Installer Builder peak usage is substantial |
| Disk | **120 GB** | OS + full LabVIEW + NI runtimes + dependencies + build outputs + snapshots; snapshots take extra space |
| Disk location | **a data drive with ample free space** (VMDK/VHDX both) | Do not put a 120 GB growing VM disk on a nearly-full system drive |
| Network | **NAT is enough** | Only outbound access to `gitea.sevenology.top`, `dl.gitea.com`, `github.com` (during CI runs); installation additionally needs `download.ni.com`, `vipm.io`, `ni.com` (activation) |
| Display | 1 virtual display is enough | Install and troubleshooting need a GUI; otherwise unattended |
| Virtualization features | no nested virtualization needed | The VM runs no Docker/WSL2 |

**Do not put the VM disk on the system drive**: a VM disk (120 GB) grows over time;
a roomy data drive also makes snapshots/clones easier. Dynamically growing disks are fine
(VMware: do not pre-allocate the full disk; Hyper-V: dynamic VHDX), but leave ≥ 40 GB of
snapshot headroom on the host side.

> Checkpoint: after creating the VM, confirm `Get-PSDrive D,E | Select Used,Free` (adjust
> the drive letters to your machine) and confirm the VM disk files really are on the data
> drive you chose.

## 3. Windows image and licensing

- **Image choice**: Windows 11 Pro (same as the host, Hyper-V guest capable) or Windows
  Server 2022 / 2025 (leaner, better suited to long unattended runs). Both meet LabVIEW
  2026's official system requirements.
- **Proper licensing**:
  - Use a **proper license** for a long-term CI machine (Win11 Pro retail/digital license,
    or Server Standard).
  - Evaluation limits: **Windows Server evaluation 180 days** (resettable with
    `slmgr /rearm`, limited times), **Windows 11 Enterprise evaluation 90 days** (no
    extension). After the evaluation period the system periodically shuts down / restricts
    itself — not suitable for a long-term unattended build machine.
- **First steps after install**:
  1. Run **Windows Update** to completion (including cumulative updates), then reboot;
  2. Install **VC++ runtimes**: both **x64 and x86** of 2015-2022 (LabVIEW 32-bit and some
     NI components depend on x86/x64 respectively);
  3. Recommended settings: power plan = high performance / never sleep, disable automatic
     restart (`pause updates` or active hours), pick a machine name such as
     `mica-build-01`.

Verification commands (in-VM pwsh):

```powershell
# OS version
(Get-ComputerInfo).WindowsProductName; (Get-ComputerInfo).WindowsVersion
# VC++ runtimes (both x64 and x86 2015-2022 entries should appear)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
  Where-Object DisplayName -like '*Visual C++*' | Select-Object DisplayName
Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
  Where-Object DisplayName -like '*Visual C++*' | Select-Object DisplayName
```

## 4. VMware alongside existing Hyper-V / WSL2

**Starting point**: the host already has the Hypervisor enabled (Docker Desktop + WSL2 in
use) and no VMware installed.

- **Route A (VMware Workstation 17, must coexist with Hyper-V)**
  - First enable **Windows Hypervisor Platform (WHP)**, otherwise VMware 17 conflicts with
    the Hyper-V layer (cannot power on, or "VMware Workstation and Hyper-V are not
    compatible"). Enable (admin):
    ```powershell
    dism /online /enable-feature /featurename:HypervisorPlatform /all /norestart
    # confirm after reboot:
    Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform | Select FeatureName,State
    ```
  - Once enabled, VMware 17.0+ runs in **ULM (WHP-based)** mode on top of Hyper-V:
    **performance is reduced** (roughly 10-30% depending on load), and stability is worse
    than native on some host/driver combinations. Do not enable "Virtualize Intel
    VT-x/EPT" in the VM settings (no nested virtualization needed inside).
  - Benefit: mature snapshot/clone experience, and no need to shut down Docker Desktop
    while WSL2 coexists.
- **Route B (alternative: build the VM directly with Hyper-V, no VMware)**
  - With the Hypervisor already enabled and Win11 Pro shipping with Hyper-V, the
    management layer is more "native": no WHP translation overhead, and no extra license
    needed (VMware Workstation requires a license for commercial use; the personal edition
    is also bound by its license terms).
    ```powershell
    # admin, if the Hyper-V management tools are not yet enabled:
    dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart
    ```
  - In Hyper-V Manager create a **Generation 2** VM: 6-8 vCPU, 16 GB fixed memory (fixed
    is recommended for a build machine — dynamic memory can disturb LabVIEW), **dynamic
    VHDX on a roomy data drive**, network **Default Switch (NAT)**, disable "automatic
    stop"-style policies.
  - Checkpoints are snapshots; usage in section 8.
- **Recommendation**: pick one; never run the same VM under both hypervisors. Already own
  VMware and value snapshot/clone experience → Route A; want one less translation layer
  and one less licensing question → Route B.
- **Clarification**: do not install Docker/WSL2 inside the VM (this project's VM only runs
  LabVIEW builds and the runner).

Verification (on the host, after choosing a route):

```powershell
# host Hyper-V/WHP state
Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform,Microsoft-Hyper-V-All |
  Select-Object FeatureName,State
# is the VM really up and NAT-ing out (inside the VM):
Test-NetConnection gitea.sevenology.top -Port 443
```

## 5. In-VM install checklist and order

> The order has dependencies: LabVIEW dev environment → NI runtimes (needed to package the
> Installer) → VIPM → Node → VIPM dependencies. Each step lists verification commands
> (in-VM pwsh, admin).

1. **LabVIEW 2026 Professional (32-bit, including Application Builder)**
   - Use an offline installer of the same version/bitness (32-bit); install to the
     **default path** `C:\Program Files (x86)\National Instruments\LabVIEW 2026\` —
     `ci/labview.ps1`'s default `-LabVIEWPath` points there, and the workflow passes no
     extra argument when reusing defaults.
   - Verify:
     ```powershell
     Test-Path 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'         # True
     Test-Path 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe' # True
     (Get-Item 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe').VersionInfo.ProductVersion
     ```
   - Application Builder verification: open `Lab_Super.lvproj`; a **Build Specifications**
     node appears in the project tree (containing Launcher-Release and the other 3 specs)
     once installed.
2. **The 4 NI runtimes** (used to package the `MICA Installer` spec; product names map
   one-to-one to `Lab_Super.lvproj`'s `DistPart[*]`):
   - NI-VISA Runtime 26.0.1
   - NI LabVIEW Runtime 2026 Q1 Patch 2
   - NI-DAQmx Runtime 26.0
   - NI-488.2 Runtime 25.8
   - Verify:
     ```powershell
     $nipkg = 'C:\Program Files\National Instruments\NI Package Manager\nipkg.exe'
     if (Test-Path $nipkg) { & $nipkg list --installed | Select-String -Pattern 'ni-visa|labview-runtime|ni-daqmx|ni-488' }
     # fallback: check the 4 product names one by one under Control Panel -> Programs and Features
     ```
3. **VIPM (JKI)**
   - The latest community edition suffices for dependency installation; accept the license
     on first launch and log in as needed.
   - Verify:
     ```powershell
     Get-ChildItem 'C:\Program Files*\JKI\VIPM\*.exe' | Select-Object FullName
     ```
4. **Node.js ≥ 20 (LTS)**
   - Purpose: CI's Node probe step and `ci/version.mjs` (tag/version consistency checks)
     both run on the runner.
   - **Install scope matters**: choose "install for all users" (machine-level PATH) so the
     runner (the user the scheduled task runs as) can resolve `node` directly.
   - Verify:
     ```powershell
     node --version   # expect v20.x or higher (repo minimum 18+, Lane 3 workflow expects ≥20)
     npm --version
     ```
5. **The 20 VIPM dependencies**
   - The single source of truth is `[vipm.dependencies]` in the repo root's
     `Lab_Super.dragon` (20 ids; list snapshot in `packages/VIPM Package List.txt`). The
     repo provides bootstrap script **`ci/bootstrap-deps.ps1`**:
     ```powershell
     # in the VM, get a working copy of the repo first (path of your choosing, e.g. C:\MICA)
     git clone https://gitea.sevenology.top/<org>/<repo>.git C:\MICA
     Set-Location C:\MICA
     pwsh -NoProfile -File ci/bootstrap-deps.ps1
     ```
   - The script ships with the repo (the first draft of this document predated its merge
     at HEAD `66a5a3d`; it is available now). It: asserts VIPM / LabVIEW / Node are in
     place → installs the dependencies → reconciles with `vipm list` and **requires all
     20 ids to be present**, exiting non-zero and naming any missing one — so do not trust
     the install phase's "installed successfully" output alone.
   - If `vipm list --installed`'s real output format does not match the script's parsing
     expectations, the script **reports everything missing and never fakes green**
     (including a raw dump); in that case check the real format once per the prompt and
     report it — do not hand-edit the assertion to let it pass.
   - Verification (three options, any two or more):
     ```powershell
     # (a) reconcile the VIPM installed list (GUI: VIPM -> Installed Packages; CLI names depend on version)
     # (b) can LabVIEW resolve the key dependencies: open Lab_Super.lvproj, no question marks / broken arrows
     # (c) one end-to-end compile (final acceptance; see the "acceptance" command in section 9)
     pwsh -NoProfile -File ci/labview.ps1 -BuildSpec 'Launcher-Debug'
     ```
6. **Final acceptance (before registering the runner)**: (c) above compiles, and
   `pwsh -NoProfile -File ci/package.ps1 -Version <X.Y.Z> -SkipVersionCheck` produces
   4 zips in `dist/` — the VM is then able to take jobs.

## 6. Licensing notes (important)

- LabVIEW inside the VM is a **separate activation**: it may consume a **second seat**, or
  require **deactivating the host's** license first. Check your NI license terms before
  installing (NI License Manager shows current seat usage); this project uses LabVIEW on
  the host and the VM **simultaneously** (host local releases / VM builds) — these are not
  "the same instance".
- If the license allows only one machine: move the activation to the VM (deactivate the
  host), or purchase/allocate a separate seat for the VM.
- **`-Headless` (container scenarios) needs no activation**; but **a native VM install is
  a normal activation** — do not assume "a build machine needs no license".
- Activation is **machine-fingerprint bound**: after activating the VM, **do not change
  the VM's UUID/MAC/hostname**; rolling back to an activated snapshot is unaffected (the
  fingerprint is unchanged), but "rebuild the VM after activating" requires reactivation.
- Offline activation: use NI's offline activation flow (needs a second internet-capable
  machine to generate/submit the request), or let the VM temporarily reach the internet
  for activation and then tighten the network.

## 7. Runner registration

### 7.0 One-shot bootstrap (recommended for first setup: `vm-bootstrap.ps1`)

**`ci/runner/vm-bootstrap.ps1` is a single-file bootstrap package**: copy it into the VM
(no repo clone, no credentials needed), run it once as administrator, paste the
registration token when prompted, and it walks the whole chain "Node → runner registration
online → dependency bootstrap". Everything else (the gitea-runner binary,
`ci/bootstrap-deps.ps1`, `Lab_Super.dragon`) it downloads itself.

```powershell
# in the VM, admin pwsh (copy the file to any directory, e.g. C:\vm-bootstrap.ps1)
pwsh -NoProfile -File C:\vm-bootstrap.ps1
```

- The only interaction is the token prompt (`Read-Host -AsSecureString`, **no echo**);
  the token stays in memory only — **never written to a file, never on a command line,
  never printed**; at registration it only passes to the runner via the environment
  variable `GITEA_RUNNER_REGISTRATION_TOKEN`. For non-interactive scenarios (remote
  session / scheduled task) use the environment variable instead; the script does not
  attempt to prompt when stdin is not a console:
  ```powershell
  $env:GITEA_RUNNER_REGISTRATION_TOKEN = (Read-Host -Prompt 'token' -MaskInput)
  pwsh -NoProfile -File C:\vm-bootstrap.ps1
  Remove-Item Env:\GITEA_RUNNER_REGISTRATION_TOKEN
  ```

Four phases (each prints progress; failure messages say what to do next):

| Phase | What it does | Failure exit code |
| --- | --- | --- |
| 0 preflight (always runs) | hostname/all IPv4s/OS/admin/disk free (system + data drive)/`node --version`/LabVIEW & VIPM probes + **manual-install checklist** (LabVIEW 2026 Professional with Application Builder, 4 NI runtimes, VIPM, with expected paths) → writes `<StageDir>\preflight.json` | — |
| 1 Node | skip if `node --version` ≥ 20; otherwise `winget install OpenJS.NodeJS.LTS --silent` (timeout 900s, session PATH refreshed and **re-verified** after install — the installer banner is not trusted) | 6 (with official MSI page / latest LTS directory; rerunnable) |
| 2 runner | download/reuse gitea-runner (windows-amd64) → write `config.yaml` (`windows-labview26:host`, `capacity: 1`, `<RunnerRoot>\_work`) → register (token only via env var) → scheduled task `MicaGiteaRunner` (SYSTEM / AtStartup) → start immediately → **verify the process is really there** (poll `Get-Process`; the task reporting Running does not count) | 4 (binary download failed) / 5 (registration or auto-start failed) |
| 3 deps | fetch `ci/bootstrap-deps.ps1` and `Lab_Super.dragon` from Gitea raw API with the same token into `<StageDir>`, then run `bootstrap-deps.ps1 -DragonFile <StageDir>\Lab_Super.dragon` (NI runtimes are installed manually per the Phase 0 checklist, so `-SkipNipm` is the default; `-WithNipm` lets VIPM also handle the nipm entries in the dragon) | 3 (401/404/network failure) / 7 (subscript non-zero exit) |

- **Idempotent / resumable**: each phase writes a marker `<StageDir>\.phase1-node.done` /
  `.phase2-runner.done` / `.phase3-deps.done` on success; reruns skip completed phases;
  `-Force` redoes everything (including re-download, re-registration). If `.runner`
  already exists it **will not** re-register — Gitea registration tokens are
  single-use; re-registering would burn a new token for nothing. Failed registrations
  clean up half-products; **auto-start failure deletes only the broken scheduled task and
  keeps valid registration state** (after fixing, rerunning needs no new token).
- **Manual fallback if files cannot be fetched** (Phase 3 exit code 3): on a machine that
  can reach the repo, copy `ci/bootstrap-deps.ps1` and `Lab_Super.dragon` into
  `<StageDir>\`, then `pwsh -NoProfile -File vm-bootstrap.ps1 -SkipRunner` (the already
  registered runner is idempotently skipped; Phase 3 uses the local files, no token).
- Common parameters: `-InstanceUrl` (default `https://gitea.sevenology.top`),
  `-RepoSlug MICA/MICA`, `-Ref dev`, `-RunnerRoot <dir>` (e.g. `C:\gitea-runner`),
  `-StageDir <dir>`, `-Name <default $env:COMPUTERNAME>`, `-Labels 'windows-labview26:host'`,
  `-Capacity 1`, `-RunnerBinaryPath <offline binary>`, `-SkipNode` / `-SkipRunner` /
  `-SkipDeps` / `-Force`, `-TaskUserId` (default `SYSTEM`; change to the current user if
  the LabVIEW build needs an interactive session). Full parameters and exit codes in the
  script header comment.
- Exit codes at a glance: `0` success; `2` usage/config error (missing token, invalid
  URL/name/label/capacity); `3` Phase 3 file fetch failed; `4` runner binary download
  failed; `5` registration or auto-start failed; `6` Node install failed; `7` dependency
  bootstrap failed.
- **Offline machines**: manually download the windows-amd64 gitea-runner and the Node LTS
  MSI, install both, then `-RunnerBinaryPath <dir>\gitea-runner.exe`; pre-place files for
  Phase 3 per the manual fallback above.
- For maintainers: the script's test seams are `-RunnerBinaryPath` / `-NodeCommand` /
  `-WingetCommand` / `-TaskBackend` / `-DepsScript` (`ci/tests/vm-bootstrap.tests.ps1` uses
  them to keep real Gitea/dl.gitea.com/VIPM/Node install/scheduled tasks out of the tests;
  HTTP only hits the loopback api-stub). Real in-VM bootstrap is manual QA (see the task
  results archive).

### 7.1 Getting the registration token (Gitea Web UI)

1. Open `https://gitea.sevenology.top`, go to the repo (or org) **Settings → Actions →
   Runners**;
2. **Create new runner**, copy the token (**shown only once**); an org-level runner can be
   used instead if desired.
3. Back in the VM, read it with `Read-Host -MaskInput` into an environment variable
   (**never** type the token directly on a command line — it would land in the PowerShell
   history file):

```powershell
# in the VM (Set-Location to the repo working copy first is recommended)
$t = Read-Host -Prompt 'Gitea registration token' -MaskInput
$env:GITEA_RUNNER_REGISTRATION_TOKEN = $t
Remove-Variable t

# option 1: the script downloads gitea-runner (windows-amd64) itself into <RunnerRoot>
pwsh -NoProfile -File ci/runner/setup-runner.ps1 -RunnerRoot C:\gitea-runner -ServiceTask

# option 2 (recommended, controlled source): download the windows-amd64 gitea-runner manually and point at the file
#   download page: https://dl.gitea.com/gitea-runner/   (files like gitea-runner-<version>-windows-amd64.exe)
pwsh -NoProfile -File ci/runner/setup-runner.ps1 -RunnerRoot C:\gitea-runner `
    -BinaryPath C:\gitea-runner\gitea-runner.exe -ServiceTask

Remove-Item Env:\GITEA_RUNNER_REGISTRATION_TOKEN
```

`setup-runner.ps1` behavior notes (full parameters in the script header comment):

- **Idempotent**: if `<RunnerRoot>\.runner` already exists, **registration is skipped**
  (only `config.yaml` and auto-start are ensured); `-Force` re-registers;
- Generates `<RunnerRoot>\config.yaml`: `log.level: info`, `runner.capacity: 1`,
  `runner.labels: ["windows-labview26:host"]`, `host.workdir_parent: <RunnerRoot>/_work`;
- **The token is never echoed and never written to any file** (the registration command's
  output is also scrubbed by the script);
- Registration failure → non-zero exit and **half-products cleaned up** (no `.runner`/temp
  dirs left; a failed `-Force` rolls the original `.runner` back intact);
- **Working-directory guardrail**: if `-WorkDir` (default `<RunnerRoot>\_work`) resolves
  inside any git repository → refused outright, nothing written;
- `-ServiceTask`: registers the **scheduled task** `MICA Gitea Runner (mica-build-01)`
  (boot + logon triggers, current interactive user, daemon output appended to
  `<RunnerRoot>\runner-daemon.log`) and tries to start it immediately; without
  `-ServiceTask` it only prints the manual start command.

Enable **auto-logon** on the VM (uncheck "must enter password" in `netplwiz`, or registry
`AutoAdminLogon`) so the task's logon trigger is ready unattended (LabVIEW builds need an
interactive session).

### 7.2 Confirming Online

- Back in Gitea's **Settings → Actions → Runners**, confirm `mica-build-01` shows
  **Online** (green). If the daemon is not running the runner shows offline after
  registration: start the daemon first (the scheduled task starts it when registered with
  `-ServiceTask`, or run the manual command printed by the script in the foreground), then
  refresh the page.
- In-VM self-check:
  ```powershell
  Get-ScheduledTask -TaskName 'MICA Gitea Runner (mica-build-01)' | Get-ScheduledTaskInfo
  Get-Content C:\gitea-runner\runner-daemon.log -Tail 30
  ```

### 7.3 Temporarily offline / recovery / re-registration

```powershell
# temporarily offline (registration untouched; jobs queue)
Disable-ScheduledTask -TaskName 'MICA Gitea Runner (mica-build-01)'
Stop-Process -Name gitea-runner -ErrorAction SilentlyContinue

# recover
Enable-ScheduledTask  -TaskName 'MICA Gitea Runner (mica-build-01)'
Start-ScheduledTask   -TaskName 'MICA Gitea Runner (mica-build-01)'
```

- Permanent removal: delete the runner in the Gitea UI, delete `<RunnerRoot>\.runner` in
  the VM and unregister the task
  (`Unregister-ScheduledTask -TaskName 'MICA Gitea Runner (mica-build-01)'`).
- New labels / capacity change / re-registration: change parameters and rerun
  `setup-runner.ps1` with `-Force` (see 7.1).

### 7.4 Starting the VM after a host reboot (`ci/runner/host-vm-autostart.ps1`)

The runner lives *inside* the VM, so a host reboot takes Lane 3 offline until the VM is
powered on again. Jobs matching `windows-labview26` stay **queued** (Gitea holds them; they
are not lost), which from the outside looks exactly like a broken pipeline — check the
runner before suspecting a workflow.

Powering the VM on is a **host-side** action, and the script needs three keys in the host's
own `ci/vm.env` (it reads the file next to itself: `$PSScriptRoot\..\vm.env`):

| Key | What it is | Where to read it off |
| --- | --- | --- |
| `VMRUN_PATH` | absolute path to `vmrun.exe` in the VMware Workstation installation | the install directory (Workstation defaults to a `VMware Workstation` folder, which is not always on `C:`) |
| `VMX_PATH` | absolute path to the VM's `.vmx` (not the `.vmdk`) | VM → Settings → Options → General shows it; or the `configPath` entries in `%APPDATA%\VMware\inventory.vmls` |
| `VMX_ENCRYPTION_PASSWORD` | the password chosen when the VM was encrypted | VM → Settings → Options → Access Control. **It is not stored in any VM file** and there is no recovery path — see 9b, point 2 |

**Write those values bare — no surrounding quotes.** The parser splits each line on the
first `=` and only trims whitespace, so a quoted path is handed to `Test-Path` with the
quote characters still attached and the script exits 2 logging `vmrun not found`. Spaces in
an unquoted path are fine.

Verify the wiring without waiting for a reboot; the script is idempotent (a running VM is a
no-op):

```powershell
pwsh -NoProfile -File ci/runner/host-vm-autostart.ps1; "exit=$LASTEXITCODE"
Get-Content "$env:ProgramData\MicaVmAutostart\autostart.log" -Tail 5
```

Pass condition: `exit=0`, with the log showing either `VM already running - nothing to do`
or `start exit=0`. `exit=2` names the cause (a key missing, or a `vmrun` path that does not
resolve). **No script in this repository creates the scheduled task** — it is a one-time
action on the host, and if it was never done then filling in `ci/vm.env` alone still leaves
the VM off after a reboot:

```powershell
schtasks /create /f /tn MicaVmAutostart /sc ONSTART /ru SYSTEM `
  /tr "pwsh -NoProfile -ExecutionPolicy Bypass -File <repo-root>\ci\runner\host-vm-autostart.ps1"
```

Two things to know once that task exists:

- **Prefer the scheduled-task module when you register it.** `Register-ScheduledTask`
  with `-User 'SYSTEM' -RunLevel Highest` and `-New-ScheduledTaskAction -Execute <full path to
  pwsh>` is what was verified here; pass the interpreter's **absolute** path, because the
  SYSTEM account's PATH is not guaranteed to contain `pwsh`. Building `-Settings` from
  `New-ScheduledTaskSettingsSet` is optional - omit it rather than fighting a null return.
- **A VM started by that task is invisible to `vmrun` run as your own user - for every verb,
  not just `list`.** The task runs in the SYSTEM session, so the `vmware-vmx.exe` it spawns
  belongs there: `vmrun list` answers `Total running VMs: 0`, and `CopyFileFromHostToGuest` /
  `RunProgramInGuest` / `getGuestIPAddress` answer `The virtual machine is not powered on`
  while the VM is genuinely up and building. Measured 2026-09-28: the *same* `vmrun list`
  command answered `Total running VMs: 1` when run as SYSTEM. So run guest operations as the
  identity that powered the VM on - the shortest path is a one-time
  `schtasks /create … /ru SYSTEM` task that executes your helper and is deleted afterwards.
  Prove liveness by process otherwise - `Get-CimInstance Win32_Process -Filter
  "Name='vmware-vmx.exe'"` with `CreationDate` against the task's `LastRunTime` - or read the
  task's own log at `%ProgramData%\MicaVmAutostart\autostart.log`, which records `start exit=0`.

Do not use `ping <guest-ip>` as the readiness signal: the host's NAT may answer for that
address while the guest is still booting. Nor is `vmrun list` a signal when the VM was started
by the SYSTEM task (see the bullet above - it answers 0 for a VM that is up). Use the
autostart log or the `vmware-vmx.exe` process on the host, or wait for **Online** in the Gitea
runners page (7.2).

Inside the guest, prefer `(Test-NetConnection <host> -Port 443).TcpTestSucceeded` over
`Test-Connection -Quiet`: the latter has been observed returning `False` from a CIM-layer
failure (`Test-Connection : Generic failure`) on a link that was actually healthy - a false
negative that will send you chasing a network that is fine.

**Reading the runner's state from the host, without logging into the VM.** `start … nogui`
leaves the guest with no interactive session, so the Workstation UI is not needed — the
Tools guest operations work over the `ci/vm.env` guest account. The runner root is the
`-RunnerRoot` passed to `setup-runner.ps1` (it holds `config.yaml`, `.runner`,
`gitea-runner.exe`, `runner-daemon.log` and `_work`), and that log is the authoritative
answer to "is the runner online?":

```powershell
# is the daemon running?
vmrun -T ws -vp <vp> -gu <guest-user> -gp <guest-pw> listProcessesInGuest <vmx> | Select-String gitea-runner
# pull its log and read the last lines
vmrun -T ws -vp <vp> -gu <guest-user> -gp <guest-pw> CopyFileFromGuestToHost <vmx> `
  <RunnerRoot>\runner-daemon.log <host-dir>\runner-daemon.log
```

Two mechanical traps when you script a guest operation like the ones above:

- **Execution policy silently kills a payload script.** `powershell -File script.ps1` returns
  exit code 1 and produces **no output file at all** when every policy scope is `Undefined`
  (the client-Windows default, which behaves as Restricted). `-ExecutionPolicy Bypass` on the
  command line does not always help; invoke it as
  `-Command "iex (Get-Content -Raw C:\path\script.ps1)"` instead. Make the payload's first
  statement write its own output file: then "file missing" reliably means "the payload never
  ran", as opposed to "it ran and found a problem".
- **Have the payload write to `C:\Users\Public`, not `C:\Windows\Temp`** - the latter is
  virtualised for a non-elevated guest process, so the file lands somewhere you will not look.
  And on a localized guest Windows the `ipconfig` labels are localized too: filter on values,
  not on English label text.

A successful start ends with a `runner: <name>, with version: …, with labels: […], declare
successfully` line. **When that line is absent, the fault is on the path between the VM and
the Gitea instance, not inside a workflow** - but do not assume the runner will fix it
unattended. Two different endings exist, and they need different actions:

- the daemon is **still running** and retrying: jobs that already matched this runner's label
  stay **queued** and begin as soon as a declare succeeds, so nothing needs re-triggering;
- the daemon has **exited**: a `fail to invoke Declare` during startup can be fatal to the
  process. Measured 2026-09-28 - the runner died at 14:12 on `unavailable: unexpected EOF` and
  was still absent at 15:57, so 105 minutes of "it should recover on its own" recovered
  nothing. Restart it through its own autostart task (`Start-ScheduledTask` on the task
  `vm-bootstrap.ps1` / `setup-runner.ps1` created, e.g. `MicaGiteaRunner`) rather than
  launching a second daemon by hand.

So the first question is "is the process there?", not "should I wait?". `listProcessesInGuest`
or a `tasklist` filtered on the real binary name answers it - and note the binary is named
after the runner package (`gitea-runner.exe`), so a probe written against a guessed name
reports "no such process" for a runner that is running fine.

What that path consists of (addresses, resolvers, services or a proxy in front of the
instance) differs from machine to machine: treat a diagnosis of a particular host as an
operator note kept outside the repository, and record here only the symptom, the two possible
endings above, and the failure modes that generalise (section 7.5).

### 7.5 Keeping the runner's network path off the critical path

Three separate Lane 3 outages on one machine turned out to have three different causes and one
identical symptom (no `declare successfully`, jobs queue). They generalise, so they belong here;
the per-machine values behind them belong in an operator note outside the repository.

| Cause | What was actually wrong | Why the obvious check misses it |
| --- | --- | --- |
| The host's DHCP service exited by itself | it could not rewrite its lease database because the host's **system drive was full**, and for that daemon a failed lease commit is fatal | the service is set to `Automatic`, so "correctly configured" reads as "running"; and because it told the service controller it was stopping, **no crash event is recorded, so a configure-recovery-on-failure action would never have fired either** |
| The host's NAT service crashed | the guest's default gateway *and* its DNS server both are that service, so the guest lost egress with it | it has a recovery action and self-healed in about a minute; minutes later the machine looks perfectly healthy and only the runner's log shows the gap |
| The NAT DNS proxy never came up | another host service won the **boot race for UDP port 53**, so the hypervisor's NAT process could not bind its DNS proxy and the guest's configured resolver was a black hole | the NAT service reported `Running` and was verifiably forwarding TCP - **only name resolution was dead**. Service state is not link health |

Two design rules follow, and both are cheaper than a watchdog:

1. **Do not let the runner's address depend on a dynamic host service.** Pin it - a static
   address in the guest, or a reservation on the host. If you pin it in the guest, put it
   **outside that NAT segment's DHCP range**: a static address inside the pool will eventually
   be handed to a second VM, and the resulting duplicate-address failure looks like random CI
   breakage that is miserable to diagnose. Accept the tradeoff knowingly: once the guest is
   static it stops appearing in the host's lease file, so "a fresh lease entry proves the VM is
   alive" is a signal you no longer have - use the autostart log, the hypervisor's VMX process,
   or the runner's own `declare successfully` line.
2. **Do not make the guest's resolver the hypervisor's NAT proxy.** Point it at any resolver
   reachable *through* NAT. The third failure mode above then cannot take the runner down, and
   one host-service dependency leaves the critical path. Worth verifying rather than assuming
   while you are there: what the instance hostname actually resolves to from outside any local
   proxy. If it is fronted by a CDN, the runner needs no local DNS interception at all, and a
   proxy in front of the instance becomes an optional hop instead of a single point of failure.

If you prefer detection over prevention, then **poll and log**, because the Windows event log
may hold nothing: some machines record no service start/stop transitions whatsoever (event 7036
absent for a whole month), and a self-exiting daemon writes no failure event either. The log is
the deliverable - it turns "it broke sometime over the weekend" into a timestamp you can correlate.
Two machine-independent probes beat a service-state check: call the instance's API over HTTPS
from inside the guest, and when name resolution fails while NAT says `Running`, ask **who owns
port 53** (`Get-NetUDPEndpoint -LocalPort 53`, then map the PID to its service with
`tasklist /svc /fi "PID eq <pid>"`).

Two disciplines that keep a watchdog honest, both learned the hard way:

- Rate-limit and require consecutive failures before acting (e.g. two checks ~10 minutes apart,
  at most one restart per 10-minute window), or it silently restarts the world during a
  network flap and erases the evidence you needed.
- When enumerating scheduled tasks to start, match narrowly and **print the candidate list
  before starting anything**. A pattern as loose as `runner|act` also matches unrelated
  system tasks (`…Inter-active`, `Proact-ive…`) and starts them.

## 8. Snapshot policy (rollback points)

VMware snapshots / Hyper-V checkpoints live on the drive hosting the VM disk and take
extra space (see section 9 cleanup).

| Snapshot | When to take | Suggested name | What to do after rollback |
| --- | --- | --- | --- |
| S0 | OS + Windows Update + VC++ installed | `S0-os-clean` | nothing |
| S1 | LabVIEW + Application Builder + 4 NI runtimes + VIPM installed, **activation complete** | `S1-labview-licensed` | nothing (activation survives in the snapshot) |
| S2 | 20 VIPM dependencies installed, `Launcher-Debug` compiles | `S2-deps-built` | nothing |
| S3 | **one before and one after runner registration**: before = `S3-pre-register`; after confirming Online + one successful build = `S4-registered-online` | `S3-pre-register` / `S4-registered-online` | After rolling back to S3: `.runner` may be missing or stale → re-register with `-Force`; a same-name offline entry may appear in the Gitea UI, delete as needed |

Discipline:

- **Never snapshot while a build is running** (file handles/locks make snapshots
  inconsistent, and the build may slow down or fail).
- Snapshots are "rollback points" only; do not accumulate dozens long-term; before
  merging/deleting old snapshots confirm the current state is recoverable.
- Rolling back to S2 (dependencies present, not yet registered) is the most common
  "clean environment, dependencies ready" state.

## 9. Operating discipline and troubleshooting

### Operating discipline

- **During a tag build, avoid other heavy work in the VM** (no LabVIEW GUI, no Windows
  Update, no snapshots). The host can keep normal development / local releases.
- **Jobs queue while the runner is offline (not lost)**: Gitea holds jobs matching the
  `windows-labview26` label and hands them over when the runner is back; just recover
  within the job timeout window.
- **Do not open the LabVIEW GUI in the VM during a build**: `ci/labview.ps1`'s port
  ownership precheck **fails outright (exit code 3)** if the VI Server port is held by
  another process — deliberate protection (avoid closing an interactive instance as if it
  were the build instance).
- **Why port 3364**: the host's `LabVIEW.ini` sets the VI Server port to 3364
  (non-default 3363). `ci/labview.ps1` **reads `server.tcp.port` from the `LabVIEW.ini`
  in the same directory as `-LabVIEWPath`** and never guesses the default. **A fresh VM's
  `LabVIEW.ini` may not have the key** (a fresh install writes nothing, or 3363): the
  build fails with "server.tcp.port not configured … pass -PortNumber explicitly".
  Recommended: set the port to **3364** in the VM's LabVIEW via Tools → Options →
  VI Server (matching the host makes troubleshooting easier), or pass `-PortNumber`
  explicitly in the workflow.
- Build outputs and logs live in the runner's working directory (`<RunnerRoot>\_work\...`)
  and the repo working copy; the runner checks out into a fresh subdirectory per job; see
  cleanup points below when disk runs tight.

### Troubleshooting

| Symptom | Look first | Handling |
| --- | --- | --- |
| **VM suspends itself, runner offline** | host's `<vm-dir>\vmware.log`: look for `PIIX4: PMAccessPM got ACPI S1 request` | The guest Windows **put itself to sleep** after idle (not a VMware auto-suspend, not host sleep — host sleep would leave a Kernel-Power event-log record). One-time fix: in the VM, admin PowerShell: `powercfg /change standby-timeout-ac 0`, `powercfg /change hibernate-timeout-ac 0` (optionally `powercfg /hibernate off`). VMware has no switch that overrides a guest sleep request |
| runner shows offline | tail of `runner-daemon.log`; scheduled task state | start the daemon (7.3); confirm the VM can reach Gitea on 443 |
| runner offline **and the process is gone** (log ends on `fail to invoke Declare`) | is the binary still in `listProcessesInGuest` / `tasklist`? | the daemon can exit rather than retry - start its **own scheduled task** (7.3) instead of waiting; see 7.5 for why waiting recovers nothing |
| guest resolves nothing, DNS times out, but the NAT service says `Running` | who owns UDP 53 on the host: `Get-NetUDPEndpoint -LocalPort 53` then `tasklist /svc /fi "PID eq <pid>"` | a second service that grabbed port 53 first at boot prevents the NAT DNS proxy from binding. Either give the guest a resolver that is reachable *through* NAT, or free the port - see 7.5 |
| job stuck queued | labels on the Gitea Runners page | confirm the label is exactly `windows-labview26:host` and the runner is Online |
| build failed | Actions run page (step logs — the per-spec `labview.ps1` logs and version/integrity reports are printed to the **job log**, nothing is uploaded as an artifact); `.ci-logs/` in the runner's repo working copy holds the same files on disk (the workflow itself never runs the bootstrap: runner provisioning is out of band, see the LabVIEW-CI kit README) | first reproduce the same step locally (`docs/ci.md` has verbatim commands) |
| exit code 3 (port held) | who is listening on the port | close the LabVIEW GUI / leftover process in the VM: `Get-NetTCPConnection -State Listen -LocalPort 3364` → `taskkill /IM LabVIEW.exe` |
| "server.tcp.port not configured" | the VM's `LabVIEW.ini` | set 3364 as above (changing the port in the GUI writes it automatically) |
| registration failed (exit code 3) | the printed `[register]` output | token expired / instance unreachable / invalid label; fetch a fresh token in the UI and rerun (idempotent) |
| disk full | `Get-PSDrive C,D,E` | cleanup points below |
| disk full **on the host's system drive** (where VMware keeps its config/lease files) | free space there, not just in the VM | this can silently take Lane 3 down later: the host's DHCP daemon fails to commit its lease database and exits, and one lease period after that the guest loses its address - see 7.5 |

**Disk cleanup points (in the VM, by payoff)**:

```powershell
# runner working-directory leftovers (confirm no job is running before deleting)
Remove-Item C:\gitea-runner\_work\* -Recurse -Force -ErrorAction SilentlyContinue
# build and package outputs
Remove-Item C:\MICA\builds\*, C:\MICA\dist\*, C:\MICA\.ci-logs\* -Recurse -Force -ErrorAction SilentlyContinue
# user temp dir / Windows Update cache (admin)
Remove-Item $env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue
Dism.exe /Online /Cleanup-Image /StartComponentCleanup
# host side: VM snapshots and old checkpoints (delete in the VMware/Hyper-V manager; keep at least one rollback point)
```

## 9b. Migrating to another Windows host

After moving the whole VM to another host, **everything inside the guest travels with it**:
LabVIEW / NI runtimes / VIPM / Node / PowerShell 7, plus the runner binary and its
`.runner` credentials (the registration identity lives on the guest disk) — so the runner
**does not need re-registration**; on boot the scheduled task brings it up and it
reconnects to Gitea.

Six things to know first:

1. **Shut down cleanly before copying** — never migrate a suspended VM: a suspended image
   contains host CPU state, and resuming across CPU models may fail. Copy the **entire VM
   directory** (`.vmx` / `.vmdk` / `.nvram` / snapshot chain / `.vmsd`).
2. **Encrypted passwords travel too**: an encrypted VM's key is not in the files; the new
   host needs it at first power-on.
3. **Snapshots inflate the size significantly**: if the VM already has Snapshot1/2/3 (each
   with a 2-7 GB `.vmem`), consolidate/delete unneeded ones before migrating, or export an
   OVF instead (which flattens the snapshot chain).
4. **Network and subnet will change**: VMware NAT subnets are assigned by the host, so the
   guest IP usually changes. If you pinned the guest address per 7.5, that pin is now **wrong
   for the new host's subnet** and the guest will have no egress until you re-pin it (or hand
   it back to DHCP) - check the resolver and the default route before blaming Gitea. This
   repo's WinRM firewall rule already accepts **`LocalSubnet`** (any local subnet) rather than
   a fixed subnet; on the new host you still need to add the guest's new IP to `TrustedHosts`
   (see 4.2).
5. **Activation may break**: Windows and **NI (LabVIEW)** activations are usually bound to
   the machine fingerprint; after a host change reactivation may be required — confirm you
   have usable activation quota and accounts before migrating. The same applies to VIPM
   Pro licensing (if used).
6. **VMware version compatibility**: the target host's Workstation version must be able to
   open the VM's hardware version (newer opens older, not vice versa).

Three post-migration checks: (1) the Gitea Runners page shows Online (the runner
reconnects automatically); (2) from the VM, `Test-NetConnection gitea.sevenology.top -Port 443` succeeds; (3) on the new host run
`pwsh -File ci\labview.ps1 -BuildSpec 'Launcher-Debug'` once to confirm LabVIEW still
compiles (and that activation survived).

## 10. Relationship to `docs/ci.md`

- **This file = VM / runner specifics**: VM sizing, OS and LabVIEW installation,
  licensing, VMware/Hyper-V coexistence, snapshots, `ci/runner/setup-runner.ps1` usage and
  troubleshooting.
- **`docs/ci.md` = the general CI/CD manual**: the three-lane overview, the Linux runner
  and `verify.yml`, the local release sequence, credentials and rotation, the recovery
  manual, and the exit-code tables of `ci/labview.ps1` / `ci/package.ps1` /
  `ci/release-local.ps1`.
- **The two must not contradict**; on discovering a conflict: **`docs/ci.md` wins**, add a
  line in the relevant section here — "conflicts with docs/ci.md, defer to that document
  for now (YYYY-MM-DD)" — then fix one of them.
- Common crossover points:
  - exit-code semantics (`labview.ps1` 0/2/3/4/124…, `release-local.ps1` 0/1/2/3/4/5) —
    `docs/ci.md` is authoritative;
  - the platform-boundary argument for "why builds do not run in Linux CI" is in
    `docs/ci.md`;
  - dual-write release credentials (`GITEA_TOKEN` / `GITHUB_TOKEN`) and repo secret setup
    are in `docs/ci.md`; the VM side only needs the runner to reach the instance (the
    token is injected into the job by Gitea automatically).
- Change discipline: when changing `setup-runner.ps1`'s parameters/behavior, update
  section 7 here and `ci/tests/setup-runner.tests.ps1` in sync; when changing the
  workflow's runner label/triggers, update sections 1 and 9 here.
