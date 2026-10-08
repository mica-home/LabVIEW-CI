#!/usr/bin/env node
/**
 * ci/tests/fixtures/api-stub.mjs — minimal Gitea/GitHub releases API double.
 *
 * Usage: node api-stub.mjs <port> <logFile> [--fail-uploads <n[,n...]>] [--fail-upload-status <c>] [--hang-on <substring>]
 *                          [--fudge-size <n>] [--raw-dir <dir>] [--raw-status <code>]
 *                          [--seed-release <tag>]... [--seed-prerelease <tag>]... [--seed-gh-release <tag>]...
 *                          [--seed-assets <tag> <name1,name2,...>] [--seed-body <tag> <text>]
 *                          [--fail-list] [--flaky-first <n>] [--always-fail] [--flaky-status <code>] [--create-then-hang]
 *
 * Serves the release endpoints ci/release-local.ps1 talks to, for ANY path prefix
 * (so one process can double both platforms at once):
 *
 *   /<anything>/repos/{owner}/{repo}/releases                     GET (list), POST (create)
 *   /<anything>/repos/{owner}/{repo}/releases/tags/{tag}          GET
 *   /<anything>/repos/{owner}/{repo}/releases/{id}                PATCH
 *   /<anything>/repos/{owner}/{repo}/releases/{id}/assets         GET (list), POST (upload, ?name=)
 *   /<anything>/repos/{owner}/{repo}/releases/{id}/assets/{aid}   DELETE
 *   /<anything>/repos/{owner}/{repo}/raw/{filepath}?ref={ref}     GET (raw file; Gitea API)
 *   /<anything>/repos/{owner}/{repo}/contents/{filepath}?ref={ref} GET (file; GitHub contents API,
 *                                                     raw bytes via Accept: application/vnd.github.raw)
 *   /__state                                                      GET (test introspection, not a real API)
 *
 * Raw file route (used by ci/runner/vm-bootstrap.ps1 Phase 3; both the Gitea `raw` and the
 * GitHub `contents` shape share it - the double ignores the Accept header, the bytes are
 * identical either way):
 *   The requested filepath is mapped under --raw-dir (e.g. raw-dir=<d> + filepath
 *   "ci/bootstrap-deps.ps1" serves <d>/ci/bootstrap-deps.ps1) and returned byte-for-byte
 *   with Content-Type: application/octet-stream. A missing --raw-dir, a missing file, an
 *   empty filepath or a path escaping --raw-dir answers 404 (never 200 with empty bytes).
 *   --raw-status <code> forces every raw request to answer that status without touching
 *   the disk - use 401 to model an invalid token and 404 to model a wrong ref/path, which
 *   is how the "fetch failed -> manual fallback" path is tested. Non-GET raw requests
 *   answer 405.
 *
 * Platform fidelity quirks (they mirror the real services):
 *   - paths under /gh/ or /uploads/ behave like GitHub: a DRAFT release is NOT
 *     returned by the by-tag endpoint (404) and creating a second release for an
 *     already-used tag fails with 422 — which is exactly the recovery hole the
 *     release script has to close via its release-list fallback.
 *   - every other prefix behaves like Gitea: drafts are visible by tag and a
 *     duplicate tag create fails with 409.
 *
 * Every request is appended to <logFile> as one JSON line (fs.appendFileSync, before
 * the response is sent, so the log is a faithful ordering of what the server saw):
 *   {seq,t,method,path,query,slug,auth,accept,ghApiVersion,contentType,tagName,
 *    assetName,size,uploadAttempt,draft,prerelease,targetCommitish,status,releaseId}
 * Raw requests carry the extra fields {raw,rawPath,ref,host,authSha256}.
 *
 * SECURITY: the Authorization header VALUE is never logged - only the scheme
 * ("token" / "Bearer"), so test sentinels can never leak into the log. Raw requests
 * additionally log authSha256, a SHA-256 fingerprint of the presented credential
 * (same pattern as fixtures/runner-stub), which proves WHICH token was sent without
 * ever writing the value; nothing else about the header is recorded.
 *
 * --fail-uploads 3     the 3rd upload ATTEMPT overall answers --fail-upload-status (all
 *                      platforms share one attempt counter, matching "interrupt mid-publish"
 *                      tests).
 * --fail-upload-status <c>
 *                      status for --fail-uploads (default 500). Use a deterministic 4xx
 *                      (e.g. 422) to model an upload that is rejected for good and must
 *                      NOT be retried away, so a recovery/cancel-resume test still aborts.
 * --hang-on <text>     any request whose "METHOD path" contains <text> is logged with
 *                      status:null and then never answered (client-side timeout test).
 * --fudge-size <n>     the assets-list endpoint reports every asset n bytes larger than
 *                      what was received (mismatch-verification test); /__state keeps the truth.
 * --raw-dir <dir>      directory the raw-file route serves files from (see above).
 * --raw-status <code>  force that status for every raw-file request (401 / 404 tests).
 *
 * Seed fixtures (what the release under test finds already published):
 * --seed-release <tag> (repeatable) pre-publish a PUBLISHED (non-draft) stable
 *                      release with no assets under the Gitea slug (MICA/MICA),
 *                      so the installer policy's "latest published release" lookup
 *                      has something to compare against.
 * --seed-prerelease <tag> (repeatable) same shape as --seed-release, but the
 *                      release carries prerelease:true (the policy must skip it
 *                      when it picks the latest published release).
 *                      All seeds are served in the order their flags appear on the
 *                      command line, which is how a fixture decides whether a
 *                      prerelease is newer (listed before) the stable release it
 *                      shares a major.minor with.
 * --seed-gh-release <tag> (repeatable) additionally publish the same tag under
 *                      the GitHub slug (mica-home/MICA), so a release run REUSES
 *                      that release on the GitHub leg too (stale-body tests).
 *                      Requires --seed-release / --seed-prerelease for the tag.
 * --seed-assets <tag> <name1,name2,...>
 *                      attach placeholder assets (size 1, unique ids) to EVERY
 *                      release seeded for <tag>. The names travel as ONE argv
 *                      element (comma-separated).
 * --seed-body <tag> <text>
 *                      set the seeded release's body to <text>, after replacing
 *                      every literal {WEBBASE} in it with http://127.0.0.1:<port>/gr
 *                      (the suite's Gitea web base is <stub base>/gr). <text> is a
 *                      separate argv element, so it may contain spaces, ':' and
 *                      '//' (a fixture may pass a full link verbatim).
 *                      A --seed-assets / --seed-body / --seed-gh-release tag that
 *                      no --seed-release / --seed-prerelease created is a fixture
 *                      bug: the stub refuses to start instead of ignoring it.
 * --flaky-first <n>    the first n requests (every route except the /__state introspection
 *                      one) answer --flaky-status and are logged with "flaky":true, then the
 *                      stub behaves normally. Drives the client's bounded retry/backoff.
 * --always-fail        every request answers --flaky-status (persistent-failure test:
 *                      the client must give up after its bounded number of attempts).
 * --flaky-status <c>   status used by --flaky-first / --always-fail (default 503; use 401
 *                      to model a deterministic auth failure that must NOT be retried).
 * --create-then-hang   a create POST creates the release server-side and then never
 *                      answers, so the client times out AFTER the effect happened. The
 *                      retry must read the release it just created (409 -> list fallback)
 *                      instead of duplicating it (stale-state / idempotent convergence).
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [, , portArg, logArg, ...rest] = process.argv;
if (!portArg || !logArg) {
  console.error('usage: node api-stub.mjs <port> <logFile> [--fail-uploads n] [--fail-upload-status c] [--hang-on text] [--fudge-size n] [--raw-dir dir] [--raw-status code] [--seed-release tag]... [--seed-prerelease tag]... [--seed-gh-release tag]... [--seed-assets tag name1,name2,...] [--seed-body tag text] [--fail-list] [--flaky-first n] [--always-fail] [--flaky-status code] [--create-then-hang]');
  process.exit(2);
}
const port = Number(portArg);
const logFile = logArg;

const failUploads = new Set();
let failUploadStatus = 500;
let hangOn = null;
let sizeFudge = 0;
let rawDir = null;
let rawStatus = null;
// Seed fixtures: the release the run under test finds already published.
const seededTags = [];              // --seed-release (stable copy on the Gitea slug)
const seededPrereleaseTags = [];    // --seed-prerelease (prerelease:true, Gitea slug)
const seededGithubTags = [];        // --seed-gh-release (same tag on the GitHub slug)
const seededAssetNames = new Map(); // tag -> [asset names], size 1 each
const seededBodies = new Map();     // tag -> body ({WEBBASE} already expanded)
// The order of the seed flags on the command line IS the order of the release
// list (the services serve it newest-first), so a fixture can decide whether a
// prerelease appears before the older stable release.
const seedPlan = [];                // [{tag, prerelease}] in argv order
let failList = false;
let flakyFirst = 0;
let alwaysFail = false;
let flakyStatus = 503;
let createThenHang = false;
for (let i = 0; i < rest.length; i++) {
  if (rest[i] === '--fail-uploads') {
    for (const n of String(rest[i + 1]).split(',')) failUploads.add(Number(n));
    i++;
  } else if (rest[i] === '--fail-upload-status') {
    failUploadStatus = Number(rest[i + 1]);
    i++;
  } else if (rest[i] === '--hang-on') {
    hangOn = String(rest[i + 1]);
    i++;
  } else if (rest[i] === '--fudge-size') {
    sizeFudge = Number(rest[i + 1]);
    i++;
  } else if (rest[i] === '--raw-dir') {
    rawDir = path.resolve(String(rest[i + 1]));
    i++;
  } else if (rest[i] === '--raw-status') {
    rawStatus = Number(rest[i + 1]);
    i++;
  } else if (rest[i] === '--seed-release') {
    seededTags.push(String(rest[i + 1]));
    seedPlan.push({ tag: String(rest[i + 1]), prerelease: false });
    i++;
  } else if (rest[i] === '--seed-prerelease') {
    seededPrereleaseTags.push(String(rest[i + 1]));
    seedPlan.push({ tag: String(rest[i + 1]), prerelease: true });
    i++;
  } else if (rest[i] === '--seed-gh-release') {
    seededGithubTags.push(String(rest[i + 1]));
    i++;
  } else if (rest[i] === '--seed-assets') {
    // Comma-separated names in ONE argv element (a name may not contain a comma).
    const names = String(rest[i + 2]).split(',').map((s) => s.trim()).filter((s) => s !== '');
    seededAssetNames.set(String(rest[i + 1]), names);
    i += 2;
  } else if (rest[i] === '--seed-body') {
    // {WEBBASE} is the suite's Gitea web base (<stub base>/gr), which the fixture
    // cannot know before the port is chosen; the stub expands it here instead.
    const text = String(rest[i + 2]).split('{WEBBASE}').join(`http://127.0.0.1:${port}/gr`);
    seededBodies.set(String(rest[i + 1]), text);
    i += 2;
  } else if (rest[i] === '--fail-list') {
    failList = true;
  } else if (rest[i] === '--flaky-first') {
    flakyFirst = Number(rest[i + 1]);
    i++;
  } else if (rest[i] === '--always-fail') {
    alwaysFail = true;
  } else if (rest[i] === '--flaky-status') {
    flakyStatus = Number(rest[i + 1]);
    i++;
  } else if (rest[i] === '--create-then-hang') {
    createThenHang = true;
  }
}

// Seed fixtures (see the header): every seeded release is PUBLISHED (draft:false),
// stable unless --seed-prerelease asked for prerelease:true, and carries the assets
// of --seed-assets (size 1 placeholders, unique ids) and the body of --seed-body.
// --seed-release seeds the Gitea slug only (that is where the installer policy's
// "latest published release" lookup runs); --seed-gh-release mirrors the same tag
// onto the GitHub slug, which is what makes a run REUSE it on the GitHub leg too.
const SEED_GITEA_SLUG = 'MICA/MICA';
const SEED_GITHUB_SLUG = 'mica-home/MICA';

function seedRelease(tag, slug, prerelease) {
  const names = seededAssetNames.get(tag) ?? [];
  const rel = {
    id: nextReleaseId++,
    tag_name: tag,
    name: tag,
    draft: false,
    prerelease,
    target_commitish: null,
    body: seededBodies.get(tag) ?? null,
    assets: names.map((name) => ({ id: nextAssetId++, name, size: 1, created_at: new Date().toISOString() })),
  };
  if (!releases.has(slug)) releases.set(slug, new Map());
  releases.get(slug).set(tag, rel);
}

function seedReleases() {
  for (const plan of seedPlan) {
    seedRelease(plan.tag, SEED_GITEA_SLUG, plan.prerelease);
    // --seed-gh-release mirrors a STABLE tag onto the GitHub slug (a mirrored
    // prerelease would only matter for the Gitea-side policy lookup).
    if (!plan.prerelease && seededGithubTags.includes(plan.tag)) {
      seedRelease(plan.tag, SEED_GITHUB_SLUG, false);
    }
  }
}

// A --seed-assets / --seed-body / --seed-gh-release tag that no --seed-release /
// --seed-prerelease created would be silently ignored and the fixture would look
// like a passing test for the wrong reason: refuse to start instead.
for (const tag of [...seededAssetNames.keys(), ...seededBodies.keys(), ...seededGithubTags]) {
  if (!seededTags.includes(tag) && !seededPrereleaseTags.includes(tag)) {
    console.error('api-stub: --seed-assets/--seed-body/--seed-gh-release tag ' + tag + ' was not seeded with --seed-release/--seed-prerelease');
    process.exit(2);
  }
}

let seq = 0;
let requestCount = 0;
let nextReleaseId = 1;
let nextAssetId = 1;
let uploadAttempt = 0;
/** @type {Map<string, Map<string, any>>} slug -> tag -> release */
const releases = new Map();
seedReleases();

function releaseList(slug) {
  return [...(releases.get(slug)?.values() ?? [])];
}
function findRelease(slug, tag) {
  return releases.get(slug)?.get(tag) ?? null;
}
function releaseJson(rel) {
  return {
    id: rel.id,
    tag_name: rel.tag_name,
    name: rel.name,
    draft: rel.draft,
    prerelease: rel.prerelease,
    target_commitish: rel.target_commitish ?? null,
    body: rel.body ?? null,
    assets: rel.assets.map((a) => ({ id: a.id, name: a.name, size: a.size, created_at: a.created_at })),
  };
}
function log(entry) {
  const line = JSON.stringify({ seq: ++seq, t: new Date().toISOString(), ...entry });
  fs.appendFileSync(logFile, line + '\n');
}
function sha256Hex(text) {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex');
}
function send(res, status, body) {
  const payload = body === undefined ? '' : JSON.stringify(body);
  // Connection: close makes the SERVER close the socket first, so the client's
  // ephemeral port is released without a client-side TIME_WAIT. That keeps the
  // suite from exhausting the ephemeral range on a loaded machine.
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload), 'Connection': 'close' });
  res.end(payload);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const segs = url.pathname.split('/').filter(Boolean);
  const githubLike = url.pathname.startsWith('/gh/') || url.pathname.startsWith('/uploads/');
  const authHeader = String(req.headers.authorization ?? '');
  const authScheme = authHeader.split(' ')[0] || null;
  const base = {
    method: req.method,
    path: url.pathname,
    query: url.search.replace(/^\?/, ''),
    slug: null,
    auth: authScheme,
    accept: req.headers.accept ?? null,
    ghApiVersion: req.headers['x-github-api-version'] ?? null,
    contentType: String(req.headers['content-type'] ?? '').split(';')[0] || null,
  };

  if (req.method === 'GET' && url.pathname === '/__state') {
    const all = [];
    for (const [slug, m] of releases) for (const rel of m.values()) all.push({ slug, ...releaseJson(rel) });
    log({ ...base, status: 200 });
    return send(res, 200, { count: all.length, releases: all });
  }

  const reposAt = segs.indexOf('repos');

  // --flaky-first N / --always-fail: inject a failure BEFORE routing, so the client's
  // bounded retry/backoff meets a real HTTP status (503 by default, any --flaky-status).
  // Every request except the /__state introspection route is counted, so the attempt
  // sequence the client saw is exactly the sequence this log shows.
  if (url.pathname !== '/__state') {
    requestCount++;
    if (alwaysFail || requestCount <= flakyFirst) {
      const flakySlug = (reposAt >= 0 && segs.length >= reposAt + 3) ? segs[reposAt + 1] + '/' + segs[reposAt + 2] : null;
      log({ ...base, slug: flakySlug, flaky: true, status: flakyStatus });
      return send(res, flakyStatus, { message: 'injected failure (--flaky-first/--always-fail, request ' + requestCount + ')' });
    }
  }

  // GET /repos/{owner}/{repo}/raw/{filepath}?ref=...       (Gitea raw file API)
  // GET /repos/{owner}/{repo}/contents/{filepath}?ref=...  (GitHub contents API; the client
  //     sends Accept: application/vnd.github.raw for the file itself, which this double does
  //     not need to distinguish - the bytes are served the same way)
  // Added for ci/runner/vm-bootstrap.ps1 Phase 3. The releases routes below are unchanged.
  if (reposAt >= 0 && (segs[reposAt + 3] === 'raw' || segs[reposAt + 3] === 'contents')) {
    let filePath = '';
    try {
      filePath = segs.slice(reposAt + 4).map(decodeURIComponent).join('/');
    } catch {
      log({ ...base, raw: true, status: 400 });
      return send(res, 400, { message: 'Bad Request: malformed percent-encoding in the file path' });
    }
    const rawBase = {
      ...base,
      raw: true,
      rawKind: segs[reposAt + 3], // 'raw' (Gitea) | 'contents' (GitHub contents API)
      rawPath: filePath,
      ref: url.searchParams.get('ref'),
      host: req.headers.host ?? null,
      authSha256: authHeader.includes(' ') ? sha256Hex(authHeader.slice(authHeader.indexOf(' ') + 1)) : null,
    };
    if (req.method !== 'GET') {
      log({ ...rawBase, status: 405 });
      return send(res, 405, { message: 'Method Not Allowed' });
    }
    if (hangOn && `${req.method} ${url.pathname}`.includes(hangOn)) {
      log({ ...rawBase, status: null, hang: true });
      return; // never answer: the client must time out on its own
    }
    if (rawStatus) {
      log({ ...rawBase, status: rawStatus });
      return send(res, rawStatus, { message: rawStatus === 401 ? 'Unauthorized' : 'Not Found' });
    }
    if (!rawDir || filePath === '') {
      log({ ...rawBase, status: 404 });
      return send(res, 404, { message: 'Not Found (no --raw-dir configured, or empty file path)' });
    }
    const abs = path.resolve(rawDir, filePath);
    if (abs !== rawDir && !abs.startsWith(rawDir + path.sep)) {
      log({ ...rawBase, status: 404, escaped: true });
      return send(res, 404, { message: 'Not Found' });
    }
    let body = null;
    try {
      if (fs.statSync(abs).isFile()) body = fs.readFileSync(abs);
    } catch { body = null; }
    if (body === null) {
      log({ ...rawBase, status: 404 });
      return send(res, 404, { message: 'Not Found' });
    }
    log({ ...rawBase, status: 200, size: body.length });
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': body.length, 'Connection': 'close' });
    return res.end(body);
  }

  if (reposAt < 0 || segs.length < reposAt + 3 || segs[reposAt + 3] !== 'releases') {
    log({ ...base, status: 404 });
    return send(res, 404, { message: 'Not Found' });
  }
  const slug = segs[reposAt + 1] + '/' + segs[reposAt + 2];
  const tail = segs.slice(reposAt + 4); // after 'releases'
  base.slug = slug;

  const raw = (req.method === 'POST' || req.method === 'PATCH' || req.method === 'PUT') ? await readBody(req) : Buffer.alloc(0);
  let json = null;
  if (raw.length && String(req.headers['content-type'] ?? '').includes('application/json')) {
    try { json = JSON.parse(raw.toString('utf8')); } catch { json = null; }
  }

  const fullKey = `${req.method} ${url.pathname}`;
  if (hangOn && fullKey.includes(hangOn)) {
    log({ ...base, status: null, hang: true });
    return; // never answer: the client must time out on its own
  }

  // GET /releases  (list)
  if (tail.length === 0 && req.method === 'GET') {
    if (failList) {
      // models an unreachable/broken releases API: the installer policy's
      // auto lookup must fall back to 'always' (never block the release).
      log({ ...base, status: 500 });
      return send(res, 500, { message: 'injected list failure (--fail-list)' });
    }
    const list = releaseList(slug).map(releaseJson);
    log({ ...base, status: 200 });
    return send(res, 200, list);
  }

  // POST /releases  (create)
  if (tail.length === 0 && req.method === 'POST') {
    const tag = json?.tag_name;
    const fields = { tagName: tag ?? null, draft: json?.draft ?? null, prerelease: json?.prerelease ?? null, targetCommitish: json?.target_commitish ?? null, body: json?.body ?? null };
    if (!json || typeof tag !== 'string' || tag === '') {
      log({ ...base, ...fields, status: 422 });
      return send(res, 422, { message: 'Validation Failed', errors: [{ code: 'missing', field: 'tag_name' }] });
    }
    if (findRelease(slug, tag)) {
      const status = githubLike ? 422 : 409;
      log({ ...base, ...fields, status });
      return send(res, status, { message: 'Validation Failed', errors: [{ code: 'already_exists', field: 'tag_name' }] });
    }
    if (!releases.has(slug)) releases.set(slug, new Map());
    const rel = {
      id: nextReleaseId++,
      tag_name: tag,
      name: json.name ?? tag,
      draft: json.draft !== false,
      prerelease: json.prerelease === true,
      target_commitish: json.target_commitish ?? null,
      body: typeof json.body === 'string' ? json.body : null,
      assets: [],
    };
    releases.get(slug).set(tag, rel);
    if (createThenHang) {
      // The effect happened (the release exists now) but the client never gets the
      // answer: a retry of the same POST must find it and take the conflict path.
      log({ ...base, ...fields, status: null, hang: true, releaseId: rel.id });
      return; // never answer
    }
    log({ ...base, ...fields, status: 201, releaseId: rel.id });
    return send(res, 201, releaseJson(rel));
  }

  // /releases/tags/{tag}
  if (tail[0] === 'tags' && tail.length === 2 && req.method === 'GET') {
    const tag = decodeURIComponent(tail[1]);
    const rel = findRelease(slug, tag);
    const hidden = !rel || (githubLike && rel.draft); // GitHub hides drafts from by-tag
    log({ ...base, tagName: tag, status: hidden ? 404 : 200, releaseId: rel ? rel.id : null });
    if (hidden) return send(res, 404, { message: 'Not Found' });
    return send(res, 200, releaseJson(rel));
  }

  const relById = tail.length >= 1 && /^\d+$/.test(tail[0])
    ? [...(releases.get(slug)?.values() ?? [])].find((r) => r.id === Number(tail[0])) ?? null
    : null;

  // PATCH /releases/{id}
  if (relById && tail.length === 1 && req.method === 'PATCH') {
    if (json && typeof json === 'object') {
      // body is applied like the real services do: a publish PATCH that carries a
      // sanitized body must be visible in /__state (the release body a user sees).
      for (const k of ['draft', 'prerelease', 'name', 'tag_name', 'target_commitish', 'body']) {
        if (k in json) relById[k] = json[k];
      }
    }
    log({ ...base, draft: relById.draft, prerelease: relById.prerelease, status: 200, releaseId: relById.id });
    return send(res, 200, releaseJson(relById));
  }

  // /releases/{id}/assets...
  if (relById && tail[1] === 'assets') {
    // GET /releases/{id}/assets
    if (tail.length === 2 && req.method === 'GET') {
      log({ ...base, status: 200, releaseId: relById.id });
      // --fudge-size: the API surface lies about the byte counts (/__state keeps the truth)
      return send(res, 200, relById.assets.map((a) => ({ id: a.id, name: a.name, size: a.size + sizeFudge, created_at: a.created_at })));
    }
    // POST /releases/{id}/assets?name=...
    if (tail.length === 2 && req.method === 'POST') {
      const name = url.searchParams.get('name');
      uploadAttempt++;
      const fields = { assetName: name, size: raw.length, uploadAttempt, contentType: base.contentType };
      if (failUploads.has(uploadAttempt)) {
        log({ ...base, ...fields, status: failUploadStatus, releaseId: relById.id });
        return send(res, failUploadStatus, { message: 'injected upload failure (--fail-uploads ' + uploadAttempt + ')' });
      }
      if (!name) {
        log({ ...base, ...fields, status: 422, releaseId: relById.id });
        return send(res, 422, { message: 'missing ?name=' });
      }
      const asset = { id: nextAssetId++, name, size: raw.length, created_at: new Date().toISOString() };
      relById.assets.push(asset);
      log({ ...base, ...fields, status: 201, releaseId: relById.id });
      return send(res, 201, { id: asset.id, name: asset.name, size: asset.size });
    }
    // DELETE /releases/{id}/assets/{assetId}
    if (tail.length === 3 && /^\d+$/.test(tail[2]) && req.method === 'DELETE') {
      const assetId = Number(tail[2]);
      const idx = relById.assets.findIndex((a) => a.id === assetId);
      const assetName = idx >= 0 ? relById.assets[idx].name : null;
      if (idx >= 0) relById.assets.splice(idx, 1);
      log({ ...base, assetName, status: idx >= 0 ? 204 : 404, releaseId: relById.id });
      if (idx < 0) return send(res, 404, { message: 'Not Found' });
      res.writeHead(204, { 'Connection': 'close' });
      return res.end();
    }
  }

  log({ ...base, status: 404, releaseId: relById ? relById.id : null });
  return send(res, 404, { message: 'Not Found' });
});

server.listen(port, '127.0.0.1', () => {
  console.log(`api-stub listening on 127.0.0.1:${port} log=${logFile}` + (failUploads.size ? ` failUploads=${[...failUploads].join(',')}` : '') + (hangOn ? ` hangOn=${hangOn}` : '') + (rawDir ? ` rawDir=${rawDir}` : '') + (rawStatus ? ` rawStatus=${rawStatus}` : '') + (seededTags.length ? ` seedReleases=${seededTags.join(',')}` : '') + (seededPrereleaseTags.length ? ` seedPrereleases=${seededPrereleaseTags.join(',')}` : '') + (seededGithubTags.length ? ` seedGhReleases=${seededGithubTags.join(',')}` : '') + (seededAssetNames.size ? ` seedAssets=${[...seededAssetNames].map(([tag, names]) => tag + ':' + names.join('+')).join(',')}` : '') + (seededBodies.size ? ` seedBodies=${[...seededBodies.keys()].join(',')}` : '') + (failList ? ' failList=true' : '') + (flakyFirst > 0 ? ` flakyFirst=${flakyFirst}` : '') + (alwaysFail ? ` alwaysFail=${flakyStatus}` : ''));
});
server.on('error', (e) => {
  console.error('api-stub error: ' + e.message);
  process.exit(1);
});
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => process.exit(0));
}
