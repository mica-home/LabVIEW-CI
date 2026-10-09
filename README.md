# LabVIEW-CI

Provisioning toolkit for the Windows Gitea Actions runner that builds the MICA LabVIEW
project. It was extracted from the MICA repository so that runner provisioning is managed
as its own project: MICA keeps only the files its pipelines need, and everything about
building, registering and feeding a Windows build VM lives here.

This repository's home is **`mica-home/LabVIEW-CI` on GitHub (public)**; it has no Gitea
mirror today. The runner it provisions is still a Gitea Actions runner for the MICA
instance - the two live on different forges by design.

## Layout

| Path | Purpose |
| --- | --- |
| `ci/bootstrap-deps.ps1` | Installs and asserts the VIPM dependency set declared in the dragon file (idempotent; `-VerifyOnly` performs a read-only reconciliation). |
| `ci/runner/vm-bootstrap.ps1` | One-file bootstrap for a fresh Windows build VM: preflight report -> Node.js -> Gitea runner registration -> dependency bootstrap (four phases, re-runnable at any point). |
| `ci/runner/setup-runner.ps1` | Registers a Gitea Actions runner on a host whose dependencies are already installed (binary download, `config.yaml` rendering, registration, optional scheduled task). |
| `ci/runner/host-vm-autostart.ps1` | Optional: starts the encrypted build VM when the host boots; designed to run as a SYSTEM scheduled task. Reads its parameters from `ci/vm.env`. |
| `ci/tests/` | PowerShell test suites for the scripts above, with local stand-ins under `ci/tests/fixtures/` (no network, no real VIPM, no real Task Scheduler). |
| `ci/vm.env.example` | Template for `ci/vm.env`. |
| `docs/ci.md` | The MICA project's CI/CD manual (lane overview, releases, credentials, troubleshooting). |
| `docs/vm-runner.md` | The VM and runner operations manual (specs, install checklist, one-shot bootstrap, registration, snapshots, decommissioning). |
| `Lab_Super.dragon` | Reference copy of the pinned dependency list (VIPM/NIPM). The test suites read it, and a standalone `bootstrap-deps.ps1` run uses it by default. |
| `runner-test-extras.dragon` | Test-lane add-ons on top of the base dependency set (the NI UTF JUnit report trio). Needed only on machines that run `RunUnitTests`; see "Test-lane extras" below. |

## Using the kit

On a fresh Windows host (the build VM), the documented one-liner is:

```powershell
pwsh -NoProfile -File ci/runner/vm-bootstrap.ps1
```

It prints a preflight report (host, disks, Node, LabVIEW, VIPM, manual-install
checklist), installs Node.js when missing, downloads and registers the Gitea runner
(the registration token is prompted for and never written to disk), and then bootstraps
the VIPM dependencies. `docs/vm-runner.md` section 7.0 is the full runbook.

On a host that already has its dependencies, register only the runner:

```powershell
pwsh -NoProfile -File ci/runner/setup-runner.ps1 -ServiceTask
```

The autostart helper is optional and is registered as a SYSTEM scheduled task; it starts
the encrypted VM at host boot. `docs/vm-runner.md` section 7.4 describes host-side
startup.

## Test-lane extras (UTF JUnit report)

Machines that run the **test lane** (`RunUnitTests`, with its JUnit report written through
the `utf` channel) additionally need NI's UTF JUnit report add-ons, which are deliberately
**not** part of `Lab_Super.dragon`. Without them `LabVIEWCLI` fails with **`-350053`**
("missing or bad files / required modules or toolkits"). Install them with the extras
dragon from the repo root:

```powershell
pwsh -NoProfile -File ci/bootstrap-deps.ps1 -DragonFile runner-test-extras.dragon -ExpectedPackageCount 3 -SkipNipm -LabViewBitness 32
```

Only test-running machines need this - the base provisioning above does not. Acceptance:
this command completes and writes the report (exit 0):

```powershell
LabVIEWCLI -OperationName RunUnitTests -ProjectPath <repo>\Lab_Super.lvproj -JUnitReportPath utf-junit.xml
```

## How the kit is consumed

The runner is provisioned out of band, before any MICA workflow runs: MICA's workflows
assume a runner that is already installed, registered and equipped, and the bootstrap is
not executed from inside a MICA workflow.

`vm-bootstrap.ps1` Phase 3 fetches each file from its own home: `ci/bootstrap-deps.ps1`
from this repository through the **GitHub contents API** (`mica-home/LabVIEW-CI`, ref
`main` - `-KitRepoSlug`/`-KitRef`, `-KitForge github` is the default). This repository is
public, so the kit fetch is **anonymous by default** and needs no credential; a GitHub
token (`-GitHubToken` or env `GITHUB_TOKEN`) is optional and adds an `Authorization:
Bearer` header for higher rate limits (or for a private fork). `Lab_Super.dragon` comes from
the MICA repository (`MICA/MICA`, ref `dev` - `-RepoSlug`/`-Ref`, which also remain the
runner registration target) through the **Gitea raw API** with the runner registration
token. `-KitForge gitea` switches the kit fetch back to the legacy Gitea raw route (for a
future Gitea mirror of this kit). When a fetch is not possible, the manual fallback is
printed: copy both files into the stage directory and re-run with `-SkipRunner`.

## Credentials

`ci/vm.env` is kept local to each machine and is never committed (`*.env` is ignored by
`.gitignore`). `ci/vm.env.example` documents the keys. Registration tokens are passed to
the runner through the environment and are never echoed or written to disk by these
scripts.

The kit fetch needs no credential: `mica-home/LabVIEW-CI` is public, so the contents
request is sent anonymously unless a token is supplied. `-GitHubToken` (or the
`GITHUB_TOKEN` environment variable) is **optional** - a fine-grained PAT with read access
to that repository (or a classic PAT with the `repo` scope) lifts the anonymous rate limit,
and a token is required only for a private fork. When supplied it travels only in the
`Authorization: Bearer` header of the contents request. The `GITEA_RUNNER_REGISTRATION_TOKEN`
and `GITHUB_TOKEN` are separate credentials for separate forges and are not interchangeable.

## Tests

The suites are real (they launch the scripts as child processes with stand-in back ends),
but they never touch the network or a real VIPM, Node install or Task Scheduler:

```powershell
pwsh -NoProfile -File ci/tests/vm-bootstrap.tests.ps1
pwsh -NoProfile -File ci/tests/bootstrap-deps.tests.ps1
pwsh -NoProfile -File ci/tests/setup-runner.tests.ps1
```

`ci/tests/fixtures/vipm-stub/`, `ci/tests/fixtures/runner-stub/` and
`ci/tests/fixtures/api-stub.mjs` are the stand-ins. `vm-bootstrap.ps1` exposes test
seams (`-RunnerBinaryPath`, `-NodeCommand`, `-WingetCommand`, `-TaskBackend`,
`-DepsScript`, `-KitApiBase`) so the suites can run unattended; see `docs/vm-runner.md`
for manual QA that needs a real VM.
