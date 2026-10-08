# CI/CD Operations Manual (MICA)

> Scope: this repository's CI (Gitea Actions) and the local build / release process.
> Audience: maintainers. Commands are written assuming "maintainer machine = Windows + pwsh 7 + LabVIEW 2026"; equivalents for inside CI (Linux runner / bash) are given where needed.
> This document was cross-checked against the implementation on 2026-09-17 (see "Change log" at the end); the "local reproduction" commands below have all been executed for real with exit codes recorded.

## 1. What this CI/CD is / is not

**What it is**

- CI (Lane 1) only performs **LabVIEW-free static verification**: version consistency + project integrity, running in a Linux runner on the Gitea host.
- Build and dual-write release (Lane 2) **run on the maintainer's Windows machine using in-repo scripts**: `ci/labview.ps1` (build) → `ci/package.ps1` (package) → `ci/release-local.ps1` (dual-write Gitea + GitHub release). **The same chain also runs automatically on the VM runner** (Lane 3, `.gitea/workflows/release.yml`, tag-triggered) — the two paths are equivalent, see "CI release (Lane 3)".

**What it is not (deliberately stripped)**

- **Lane 1** CI **does not** compile / run VI Analyzer / run unit tests, and **performs no write operations** (no commit, no tag, no release). Keeping the build out of the read-only checks is a core scope decision of this design, not an omission. **Note the distinction**: Lane 3's `release.yml` likewise **does not write to the repository** (read-only checkout, tags are created manually by the maintainer); its "writes" only happen against the Gitea / GitHub release APIs.
- The **compile gate is live since 2026-09-24** — but as its own Lane 3 workflow (`.gitea/workflows/compile.yml`, on the `windows-labview26` runner), not as a Lane 1 step: a LabVIEW build cannot run on the Linux runner, and merging it into `verify.yml` would break that file's "Linux-only and LabVIEW-free" contract, which the workflow self-check asserts. **VI Analyzer and unit tests remain deferred** (see the "Deferred items" list). Tag-triggered fully automatic release is live: it reuses the Lane 2 scripts such as `ci/labview.ps1`, running on a self-hosted Windows runner (label `windows-labview26`). For the VM setup / registration / snapshots see `docs/vm-runner.md`.

**Why the build cannot run inside CI (platform boundary, verified — do not re-litigate)**

- The Gitea host is **Linux**. Containers share the **host OS kernel**; Windows base images can only run on Windows 10 / Server 2016+ hosts.
- Windows workloads on K8s **require Windows worker nodes** (Linux nodes cannot run Windows Pods), and **K8s does not support Hyper-V isolation**.
- NI's official Windows container image (base `mcr.microsoft.com/windows/server:ltsc2022`) states it "can only run on a Windows host".
- → Any LabVIEW compile / build must happen on some **Windows machine**; therefore it lands on the maintainer machine (Lane 2) or a **self-hosted Windows runner** (Lane 3, see "CI release (Lane 3)"). **The Linux CI on the Gitea host only carries out LabVIEW-free checks** — Lane 3 does not change this: it uses a different, **Windows** machine; it does not squeeze LabVIEW into a Linux container.

**Known cost**: with the build stripped out, "does the code still compile" has no automatic pre-merge check — non-compilable changes can be merged into `dev`/`main` and only surface at release time (local build or the Lane 3 tag build). Mitigation: step 0 of the release checklist is a compile confirmation (see below).

## 2. The three lanes at a glance

| Lane | Where | Needs | Does | Status |
| --- | --- | --- | --- | --- |
| **Lane 1 — CI checks** | Gitea Actions: `.gitea/workflows/verify.yml`, Linux runner on the Gitea host | Linux runner; image includes Node 18+; no LabVIEW | `node ci/version.mjs check` + `node ci/repo-integrity.mjs --strict`; read-only, reports printed to the job log | **Active** |
| **Lane 2 — local build & release** | Maintainer's Windows machine (repo working copy) | Windows + pwsh 7 + LabVIEW 2026 (32-bit) + Application Builder / Installer Builder + VIPM dependencies + two tokens (`ci/release.env` or environment variables) | Compile confirmation → build 4 specs in fixed order → package 4 zips → dual-write Gitea / GitHub release | **Active** (equivalent to Lane 3) |
| **Lane 3 — compile gate** | Same self-hosted Windows runner; `.gitea/workflows/compile.yml` | The `windows-labview26` runner and nothing else (no token beyond the injected clone token, no secret, no LabVIEW project change) | Triggered by `push` to `dev` and every `pull_request` (plus `workflow_dispatch` with a `build_spec` input): probe → checkout → one `Launcher-Debug` build through `ci/labview.ps1`, exit code re-raised. Read-only: `permissions: contents: read`, no packaging, no publishing | **Active** (measured 8m31s for the job, run 80; the same spec builds in 276s on the maintainer's host) |
| **Lane 3 — fully automatic release** | **Self-hosted Windows runner** on Gitea (label `windows-labview26`; VM see `docs/vm-runner.md`) | Windows + LabVIEW 2026 + 4 NI runtimes + VIPM (18 dependencies) + Node ≥20; CI side also needs the repo secret `GH_RELEASE_TOKEN` | Triggered by `push: tags: ['v*']` (or `workflow_dispatch`) running `.gitea/workflows/release.yml`: probe → checkout → tag resolution → version check → build + package + dual-write release (evidence in the job log). **VI Analyzer and unit-test gates remain deferred** | **Active** (release + compile) / **Deferred** (the two remaining gates) |

## 3. CI checks (Lane 1)

### Trigger and environment (current state of `.gitea/workflows/verify.yml`)

- Triggers: `push` to `dev` or `main`; any `pull_request`. **Tag pushes do not trigger it** (filtered by branches) — tags go through Lane 3's `release.yml` (see "CI release (Lane 3)"); the two workflows do not overlap.
- Concurrency: `concurrency: {group: mica-ci, cancel-in-progress: false}`. `cancel-in-progress: false` only protects a run that is **already executing**; a run still **waiting in the queue** is cancelled and replaced when a newer run enters the same group. `dev` and `main` share that single group, so pushing either branch supersedes a run the other branch had queued for the same content. A stretch of consecutive `cancelled` verify runs therefore means "nothing was picked up yet" (an offline runner) plus normal queue replacement — it is not a gate failing. Measured 2026-09-21: runs 66-69 all ended `cancelled` while no runner was accepting jobs, and only the newest one (70, on `main`) then executed and passed.
- Permissions: `permissions: contents: read`. CI performs no writes end to end.
- Other: `timeout-minutes: 20`; `defaults.run.shell: bash`.

### Steps

1. **Node probe**: `node --version` (requires 18+). Missing or too old → immediate failure with a one-line fix: add the label `ubuntu-node20:docker://node:20-bookworm` to the runner and point `runs-on` at it (see the "Runner" section).
2. **checkout (bare git)**: a plain `git clone` with `http.extraHeader` auth (no marketplace actions anywhere — the runner cannot reach github.com), full history, checked out detached at the pushed commit. **Full history is required**: `ci/version.mjs` resolves the current tag with `git tag --points-at HEAD`; a shallow clone cannot see tags and would degrade the tag / CHANGELOG checks into SKIP (false green). The private-repo clone uses the job token Gitea issues automatically per job (`secrets.GITEA_TOKEN`, no manual secret needed).
3. **Workflow self-check (blocking)**: `node ci/tests/verify-workflow.check.mjs` — statically parses **the workflow files that were just checked out** and asserts their full contract (step order, both blocking checks in place verbatim, permissions, trigger/concurrency semantics, action-free shape, forbidden-write and platform lexical scans). It runs after checkout and before the other checks: **its purpose is "prevent anyone from breaking the workflow semantics"** — a commit that breaks the workflow goes red on the next push immediately, instead of silently changing what Lane 1 verifies. The checker can self-verify locally with `--selftest` (all mutants red + all benign controls green).
4. **Version consistency (blocking)**: `node ci/version.mjs check --json`; non-zero fails the run; the report is printed to the job log. Rules:
   - `package.json`'s `version` must be of the form `X.Y.Z`;
   - the three Launcher specs' (`Launcher-Debug` / `Launcher-Release` / `Launcher-Simulation`) `Bld_version.major/minor/patch` must match `package.json` (missing minor/patch participate in the comparison as 0; **the absence itself** is WARN without a tag, and FAIL with a tag or `--strict` — bootstrap-phase semantics); `Bld_version.build`, if present, must be an integer in 0..2147483647;
   - the `MICA Installer` spec's `INST_productVersion` must match `package.json`;
   - a `vX.Y.Z` tag on HEAD (if any) must match `package.json`; `CHANGELOG.md` must contain a `## [<tag>]` **or** `### [<tag>]` section (both level-2 and level-3 headings are accepted, see commit `04ee8a1`). **When HEAD has no tag (the normal state of everyday pushes), the tag and CHANGELOG items show SKIP, which is normal**: the rules only target "a tag visible on current HEAD"; combined with the full-history clone (all tags fetched), a tag that exists will always be visible and never falsely SKIP; the "shallow clone causes false SKIP" case described in step 2 is the anomaly to guard against;
   - Exit codes: `0` pass | `1` mismatch | `2` usage error | `3` write refused (dirty files) | `4` write/read-back failure (a read-only CI run normally only sees 0/1/2).
5. **Project integrity (blocking)**: `node ci/repo-integrity.mjs --strict --report .ci-logs/integrity-report.txt --json`; non-zero fails the run; the report and the JSON copy are printed to the job log. Five rules and severities:

| Rule | What it checks | Severity (in CI) |
| --- | --- | --- |
| (a) Orphan VIs | `.vi` files on disk that no `.lvlib` / `.lvclass` / `.lvproj` references (currently 17) | Full list is **reported only**; **new entries relative to the baseline** → exit 2 under `--strict` → **red** |
| (b) Referenced but missing `.vi` | A reference exists but the file is not on disk (currently 5, all in `cores/D-Y Map/D-Y Map.lvclass`; `.ctl` private-data references are a normal shape and out of scope) | Same as above |
| (c) Build-spec invariants | The 4 release specs (`Launcher-Release`, `Launcher-Simulation`, `Updater`, `MICA Installer`) exist; version properties complete; `Bld_autoIncrement` all false; `MICA Installer` has `SourceCount=2` and resolvable `Source[0..1]`; all XML in scan scope parseable | Any failure → exit 1 → **blocking** |
| (d) LabVIEW version consistency | `Lab_Super.lvproj`'s `LVVersion` ↔ `Lab_Super.dragon` ↔ `.dragon/settings.toml` all agree | Mismatch → exit 1 → **blocking** |
| (e) configs JSON | All `configs/**/*.json` (currently 64) must parse | Bad JSON → exit 1 → **blocking**; key-set differences vs the reference config are **reported only** (the repo has deliberate variants) |
| — | The checker itself cannot run (usage / internal error) | exit 3 → treat as an incident; fix the environment first, **do not count it as green** |

Baseline: `ci/integrity-baseline.json` (17 orphans + 5 missing). The red line for rules (a)(b) is **new entries relative to the baseline**; in-baseline entries only ever appear in the report. Rebuild the baseline with `node ci/repo-integrity.mjs --write-baseline` (rewrites the baseline file; always review the diff before committing).
6. **Report, not artifact**: the generated reports (`.ci-logs/version-report.json`, `.ci-logs/integrity-report.txt`, `.ci-logs/integrity-report.json`) are printed into the **job log** — the workflow uses no marketplace actions, so there is no artifact upload step. The log is available even when checks fail.

### What to do on failure

- First reproduce locally (commands in the next section); the FAIL lines in the report name files and line numbers.
- Version-consistency red: fix the offending fields per the report; prefer `node ci/version.mjs set <X.Y.Z>` for alignment — do not hand-edit the lvproj's indentation / formatting.
- (c) red: fix the lvproj or put `Bld_autoIncrement` back; note LabVIEW rewrites the project file when opened — after editing, confirm in the GUI that the project loads.
- (d) red: align the three LabVIEW version locations.
- (e) red: fix the JSON; key-set differences are advisories — confirm whether they are deliberate variants.
- (a)(b) new-entry red: prefer adding the reference / the file; only rebuild the baseline if the change is genuinely intended (e.g. a class path moved), and explain it in the PR.
- CI red but local green: confirm local HEAD matches the commit CI checked out, and that `git tag --points-at HEAD` agrees on both sides.

### How to reproduce the same checks locally (paste-ready)

Verbatim alignment with the CI steps (maintainer machine, pwsh; Git Bash works too):

```powershell
cd <repo>
New-Item -ItemType Directory -Force .ci-logs | Out-Null
node ci/version.mjs check --json > .ci-logs/version-report.json; Write-Host "version exit=$LASTEXITCODE"
node ci/repo-integrity.mjs --strict --report .ci-logs/integrity-report.txt --json > .ci-logs/integrity-report.json; Write-Host "integrity exit=$LASTEXITCODE"
```

Short form (daily use):

```powershell
node ci/version.mjs check
node ci/repo-integrity.mjs --strict
```

(Recorded 2026-09-16: `node ci/version.mjs check` and `node ci/repo-integrity.mjs --strict` both exit 0; the two "verbatim" commands above also exit 0, and the report files under `.ci-logs/` are generated normally. Without `--strict`, rules (a)(b) only report and never fail.)

`.ci-logs/`, `dist/`, `*.env` are ignored by `.gitignore`, so running checks / packaging locally does not dirty the working tree.

## 4. Local release sequence (Lane 2)

Run on the maintainer machine, from the repo root. The order of the whole chain is the contract — do not reorder. **The same chain can also run automatically on the VM runner via `release.yml`** (Lane 3, see "CI release (Lane 3)"): both paths run the same scripts, produce the same 4 assets, and have the same idempotency semantics; pick one for day-to-day releases, **never run both at once**.

### One command: `npm run bump-version`

Steps 1–5 and the step-5 self-check below are wrapped into a single command:

```powershell
npm run bump-version -- 1.1.0     # same as: node ci/release-prep.mjs 1.1.0
```

It is exactly the sequence documented below, automated with the same order and semantics — nothing else. It refuses to start (exit 2, with a hint naming the fix) unless: the version argument is a plain `X.Y.Z`; the current branch is `dev`; the worktree is completely clean (`git status --porcelain` empty — it never folds unrelated work into the release commit); the tag `vX.Y.Z` exists neither locally nor on `origin` (a failed/offline origin query only warns; an existing remote tag refuses — a released version is never re-released); and the local `auto-changelog` package is installed (`npm install` first if not). It then runs: version set → release commit (`chore(release): bump version to X.Y.Z`) → tag → auto-changelog → amend (changelog folded into the release commit) → re-point the tag → `node ci/version.mjs check --tag vX.Y.Z` as the final gate. Every step is announced before it runs; the first failure aborts non-zero, passes the failing step's exit code through, preserves the scene and prints the exact continuation commands (docs/ci.md section 4 steps apply by hand from there). `--skip-check` skips ONLY the final version-chain gate (a loud warning names the check to run manually); it never waives any preflight. There is no dry-run mode — the preflight refusals are the safe way to rehearse.

The command never pushes and never touches a remote ref (creating the tag locally is the maintainer's own explicit release action, the scripted counterpart of the manual `git tag` in step 3 — remote refs stay read-only until the push). The tag is created lightweight, like the manual sequence, so note for step 6: a single `git push origin dev --follow-tags` carries **annotated** tags only — push the tag explicitly:

```powershell
git push origin dev
git push origin vX.Y.Z
```

Once the tag lands, `release.yml` takes over (Lane 3). The step-by-step sequence below is kept unchanged as the reference for what the command does and why each step exists.

### Prerelease (`rc`) rehearsals are outside that command

`bump-version` and `version.mjs set` accept a bare `X.Y.Z` only (both gate on the same `VERSION_RE`), so a `vX.Y.Z-rc.N` rehearsal cannot go through them. The manual sequence is short because a prerelease deliberately carries the version of the stable release it precedes: the version chain does not move, only the tag and the CHANGELOG heading do. Verified end to end on 2026-09-21 with `v1.0.0-rc.2` (Lane 3 run 71, 3 assets, Gitea only):

```powershell
git switch dev                                  # same preflight as usual: worktree clean, on dev
git commit --allow-empty -m "chore(release): bootstrap the v1.0.0-rc.N rehearsal"
git tag v1.0.0-rc.N                             # must exist before the changelog runs
npm run auto-changelog                          # writes the "### [v1.0.0-rc.N]" section rule 4 wants
git add CHANGELOG.md
git commit --amend --no-edit                    # fold the changelog into the rehearsal commit
git tag -f v1.0.0-rc.N                          # re-point the tag at the amended commit
node ci/version.mjs check --tag v1.0.0-rc.N     # the final gate; must exit 0
git push origin dev                             # push ONLY after the amend and the re-tag
git push origin v1.0.0-rc.N
```

What actually matters here:

- **Nothing is pushed until the amend and `tag -f` are done.** Pushing the pre-amend commit and rewriting it afterwards is a history rewrite on a shared branch — precisely what this sequence must never do.
- Rule 3 compares only the tag's `X.Y.Z` base, so `v1.0.0-rc.2` passes against a `1.0.0` `package.json` with no version edits at all; rule 4 wants the literal `### [v1.0.0-rc.N]` heading, which is why the tag has to exist before `auto-changelog` runs.
- `auto-changelog` sorts a prerelease *below* the stable release it precedes, so the section lands under `## [v1.0.0]` and that release's compare link is rewritten to `v1.0.0-rc.N...v1.0.0`. Odd to read, proven harmless — `rc.1` produced the same shape and published correctly.
- A prerelease tag publishes to **Gitea only** and its installer policy never packages the installer, so an `rc` rehearsal exercises the whole Lane 3 chain without touching the public repository. That is what makes it the cheap end-to-end check after any change to the release path.

**Step 0 (recommended pre-step): compile confirmation.** The build has been stripped out of CI, so this is the only compile signal before a release:

```powershell
pwsh -File ci/labview.ps1 -BuildSpec Launcher-Debug
```

Expected: LabVIEWCLI runs step by step, logs land in `.ci-logs/`; success exits 0. Common failures and recovery are in "Troubleshooting".

**Step 1: generate the CHANGELOG.**

```powershell
npm run auto-changelog     # run npm install first if needed
```

Expected: `CHANGELOG.md` updated; unreleased commits first land in the `### [Unreleased]` section.

**Step 2: align versions.**

```powershell
node ci/version.mjs set <X.Y.Z>
```

Preconditions: no uncommitted changes in `package.json` / `Lab_Super.lvproj` (otherwise exit 3; `--force` overrides). Expected output: `== MICA version set -> X.Y.Z ==`, a `[WRITE]`/`[NOOP]` line per file, and a final `verify: re-read OK — ...`, exit 0. This writes `package.json`'s `version`, the three Launcher specs' `Bld_version.major/minor/patch` (missing properties are inserted in place) and `MICA Installer.INST_productVersion`; **the Updater and 6 tool EXE specs are excluded** and verified byte-identical.

**Step 3: commit and tag.**

```powershell
git add -A
git commit -m "chore(release): vX.Y.Z"
git tag vX.Y.Z
```

Tags are always created manually by the maintainer — no script ever creates tags. Preview / pre-release versions use a tag with `-` (e.g. `v1.1.0-rc.1`); those are automatically marked prerelease (see below).

**Step 4: get the version section into the CHANGELOG (common pitfall).**

`auto-changelog` only assigns commits to the `[vX.Y.Z]` section once the tag exists; and it emits a level-2 heading `## ` only for semver-major versions, and `### ` for minor / patch versions. Rule 4 of `ci/version.mjs` (which validates the CHANGELOG section against the tag resolved via `git tag`; `release-local.ps1`'s preflight self-check calls exactly this) **accepts both level-2 and level-3 headings** — `## [vX.Y.Z]` or `### [vX.Y.Z]` both work (see commit `04ee8a1`). So, **only while the commit and the tag have never been pushed**:

```powershell
npm run auto-changelog     # tag exists now: generates/refreshes the [vX.Y.Z] section
# keep the section heading exactly as auto-changelog produced it (major → "## [vX.Y.Z](...)", minor/patch → "### [vX.Y.Z](...)")
git add -A
git commit --amend --no-edit    # fold the changelog update into the release commit (never-pushed only)
git tag -f vX.Y.Z               # re-point the tag at the amended commit (never-pushed only)
```

Alternatively skip the regeneration and hand-edit the `Unreleased` section into `## [vX.Y.Z](https://gitea.sevenology.top/MICA/MICA/compare/v<prev>...vX.Y.Z) -  <date> ` (or a `### ` level-3 heading) before committing. Either way works; **the only hard requirement** is that before tagging, `CHANGELOG.md` already contains a line starting with `## [vX.Y.Z]` or `### [vX.Y.Z]` (the bracket must contain the exact tag; `### [Unreleased]` does not count).

**Step 5: pre-release self-check (the same check release-local runs as its step 1).**

```powershell
node ci/version.mjs check --tag vX.Y.Z
```

Expected exit 0. On failure `release-local.ps1` aborts early with exit 4.

**Step 6: push.**

```powershell
git push origin dev
git push origin vX.Y.Z
```

(The GitHub-side release's `target_commitish` points at that commit and must be reachable.)

**Step 7: release.**

```powershell
pwsh -File ci/release-local.ps1 -Tag vX.Y.Z
```

Preconditions (hard-verified in the script's step 1): the tag exists and **`HEAD` == tag**; **tracked files** clean (untracked files are deliberately ignored; `dist/`, `builds/`, `.ci-logs/`, `.omz/` do not block); `node ci/version.mjs check --tag` passes; both tokens available — **environment variables win** (`GITEA_TOKEN` / `GITHUB_TOKEN`); the `ci/release.env` file is read only when the environment variable is absent (the local norm, see the "Credentials" section).

Expected flow ([1/4]→[4/4]): preflight → clear `builds/` then build in fixed order `Launcher-Release → Launcher-Simulation → Updater → MICA Installer` → package 4 zips into `dist/` → publish to each endpoint in turn (Gitea first, then GitHub): find the release by tag (create a **draft** if absent) → for an existing release apply the public-state-preserving differential treatment (see "Rerun semantics and operating discipline") → upload 4 assets → verify the remote asset count and byte sizes match local (on mismatch the public state is not changed and the exit is non-zero — draft stays draft, published stays published) → PATCH to promote (an idempotent no-op for already-published ones) → print the release URL.

Exit codes: `0` success | `1` run failure (build / package non-zero codes pass through) | `2` configuration error (tag/slug/version format, env file, missing token or assets) | `3` precondition invariant (tag missing / tag != HEAD / tracked files dirty) | `4` version-chain check failed | `5` concurrency lock held (another release is running).

Common switches (full parameters: `pwsh -File ci/release-local.ps1 -?`):

- `-Prerelease`: force prerelease; **any tag containing `-` is automatically prerelease** (e.g. `v1.1.0-rc.1`) — `releases/latest` skips drafts and prereleases, so end users are never pointed at a pre-release.
- `-SkipGithub` / `-SkipGitea`: publish to a single endpoint only.
- `-SkipBuild` / `-SkipPackage`: reuse existing build / package outputs.
- `-AssetsDir <dir>`: directory for the 4 zips (default `dist/`).
- `-EnvFile <path>`: credentials file (default `ci/release.env`).
- `-ForceRepublish`: only when explicitly requested, re-enter the draft-recovery loop (PATCH back to draft → delete same-name assets → re-upload → verify → promote). By default **an already-published release is never pulled back to draft**.

### Rerun semantics (idempotency) and operating discipline

- **No release / draft release**: the full recovery loop runs — PATCH back to `draft:true`, delete same-name old assets, re-upload the 4, verify, promote. A half-set of assets never becomes public (drafts are invisible to `releases/latest` and to downloaders).
- **Already-published release**: the script **does not pull it back to draft** and does not bulk-clear its assets. Same-name assets are replaced one by one (delete that asset, then upload the new file; a single asset is briefly missing mid-replacement, but the release stays public and `releases/latest` never regresses); if verification fails, the public state is unchanged (still published) and the exit is non-zero. To force the draft-recovery loop, pass `-ForceRepublish` explicitly.
- **Do not run concurrently (a cross-process lock backs this up)**: on startup `ci/release-local.ps1` takes a **local lock file** `%TEMP%\mica-release.lock` (content: holding PID + start timestamp; the handle is held with exclusive write until the script ends). While a release is running, a second instance **fails fast with exit code 5**, printing the holding process's info — just rerun the same command later. A **stale lock** left by a force-killed process / power loss (PID no longer exists) is **automatically taken over** on the next run; the lock is released by `try/finally` on all exit paths (verified for success and every failure exit code). The two APIs remain last-writer-wins; the lock only guarantees **same-machine** serialization — one instance on each of two machines still interferes, so the discipline stands: publishing / rerunning the same tag must be **serial**; after an interruption just rerun the same command and it converges.

### Release assets (frozen — names and structure must not change)

| Asset | Source | Structure inside the zip |
| --- | --- | --- |
| `Launcher-Release.zip` | `builds/Launcher-Release/` | Content at the zip root (`Launcher.exe` is the marker file) |
| `Launcher-Simulation.zip` | `builds/Launcher-Simulation/` | Same |
| `Updater.zip` | `builds/Updater/` | Content at the zip root (`Updater.exe` is the marker file) |
| `MICA.Installer.zip` | `builds/MICA Installer/Volume/**` | **Every entry starts with `Volume/`** (a top-level `Volume/` wrapper; `Volume/install.exe` is the marker file) |

Why frozen: the in-app updater (`utility/Get Latest Release Info.vi`) requests `api.github.com/repos/mica-home/MICA/releases/latest` and picks the update package by filtering asset names against the **regex literal `release`** — renaming breaks the updater's asset lookup; the Gitea repo is private so end users cannot download from Gitea, hence **the dual write must stay** (the GitHub side is the end-user update channel). If `MICA.Installer.zip` loses the top-level `Volume/` wrapper, `ci/package.ps1` fails packaging outright (it asserts the structure) — do not try to "fix" that wrapper.

Also: `ci/release-local.ps1` sets the release title = tag and uploads the tag's CHANGELOG section as the release body — **verbatim to Gitea**, and for GitHub run through a sanitizer that re-points compare links at the GitHub slug, strips other private-host links, and **refuses to publish a body that still carries the private address** (leak guard: the scheme-qualified web base in any casing, plus the bare host name when the GitHub web base sits on a different host). The guard runs both when a release is created and again at publish time (the publish PATCH re-applies the sanitized body), so a release reused from an earlier run or edited by hand is covered too; when no CHANGELOG section exists to rebuild from, the stored body is cleaned and published back, and the guard refuses if anything survives.

## 5. CI release (Lane 3, self-hosted Windows runner)

`.gitea/workflows/release.yml` runs the **full build → package → dual-write release** on the VM runner, **equivalent** to section 4 (local `ci/release-local.ps1`): both paths run the same scripts (`ci/labview.ps1` → `ci/package.ps1` → `ci/release-local.ps1`), the same 4 frozen assets, and the same idempotency and asset-verification semantics. For day-to-day releases pick one; **never run both at once** (the two APIs are last-writer-wins; `release-local.ps1`'s local lock only guarantees **same-machine** serialization).

### Triggers (two, resolving to the same tag)

| Trigger | Tag value | Use |
| --- | --- | --- |
| `push` of a tag matching `v*` | `github.ref_name` | Primary path |
| `workflow_dispatch` (manual, required `inputs.tag`) | `inputs.tag` (**the tag must already exist**) | Re-release / rerun; empty input or a non-`vX.Y.Z` value fails before the build, no ref guessing. Two extra optional inputs: `installer` (`auto` \| `always` \| `never`, default `auto` — the minor-release installer policy, section 4) and `force_github` (`true` publishes a prerelease tag to GitHub too; default `false`, so a tag with a `-` suffix publishes to Gitea only) |

**Tags are still created manually by the maintainer** (`git tag vX.Y.Z`, section 4 step 3): the workflow performs **no repository writes** except what publishing requires (`permissions: contents: write`, needed for the release API); no step commits / tags / moves refs.

### Environment and concurrency

- `runs-on: windows-labview26`: a **self-hosted Windows runner** on Gitea (registration label `windows-labview26:host`, capacity 1). For the VM specs, install checklist, licensing and registration see **`docs/vm-runner.md`**. **When the runner is offline, jobs queue (they are not lost)**: Gitea holds jobs matching that label and hands them over once the runner is back (provided the job timeout window has not passed).
- `concurrency: {group: mica-release, cancel-in-progress: false}`: a new run in the group **queues** rather than cancelling the running one — cancelling a release mid-flight would leave a draft release behind.
- `timeout-minutes: 240` (hang protection, not the expected duration); `defaults.run.shell: pwsh` (the runner host needs pwsh installed).
- **The workflow uses no marketplace actions** (the runner cannot reach github.com): every step is a plain shell command, checkout included. Evidence therefore lives in the **job log**, not in uploaded artifacts — this is deliberate, not a missing artifact step.

### Steps (5)

1. **Node probe**: `node --version`; no Node on the runner host → immediate failure with fix instructions (`docs/vm-runner.md` section 5, step 4).
2. **checkout (bare git)**: a plain `git clone` (with header auth from the injected job token) of the requested ref, full history, checked out detached — `ci/version.mjs` resolves tags via git, and `release-local.ps1` also requires the tag to exist and point at HEAD (the detached checkout naturally satisfies this).
3. **resolve tag (blocking)**: collapses the two triggers into one `RELEASE_TAG`, exported to later steps via `GITHUB_ENV`; empty input / malformed tag / runner not exporting `GITHUB_ENV` all fail before the build.
4. **Version consistency (blocking)**: `node ci/version.mjs check --tag <tag> --json` (same rules as section 3 step 4, plus the tag); the report is printed to the job log.
5. **publish (blocking)**: `pwsh -NoProfile -NonInteractive -File ci/release-local.ps1 -Tag <tag> [-Installer <policy>] [-ForceGithub]` — preflight → build → package → dual-write. Exit-code semantics in section 4 (including `5 = concurrency lock held`; unlikely on a single runner).

Failure handling: the workflow and `release-local.ps1` are both idempotent — **rerunning the same run (or re-dispatching for the same tag) converges**; a half-set of assets is never treated as complete. Start troubleshooting from the job log of the failing step (the publish step prints the full `release-local.ps1` output, including the version report).

### One-time in-VM bootstrap: `ci/bootstrap-deps.ps1`

After the VM has LabVIEW → the 4 NI runtimes → VIPM → Node ≥20 installed in the order of section 5 of `docs/vm-runner.md`, use the in-repo script to bootstrap the 18 VIPM dependencies **and assert that all are installed** ("half-installed and assumed done" exits non-zero and names the missing package ids):

```powershell
# inside the VM, at the repo working-copy root
pwsh -NoProfile -File ci/bootstrap-deps.ps1              # install + verify (idempotent, safe to rerun)
pwsh -NoProfile -File ci/bootstrap-deps.ps1 -VerifyOnly  # read-only verification: no install
```

- Parameters: `-DragonFile` (default `<repo>/Lab_Super.dragon`, the **single source of truth** for the 18 ids), `-VipmPath` (default VIPM's standard install path), `-LabViewVersion` / `-LabViewPath`, `-SkipNipm` (install the VIPM part only; forwards `vipm install --vipm`), `-VerifyOnly`.
- Exit codes: `0` all verifications passed | `2` preconditions unmet (missing VIPM CLI / no or empty `[vipm.dependencies]` in the dragon / missing LabVIEW / Node < 20) | `3` install failed or timed out (including watchdog kills) | `4` verification failed (list unreadable, or **packages still missing after install** — missing ids are listed).
- It only runs `vipm install -y --labview-version <ver> <dragon>` and `vipm list --installed`; it **never removes / cleans / upgrades**, writes no repo files, and reruns are idempotent. For the 4 NI runtimes it performs only a **soft check** (missing ones only warn and list — they are needed by the Installer spec packaging; the warning names the authoritative reconciliation command `nipkg list --installed`).
- Self-test: `pwsh -NoProfile -File ci/tests/bootstrap-deps.tests.ps1` (stub-driven, **never calls real VIPM**).
- Next step: `pwsh -NoProfile -File ci/runner/setup-runner.ps1 -ServiceTask` (register the runner, see `docs/vm-runner.md` section 7).

## 6. Credentials

### Resolution order (**environment variables first**; the order itself is the contract)

For each publishing platform, `ci/release-local.ps1` takes the token in this order:

1. **Environment variables**: `GITEA_TOKEN` / `GITHUB_TOKEN`. **This is the CI path** — `release.yml`'s publish step injects both tokens as plain environment variables; the runner's checkout contains and needs no credentials file.
2. **`-EnvFile` file** (default `ci/release.env`): opened only when the environment variable did not provide that key. So CI **never reads** `ci/release.env`, and a stale / incomplete local file cannot affect CI runs.

Where the two tokens come from and how they map in CI:

| Platform | Source | Mapped to the variable the script reads |
| --- | --- | --- |
| Gitea | the job token Gitea **injects automatically** per job (`secrets.GITEA_TOKEN`; `checkout` uses the same one, no manual secret needed) | `GITEA_TOKEN` |
| GitHub | repo secret **`GH_RELEASE_TOKEN`** (fine-grained PAT or classic PAT, permissions in the table below) | `GITHUB_TOKEN` (explicitly mapped to that name in `release.yml`) |

The script only prints **key names and sources** (like `credentials: GITEA_TOKEN<-env, GITHUB_TOKEN<-env`), **never echoes values**, and never writes values into any file. Documentation, the repo and CI logs always use placeholders (like `<your-token>`); **never write real tokens**.

### Storage location and format (local path)

- File: `ci/release.env` (`release-local.ps1`'s default `-EnvFile`, **for local releases**; CI does not need it; **already ignored by `.gitignore`**).
- Self-check (should print one matching rule; no output = rule missing — fix `.gitignore` first, then create the file):

```powershell
git check-ignore -v ci/release.env
# expected shape:  .gitignore:43:*.env	ci/release.env
```

- Format: `KEY=value` per line; blank lines and whole-line `#` comments allowed; **values are not quoted** (the script does no quote parsing; it splits at the first `=` and Trims the right side); inline `#` comments are not supported. Key names must match `^[A-Za-z_][A-Za-z0-9_]*$`.
- Two keys: `GITEA_TOKEN`, `GITHUB_TOKEN`. The script never echoes token values (only key names). **No token value may ever be written into this document, the repo, or CI logs.**

### The two tokens and least privilege

| Platform | Purpose | Least privilege |
| --- | --- | --- |
| Gitea (`gitea.sevenology.top`, private repo `MICA/MICA`) | create release + upload 4 assets (header `Authorization: token <your-token>`) | User Settings → Applications → Generate New Token, scope **`write:repository`** (releases are part of repository; Gitea has no separate release scope) |
| GitHub (public repo `mica-home/MICA`) | create release + upload 4 assets for the in-app updater | fine-grained PAT: **Contents = Read and write**; classic PAT: `public_repo` |

### Proving write permission (do this once after configuring tokens)

On each endpoint **create a temporary prerelease and delete it** (simplest in the UI; API also works):

- Gitea: `POST /api/v1/repos/MICA/MICA/releases` (body like `{"tag_name":"v0.0.0-permcheck","name":"permcheck","prerelease":true}`) → confirm creation → `DELETE .../releases/<id>`. Note the Gitea API registers the temporary tag; if the tag lingers after deleting the release, delete it too (Delete tag in the UI).
- GitHub: `POST /repos/mica-home/MICA/releases` (same `tag_name`, `prerelease:true`) → confirm creation → `DELETE /repos/mica-home/MICA/releases/<id>`.

Successful creation proves the token has write permission; clean up afterwards (no leftover temporary tags / releases).

### Expiry and rotation

1. Generate a new token on the platform (same permissions as above);
2. Update where the token is stored: the matching key in the local `ci/release.env`, and the CI-side repo secret (`GH_RELEASE_TOKEN`; the Gitea side needs no rotation — it uses Gitea's auto-issued job token);
3. Rerun the "prove write permission" check once;
4. Revoke the old token (Gitea → Applications; GitHub → Settings → Developer settings → Tokens);
5. Record the expiry date (GitHub PATs expire; set and record an expiry for Gitea tokens too).

### Risk notes

- Plaintext env files are an **accepted risk**: same-user processes and local admins can read them; neither the repo nor CI ever stores tokens.
- On Windows that accepted risk is wider than the sentence above suggests, so measure it rather than assume: `icacls ci\vm.env` was observed to inherit **`BUILTIN\Users:(I)(F)`**, i.e. every local standard user can both read *and rewrite* the file — and rewriting a token file feeds the attacker's value into the release path, which is worse than reading one. Tighten the two files that hold credentials (an elevated shell; repeat after recreating them):

```powershell
icacls ci\vm.env /inheritance:r /grant:r "$env:USERNAME:F" /grant SYSTEM:F
icacls ci\release.env /inheritance:r /grant:r "$env:USERNAME:F" /grant SYSTEM:F   # when it exists
```

- Parsing details (matching `ci/release-local.ps1`'s implementation): split each line at the **first** `=`, key on the left, value on the right; leading/trailing whitespace of values is Trimmed, so **do not put leading / trailing spaces inside values**; do not quote values (quotes become part of the value).

## 7. Recovery manual

**General principle: every failure of `release-local.ps1` converges by "rerunning the same command" (idempotent). The tag is the release anchor — never move a tag silently. The published asset set for a given tag is sticky**: the installer policy skips the tag being released and any prerelease, comparing against the previous **stable** release, so a rerun resolves the same policy the first run used (a minor release keeps its installer, a patch release stays at three assets). Known limitation: rerunning an **older** stable tag *after* a newer release in the same major.minor has landed re-evaluates the policy and can report an asset-set mismatch (`expected exactly N assets, found M`) — this is fail-closed and the message names the choices; recover with `-Installer always`, or bring the released asset set in line by hand.

| Situation | Handling |
| --- | --- |
| **Tag exists, want to re-release** | Rerun `pwsh -File ci/release-local.ps1 -Tag vX.Y.Z`: the script finds the existing release by tag and reuses its id; a draft release goes back to draft, then same-name assets are replaced one by one; a published release stays public with same-name assets deleted-then-uploaded; verified, then promoted (a no-op for already-published ones). Add `-ForceRepublish` to force the draft-recovery loop. **Do not** move / re-create an already-pushed tag to re-release. To change content, change the version number or add a `-rc.n`-style prerelease suffix (new tag). |
| **Assets partially uploaded** | Rerun the same command. A draft release is PATCHed back to draft, then same-name assets are deleted and re-uploaded one by one; a published release **does not go back to draft** and its same-name assets are replaced one by one (stays public); if count / size verification fails, the release keeps its original public state (draft stays draft, published stays published) and the exit is non-zero (a half-set is never treated as complete, nor does a public release disappear). On rerun each endpoint converges independently. |
| **Script interrupted (Ctrl-C / network drop)** | Just rerun. Gitea / GitHub side: a draft or half-asset release is reused, cleaned up, completed; a published release is never pulled back to draft (stays public; same-name assets are completed one by one on the next rerun). Local: `builds/` is rebuilt before the build; `.pkg-tmp-*` debris in `dist/` is auto-cleaned by `ci/package.ps1` on next start. |
| **One endpoint succeeded, one failed** | Rerun (the successful endpoint reuses idempotently); or `-SkipGitea` / `-SkipGithub` to fill in only the failed endpoint. |
| **Exit code 5 (concurrency lock held)** | Another `release-local.ps1` instance is running on this machine (the message names the holding PID and the lock path `%TEMP%\mica-release.lock`). Wait for it to finish, then rerun the same command. If the holding process is truly dead (PID gone), no manual unlock is needed — the next run takes over the stale lock; delete the lock file manually only if it is wedged by a foreign tool holding it exclusively. |
| **A pushed tag is wrong** | Cannot be moved silently. Delete the release on both endpoints (or keep the release record with a note), then re-release with a new tag; deleting a remote tag is destructive and requires explicit confirmation first. |
| **`release.yml` (Lane 3) is red** | Read the failing step's output in the **job log** (the publish step prints the full release output). Handle version-chain problems per the rows above (**a pushed tag cannot be moved silently**; changed content needs a new tag); for a failed release step, match the exit code against this table and rerun **the same run** (or re-`workflow_dispatch` for the same tag) — idempotent convergence. |
| **Runner offline** | The job stays queued (**not lost**, including Lane 3 tag releases). Check the runner's online state and labels on Gitea's Runners page — Lane 1 is the Linux runner (`ubuntu-latest`), Lane 3 the self-hosted Windows runner (label `windows-labview26:host`, VM-side troubleshooting in `docs/vm-runner.md`); once recovered, Re-run the failed / queued run from the Actions page. |
| **CI queue backlog** | The `concurrency` group `mica-ci` with `cancel-in-progress: false` is the intended semantics: new runs queue rather than cancel each other. Handling: cancel stale runs on the Actions page, or Re-run on the latest commit. **Do not** flip `cancel-in-progress` to true on your own (it would cancel running checks mid-flight). |

**Recovery-only switches**: `-SkipBuild -SkipPackage -AssetsDir <dir>` publishes pre-packaged zips from `<dir>`. In that path the packaging freshness assertion (`ci/package.ps1 -NotBefore`) does **not** run, and asset verification compares the remote sizes against those local files only — so the zips must be the ones built from the tag's commit. Use it to re-upload the exact files of a previous run; never to publish artifacts of unknown origin.

## 8. Troubleshooting

- **VI Server port is not the default**: the local port is **3364** (not the default 3363). `ci/labview.ps1` reads `server.tcp.port` from `LabVIEW.ini` in the same directory as `LabVIEW.exe` (`-PortNumber` overrides explicitly); if unresolvable it errors out (exit 2) and prints the ini path — it **never guesses the default port**, and no script / document may hard-code 3363. To inspect:

  ```powershell
  Select-String server.tcp.port "C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.ini"
  # expected:  server.tcp.port=3364
  ```

- **The port is held by someone else's LabVIEW**: the script checks port ownership before building; if held it exits 3, printing the owning process name / PID / source, plus the recovery hint **`taskkill /IM LabVIEW.exe`** (close that instance first and rerun; or use `-PortNumber` on another port). Reason: LabVIEWCLI attaches to an existing instance, and the script's subsequent CloseLabVIEW would kill that interactive session.
- **Do not use LabVIEW interactively during a build**: it causes port conflicts, file locks, build failures. The script only closes instances **it started itself**; `-NoClose` keeps the instance alive.
- **The working tree should be clean after a build**: the script backs up the lvproj before building; afterwards, if LabVIEW rewrote the project, **only** `Bld_version.*` / `Bld_autoIncrement` line diffs are automatically reverted; any other diff is refused with exit 4 (scene and backup preserved, manual handling required). In the normal state (`Bld_autoIncrement` all false), `git status` should show no tracked-file changes after a build.
- **Empty or missing `.ci-logs/` and `dist/` is normal**: both are generated directories (gitignored). `.ci-logs/` holds LabVIEWCLI step logs and local check reports; `dist/` holds the 4 packaged zips.
- **CI red on version consistency**: read the FAIL lines in the job log (the version step prints its report), or run `node ci/version.mjs check` locally.
- **CI red on project integrity**: read the named rule in the report; for new orphans / missing references prefer fixing the code; rebuild the baseline only for genuinely intended changes.
- **`release.yml` (Lane 3) red**: first read the failing step's output in the job log (the publish step prints the full release output), match the exit code against the section 4 table; "queued" due to a runner being offline is not a failure (see section 7, "Runner offline"). For VM-side build / port / snapshot problems see `docs/vm-runner.md` section 9.
- **`bootstrap-deps.ps1` verification red (missing packages)**: the output names the missing package ids — just rerun the same command (idempotent), or manually `vipm.exe install --labview-version 2026 <id>`; if the printed list looks like display names rather than ids, that is a tool output-format change — **do not** count it as a pass. `[vipm.dependencies]` defaults to an 18-item tripwire; changing the dependency list requires updating `-ExpectedPackageCount`, `packages/VIPM Package List.txt` and `docs/vm-runner.md` in sync.
- **Node probe failure (runner image has no Node)**: add the label `ubuntu-node20:docker://node:20-bookworm` to the runner and change the workflow's `runs-on` to `ubuntu-node20` (only that one line).
- **First push may show (a)(b) report items**: in-baseline entries only report, never fail; only "new" entries are red.
- **Local self-test tools** (optional; exit 0 = pass, see each file's header comment): `node ci/tests/verify-workflow.check.mjs` (static workflow verification), `node ci/tests/version.test.mjs`, `node ci/tests/integrity.test.mjs`; `pwsh -NoProfile -File ci/tests/labview.tests.ps1`, `pwsh -NoProfile -File ci/tests/package.tests.ps1`, `pwsh -NoProfile -File ci/tests/release-local.tests.ps1`, `pwsh -NoProfile -File ci/tests/bootstrap-deps.tests.ps1` (VIPM dependency bootstrap; **stub-driven, no real VIPM**).

## 9. Runner

- **Lane 1 reuses an existing Linux runner on Gitea; none is created**. The workflow has `runs-on: ubuntu-latest`.
- Gitea's matching semantics: **with no matching label, jobs still execute**, just on the default image `docker.gitea.com/runner-images:ubuntu-latest` — so `ubuntu-latest` runs on any Linux runner (avoid `windows-*`-style names, which could be mistaken for the default).
- **Only if the image lacks Node**: add one label to the existing runner, `ubuntu-node20:docker://node:20-bookworm` (cheaper than re-registering), then change the workflow's `runs-on` to `ubuntu-node20`. A runner's labels / mode / scope are visible on Gitea's repo / org / instance Runners pages; confirm it covers `MICA/MICA`.
- **If the runner labels change later, change only the workflow's `runs-on` line** (the first step's Node probe fails fast when Node is missing and prints the same fix hint).
- The `GITEA_TOKEN` used by checkout of a private repo is the job token Gitea **issues automatically** (no manual secret needed); its permissions are clamped by the workflow's `permissions: contents: read` and the repo-level ceiling.
- **Lane 3 uses a different Windows runner**: a Windows VM on a host machine (**specs, install checklist, licensing, snapshots and registration steps are all in `docs/vm-runner.md`**), registered label `windows-labview26:host`, capacity 1 — `release.yml`'s `runs-on: windows-labview26` matches that label exactly. One-time in-VM bootstrap: `ci/bootstrap-deps.ps1` (VIPM deps) → `ci/runner/setup-runner.ps1` (registration); **jobs matching it queue while the runner is offline and are not lost** (Gitea holds them; the runner picks them up when back online). **Do not** write Windows jobs' `runs-on` as a `windows-*`-style name and hand them to a Linux runner (see the matching semantics above).

## 10. Deferred items (the not-yet-live parts of Lane 3)

Lane 3's **release part is live** (2026-09-17): on the VM runner, `.gitea/workflows/release.yml` runs the tag-triggered build → package → dual-write release (see "CI release (Lane 3)"). The **compile gate went live on 2026-09-24** (`.gitea/workflows/compile.yml`, first green run 80), so the table below holds only the two remaining LabVIEW gates — they are a separate matter from "release"; do not assume a gate is open because releases work.

| Deferred item | Prerequisites to enable | Reuse when enabling |
| --- | --- | --- |
| VI Analyzer gate (`RunVIAnalyzer`) | runner ready (`windows-labview26`); plus export a config once via the GUI first (ensure no machine-absolute paths) | reuse `ci/labview.ps1`; needs a new cfg |
| Unit-test gate (`RunUnitTests`, 3 `.lvtest` not attached to projects) | same; plus spike-verify the invocation contract and failure exit-code semantics first (add a report→exit-code shim if necessary) | reuse `ci/labview.ps1` |

Already live (kept here for reference — do not treat as deferred):

| Live item | Shape | Notes |
| --- | --- | --- |
| Compile gate (`Launcher-Debug` build on every `dev` push and pull request) | `.gitea/workflows/compile.yml` (3 steps, action-free, `runs-on: windows-labview26`, `concurrency: mica-compile` with `cancel-in-progress: false`, `permissions: contents: read`) | reuses `ci/labview.ps1` unchanged; `build_spec` dispatch input defaults to `Launcher-Debug` and is also the way to watch the gate fail without touching source. Bounds come from measurement: the job takes 8m31s on the runner (run 80), the spec builds in 276s on the host, so `CI_STEP_TIMEOUT_SEC: 1200` sits inside `timeout-minutes: 25` — the script must be the guard that fires first, because a platform cancellation can leave LabVIEW holding the VI Server port and every later run then refuses with exit 3. `main` is deliberately not a trigger: the release sequence pushes `dev` and fast-forwards `main` to the same commit, so a `main` trigger would compile identical content twice on a capacity-1 runner. |

| Live item | Shape | Notes |
| --- | --- | --- |
| Tag-triggered full build + CI-side dual-write release | `.gitea/workflows/release.yml` (5 steps, action-free, `runs-on: windows-labview26`, `concurrency: mica-release`) | reuses `ci/package.ps1` and `ci/release-local.ps1`; tokens via environment variables (`GH_RELEASE_TOKEN` → `GITHUB_TOKEN`); evidence in the job log |
| Windows runner decision (local machine vs host Windows VM) | **Decision: a Windows VM on the host**, all evidence and the ops manual live in `docs/vm-runner.md` | registration script `ci/runner/setup-runner.ps1` (label `windows-labview26:host`, capacity 1) |
| In-VM dependency bootstrap | `ci/bootstrap-deps.ps1` (install + assert all 18 vipm ids present; idempotent, with timeout and watchdog) | self-test `ci/tests/bootstrap-deps.tests.ps1` (stub-driven) |

**Build / package / release now have two equivalent paths**: A) automatically on the VM runner via `release.yml` (tag-triggered or manual dispatch); B) locally `pwsh -File ci/release-local.ps1 -Tag vX.Y.Z` (the manual sequence in section 4). Both run the same scripts and the same asset contract; **never run both at once** (last-writer-wins on both APIs; the local lock only serializes one machine).

## 11. Change log

- 2026-09-24 (compile gate goes live): (1) new `.gitea/workflows/compile.yml` builds `Launcher-Debug` through `ci/labview.ps1` on the `windows-labview26` runner for every `dev` push and pull request, read-only and action-free, with a `build_spec` dispatch input whose default is the whole point of the red control; first green is run 80 (8m31s on the runner). (2) `ci/tests/verify-workflow.check.mjs` gained a third expectation set (92 assertions) plus 26 mutants and 4 controls, so a bad edit to the gate turns Lane 1 red on the next push like the other two files; two assertions encode load-bearing ordering — `cancel-in-progress: false` (a cancelled build can strand the VI Server port) and `timeout-minutes` exceeding `CI_STEP_TIMEOUT_SEC` by at least two minutes (the script, not the platform, must kill LabVIEW). (3) The selftest now LF-normalises the file under test: this repository has no `.gitattributes` and `core.autocrlf=true` on Windows, so the same committed bytes can check out as CRLF and every multi-line mutation anchor would fail for a reason that has nothing to do with the pipeline. (4) `docs/vm-runner.md` 7.4 keeps only the generic runner-state recipe; a diagnosis of one particular host's network stays in the maintainer's local notes.
- 2026-09-24 (documentation of what the 2026-09-21 rehearsal actually proved): (1) section 3's concurrency sentence was wrong and is corrected — `cancel-in-progress: false` protects only an **executing** run, a **queued** one is superseded by the next run in the group, and `dev`/`main` share the single group `mica-ci`, so consecutive `cancelled` verify runs mean "no runner picked anything up", not "a gate failed"; (2) section 4 gained the prerelease (`rc`) rehearsal sequence, needed because `bump-version` and `version.mjs set` accept a bare `X.Y.Z` only — the sequence was validated by `v1.0.0-rc.2` on Lane 3 (Gitea-only, 3 assets, each re-downloaded and byte-length verified); (3) section 6 risk notes now record the measured `icacls` inheritance on the credential env files (`BUILTIN\Users:(I)(F)` — readable *and rewritable* by any local standard user) and the command to tighten it; (4) `docs/vm-runner.md` gained 7.4 on host-side VM startup: the three `ci/vm.env` keys and where to read them off, the no-quotes rule, verifying without a reboot, the fact that **no script in this repository registers `MicaVmAutostart`**, and why `ping <guest-ip>` is not a readiness signal.
- 2026-09-16: initial version. (The corresponding plan file lived in the maintainer's local agent state; it is not part of the repository.)
- 2026-09-21 (action-free workflows + idempotency hardening; sections 5, 6, 7 and 10 above were updated to match): (1) both workflows dropped every marketplace action — the Windows runner cannot reach github.com — so checkout is a bare `git clone` and reports go to the **job log** instead of uploaded artifacts; `release.yml` is now 5 steps, `verify.yml` 5 steps, and the earlier SHA-pinned `actions/checkout` no longer exists (historical entries below describe the then-current shape; the static workflow checker was updated accordingly and now asserts the absence of marketplace actions); (2) `release.yml` gained `permissions: contents: write` (release API writes) and the `installer` / `force_github` dispatch inputs; the GitHub create no longer sends `target_commitish` (the two histories are independent; GitHub answers 422); (3) `ci/release-local.ps1` gained: an **installer policy that skips the tag being released and any prerelease** when picking the comparison release (a rerun resolves the same asset set the first run published, and a stable minor release is not misread as a patch because its own rc is already out — the comparison is against the last stable release), a **publish-time re-application of the GitHub body sanitizer** (a release reused from an earlier run can no longer publish a body that was written outside the guard; with no CHANGELOG section to rebuild from, the tripwire refuses), **case-insensitive** matching in all three sanitizer steps, and a retry wrapper for transient platform API failures (bounded attempts; deterministic 4xx are never retried); (4) `npm run bump-version -- <X.Y.Z>` (`ci/release-prep.mjs`) performs the whole local release preparation in one command (version set → commit → tag → auto-changelog → amend → retag → final check; it never pushes); (5) the release-local test suite gained regression cases for the policy rerun path, the reused-body sanitization and the leak tripwire firing, plus a suite-start guard that refuses to run while another release owns the machine-global lock.
- 2026-09-16 (T-017 wrap-up revision): (1) steps 5 and 3 corrected so both CHANGELOG level-2 and level-3 headings are accepted (`ci/version.mjs` updated, commit `04ee8a1`); (2) added "rerun semantics and operating discipline" — published releases are no longer pulled back to draft (same-name assets deleted-then-re-uploaded one by one), `-ForceRepublish` is explicit opt-in, and concurrent runs of `ci/release-local.ps1` are **forbidden**; (3) documented that CI showing SKIP for the tag/CHANGELOG items when HEAD has no tag is normal (relies on checkout's `fetch-depth: 0`); (4) noted that `secrets.GITEA_TOKEN` is injected automatically by Gitea (fall back to plain git if checkout fails in PR scenarios when it is not injected; snippet in the workflow comments) and that `actions/checkout@v4` was not yet SHA-pinned (pin it yourself if you want the hardening).
- 2026-09-16 (T-018 wrap-up hardening): (1) workflow gained step 3, the **workflow self-check (blocking)** (`node ci/tests/verify-workflow.check.mjs`, placed after checkout; this document's "Steps" subsection was renumbered 1-6 accordingly; "steps 3/5" in the T-017 entry refer to the numbering of that time); (2) checkout changed from `@v4` to **pinned by commit SHA** (v4.4.0 = `11d5960a326750d5838078e36cf38b85af677262`, verified via `git ls-remote`); (3) `release-local.ps1` gained a **concurrency lock** (`%TEMP%\mica-release.lock`, holding PID + timestamp; held → exit code **5**, stale locks auto-taken-over, released by `try/finally` on all exit paths), with the exit-code table and recovery manual gaining "5 = concurrency lock held" — mechanism backing for T-017's "no concurrent runs" discipline; (4) `ci/tests/verify-workflow.check.mjs`'s assertion table synced to 6 steps (added `steps.selfcheck`; the checkout assertion enforces a 40-hex-digit SHA), `--selftest` 24 → 26 cases (new M21 remove-self-check-step, M22 revert-to-tag-pinning) all green; `release-local.tests.ps1` gained T13 (livelock exit 5 / stale-lock takeover / locks released on success and failure paths).
- 2026-09-17 (documentation sync after Lane 3 landed; corresponds to the implementation of T-019 / T-020 / T-021 and the additions T-025 / T-026): (1) new **section 5 "CI release (Lane 3, self-hosted Windows runner)"** — `release.yml`'s two triggers (tag push / `workflow_dispatch` with `inputs.tag`), `runs-on: windows-labview26`, the 6-step list, artifact contents, the runner-offline queueing semantics, and "**tags are still created manually by the maintainer; the workflow does not write the repo**"; (2) sections 1 / 2 / 9 / 10 changed Lane 3's status from "deferred" to "**release live, LabVIEW gates still deferred**", uniformly linking to `docs/vm-runner.md`; (3) section 6 credentials changed to **environment variables first** (T-020's contract): in CI `GITEA_TOKEN` is injected automatically by Gitea and the GitHub PAT is stored as repo secret **`GH_RELEASE_TOKEN`** mapped to `GITHUB_TOKEN` in the workflow, while locally `ci/release.env` still works (examples always use `<your-token>`); section 4's step 7 precondition description corrected accordingly; (4) section 5 gained **`ci/bootstrap-deps.ps1`** usage, parameters, exit codes and self-test command (one-time in-VM bootstrap of the 18 VIPM dependencies with an all-present assertion, added in T-025, including `ci/tests/bootstrap-deps.tests.ps1` and `ci/tests/fixtures/vipm-stub/**`); (5) section 8 troubleshooting and section 7 recovery manual gained entries for `release.yml` and `bootstrap-deps.ps1`; (6) section numbers shifted (former sections 5-10 → 6-11); (7) the exit-code table was **not changed**: `5 = concurrency lock held` has been in the table since T-018 (grepped during this pass; no duplicate entries).
- This version was checked item-by-item against the following implementations: `ci/version.mjs`, `ci/repo-integrity.mjs`, `ci/labview.ps1`, `ci/package.ps1`, `ci/release-local.ps1`, `ci/bootstrap-deps.ps1`, `.gitea/workflows/verify.yml`, `.gitea/workflows/release.yml`, `ci/integrity-baseline.json`, `.gitignore`, `docs/vm-runner.md` (read-only comparison, no changes).
- Executed evidence gathered while checking: `node ci/version.mjs check` exit 0; `node ci/repo-integrity.mjs --strict` exit 0; `release-local.ps1` precondition failure modes measured at exit 3 (tag missing / tag != HEAD / tracked files dirty) and exit 2 (missing `ci/release.env`); `pwsh -NoProfile -File ci/tests/bootstrap-deps.tests.ps1` **13/13 green, exit 0** (stub-driven, real VIPM never invoked); `node ci/tests/verify-workflow.check.mjs` and `pwsh -NoProfile -File ci/tests/release-local.tests.ps1` both exit 0 (re-run 2026-09-17).
