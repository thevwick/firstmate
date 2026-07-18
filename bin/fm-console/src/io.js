// I/O layer: everything that touches the filesystem or shells out to firstmate
// helpers lives here, isolated from the pure logic in state.js/commands.js so
// the pure code stays unit-testable. Nothing here reimplements a helper's
// logic - it shells out to the one owner (fm-fleet-snapshot.sh, df, du) and to
// fm-send.sh for the command bridge (see bridge.js).

import { execFile } from 'node:child_process';
import { stat, readdir, readFile } from 'node:fs/promises';
import path from 'node:path';

// Promisified execFile with a bounded timeout so a slow child never wedges the
// UI. Resolves { code, stdout, stderr } rather than rejecting on non-zero, so
// callers decide how to degrade; only spawn failures reject.
function run(cmd, args, { cwd, env, timeout = 10000 } = {}) {
  return new Promise((resolve, reject) => {
    execFile(
      cmd,
      args,
      { cwd, env: env || process.env, timeout, maxBuffer: 16 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err && err.code === undefined && !err.killed) {
          // Spawn failure (ENOENT etc.) - surface it.
          reject(err);
          return;
        }
        resolve({
          code: err ? (err.code ?? (err.killed ? 'timeout' : 1)) : 0,
          stdout: stdout || '',
          stderr: stderr || '',
        });
      }
    );
  });
}

// Resolve the bin/ directory of this firstmate checkout from the console's own
// location (src/../.. -> repo root, then bin/). The launcher also passes
// FM_CONSOLE_BIN as a belt-and-suspenders override.
export function binDir(importMetaUrl) {
  if (process.env.FM_CONSOLE_BIN) return process.env.FM_CONSOLE_BIN;
  const here = path.dirname(new URL(importMetaUrl).pathname);
  // src/ -> fm-console/ -> bin/
  return path.resolve(here, '..', '..');
}

// The firstmate home this console operates on. FM_HOME wins; else the repo root
// two levels above bin/. Mirrors the AGENTS.md FM_HOME discipline.
export function resolveHome(binDirPath) {
  if (process.env.FM_HOME) return process.env.FM_HOME;
  return path.resolve(binDirPath, '..');
}

// Read the structured fleet snapshot. The snapshot is the single owner of fleet
// parsing; the console never re-parses backlog/meta. Returns the parsed object,
// or null with an error string on failure (empty fleet is a normal, non-error
// snapshot, not null).
export async function readSnapshot(bin, home) {
  try {
    const { code, stdout, stderr } = await run(
      path.join(bin, 'fm-fleet-snapshot.sh'),
      ['--json'],
      { env: { ...process.env, FM_HOME: home }, timeout: 15000 }
    );
    if (code !== 0) {
      return { snapshot: null, error: stderr.trim() || `snapshot exited ${code}` };
    }
    return { snapshot: JSON.parse(stdout), error: null };
  } catch (e) {
    return { snapshot: null, error: e.message };
  }
}

// Free space and use% on a volume via df. Parses the -k output's last data row.
// Degrades to nulls on any error - a missing volume must never crash the board.
export async function readDisk(volume) {
  try {
    const { code, stdout } = await run('df', ['-k', volume], { timeout: 5000 });
    if (code !== 0) return { free: null, usePct: null };
    return parseDf(stdout);
  } catch {
    return { free: null, usePct: null };
  }
}

// Pure df -k parser, split out so it is unit-testable without a real df.
// Returns { free (bytes), usePct (0-100 int) } or nulls when unparseable.
export function parseDf(stdout) {
  const lines = String(stdout).trim().split('\n');
  if (lines.length < 2) return { free: null, usePct: null };
  // The filesystem name can wrap; the numeric columns are what we key on.
  // df -k columns: Filesystem 1024-blocks Used Available Capacity ... Mounted
  const cols = lines[lines.length - 1].trim().split(/\s+/);
  // Find the Capacity column (ends with %) to anchor parsing.
  const capIdx = cols.findIndex((c) => /^\d+%$/.test(c));
  if (capIdx < 2) return { free: null, usePct: null };
  const availKb = Number(cols[capIdx - 1]);
  const usePct = Number(cols[capIdx].replace('%', ''));
  if (!Number.isFinite(availKb) || !Number.isFinite(usePct)) {
    return { free: null, usePct: null };
  }
  return { free: availKb * 1024, usePct };
}

// mtime of a file in epoch seconds, or null if absent/unreadable. Used for the
// watcher beacon and afk-flag reads.
export async function fileMtimeSecs(file) {
  try {
    const s = await stat(file);
    return Math.floor(s.mtimeMs / 1000);
  } catch {
    return null;
  }
}

// Whether a file exists (afk flag).
export async function fileExists(file) {
  try {
    await stat(file);
    return true;
  } catch {
    return false;
  }
}

// Worktree size in bytes via du -sk. Slow (walks the tree), so callers run it
// on the du cadence, not every board refresh. Returns null on any error,
// including a torn-down worktree whose path no longer exists.
export async function readWorktreeSize(worktreePath) {
  if (!worktreePath) return null;
  try {
    const { code, stdout } = await run('du', ['-sk', worktreePath], { timeout: 30000 });
    if (code !== 0) return null;
    const kb = Number(String(stdout).trim().split(/\s+/)[0]);
    if (!Number.isFinite(kb)) return null;
    return kb * 1024;
  } catch {
    return null;
  }
}

// Default TTL for WorktreeSizeCache: a multi-GB worktree does not change size
// meaningfully within a du cadence's few passes, so a fresh du -sk walk per
// worktree is only actually needed this often.
export const WORKTREE_SIZE_TTL_MS = 60000;

// Per-worktree du -sk cache with a global in-flight guard, the fix for the
// du-drain bug: app.js used to fire an unguarded du per worktree on every
// DU_INTERVAL_MS tick with no protection against a slow/huge (multi-GB)
// worktree still being walked when the next tick landed, so passes overlapped
// and stacked - confirmed to starve an xcodebuild link step
// (data/mobile-lab-audit-a7/report.md, "du drain"). This cache fixes both
// halves of that: a TTL means most ticks reuse a cached size instead of
// walking at all, and the in-flight flag means even a cache-miss walk that
// outlives one interval is never joined by a second overlapping walk for the
// same (or any other) worktree - get() just returns the still-fresh-enough
// cached value (or null) while one is in flight, rather than queuing more du
// processes on top of a system that is already behind.
export function createWorktreeSizeCache({ ttlMs = WORKTREE_SIZE_TTL_MS, measure = readWorktreeSize } = {}) {
  const cache = new Map(); // worktreePath -> { bytes, atMs }
  let inFlight = false;

  return {
    // Resolve a worktree's size. Never overlaps with another in-flight du
    // call from this cache (returns the last cached value, or null, instead
    // of starting a second walk); reuses a cached value within ttlMs instead
    // of re-walking. Pass nowMs for deterministic tests.
    async get(worktreePath, nowMs = Date.now()) {
      if (!worktreePath) return null;
      const cached = cache.get(worktreePath);
      if (cached && nowMs - cached.atMs < ttlMs) return cached.bytes;
      if (inFlight) return cached ? cached.bytes : null;
      inFlight = true;
      try {
        const bytes = await measure(worktreePath);
        cache.set(worktreePath, { bytes, atMs: nowMs });
        return bytes;
      } finally {
        inFlight = false;
      }
    },
    // Test/inspection hooks only - not used by app.js's normal path.
    isInFlight: () => inFlight,
    peek: (worktreePath) => cache.get(worktreePath)?.bytes ?? null,
  };
}

// Parse a full https://github.com/<owner>/<repo>/pull/<n> URL into its parts,
// mirroring bin/fm-pr-merge.sh's parse_pr_url. gh-axi's `pr checks` takes a PR
// NUMBER plus --repo <owner>/<repo>, not a URL - passing a URL fails with
// "error: Missing PR number" (VALIDATION_ERROR). Returns null if the URL does
// not match.
export function parsePrUrl(prUrl) {
  const m = String(prUrl).match(
    /^https:\/\/github\.com\/([A-Za-z0-9][A-Za-z0-9-]{0,38})\/([A-Za-z0-9._-]+)\/pull\/(\d+)\/?$/
  );
  if (!m) return null;
  return { owner: m[1], repo: m[2], number: m[3] };
}

// PR checks status for a task via gh-axi, best-effort. Returns a short status
// string ('passing' | 'failing' | 'pending' | 'none' | null). Only called when
// the task records a PR url.
//
// gh-axi's `pr checks <n> --repo <owner>/<repo>` always exits 0 on a
// successful read (empirically verified against gh-axi 0.1.26's
// src/commands/pr.js:prChecks) and prints one of two TOON-encoded shapes on
// stdout:
//   checks: "0 passed, 0 failed — this PR has no CI checks configured"   (no checks configured)
//   summary: "N passed, M failed[, K skipped][, P pending], Q total"     (checks exist)
// Any error (bad args, not-found, auth, rate limit) prints "error: ..." /
// "code: ..." on stdout with a non-zero exit. gh-axi's printed output is the
// source of truth here, not the exit code, so this parses that text directly
// rather than trusting exit codes.
export async function readPrChecks(prUrl) {
  const parsed = parsePrUrl(prUrl);
  if (!parsed) return null;
  try {
    const { stdout } = await run(
      'gh-axi',
      ['pr', 'checks', parsed.number, '--repo', `${parsed.owner}/${parsed.repo}`],
      { timeout: 15000 }
    );
    const text = String(stdout);
    if (/no CI checks configured/.test(text)) return 'none';
    const failMatch = text.match(/(\d+)\s+failed/);
    const passMatch = text.match(/(\d+)\s+passed/);
    const pendingMatch = text.match(/(\d+)\s+pending/);
    if (!failMatch || !passMatch) return null;
    if (Number(failMatch[1]) > 0) return 'failing';
    if (pendingMatch && Number(pendingMatch[1]) > 0) return 'pending';
    if (Number(passMatch[1]) > 0) return 'passing';
    return null;
  } catch {
    return null;
  }
}

// Capture firstmate's OWN pane (the resolved supervisor target the command
// bridge sends into - see bridge.js's resolveSupervisor) via bin/fm-peek.sh,
// the same plain, human-facing capture fm-peek uses for cheap diagnosis -
// never the styled composer-only reader (fm_tmux_composer_state), which
// captures only a single cursor row for busy/idle classification, not a
// readable tail. Read-only: this only ever reads pane content, never sends
// keystrokes. Returns { text, error }; a resolution or capture failure
// degrades to { text: null, error } rather than throwing, so a slow or wedged
// pane never blocks the board (callers thread this through an async
// side-channel exactly like du/PR-checks, never inline in render).
export async function readFirstmateActivity(bin, home, target, lines) {
  if (!target) return { text: null, error: 'no target' };
  try {
    const { code, stdout, stderr } = await run(path.join(bin, 'fm-peek.sh'), [target, String(lines)], {
      env: { ...process.env, FM_HOME: home },
      timeout: 10000,
    });
    if (code !== 0) {
      return { text: null, error: (stderr || '').trim() || `fm-peek exited ${code}` };
    }
    return { text: stdout, error: null };
  } catch (e) {
    return { text: null, error: e.message };
  }
}

// Read every fm-mobile-lab build-status file (state/lab-build-<slot>.json,
// per data/mobile-lab-status-contract.md v1) in the home's state/ dir. The lab
// writes these atomically (temp file + mv), but the console must still treat
// each read defensively: a slot with no file simply is not returned (idle),
// and a present-but-malformed/partial file returns a raw-text entry with
// parseError set instead of throwing, so one bad file never blanks the whole
// section. Returns an array of { slot, raw, parseError } - state.js turns
// each into a card, defaulting missing fields there rather than here, so this
// function stays a thin, defensive read and nothing more.
export async function readLabBuildStatuses(home) {
  const dir = path.join(home, 'state');
  let entries;
  try {
    entries = await readdir(dir);
  } catch {
    return [];
  }
  const files = entries.filter((f) => /^lab-build-.+\.json$/.test(f));
  const results = [];
  for (const file of files) {
    const slotMatch = file.match(/^lab-build-(.+)\.json$/);
    const slot = slotMatch ? slotMatch[1] : file;
    try {
      const text = await readFile(path.join(dir, file), 'utf8');
      try {
        const raw = JSON.parse(text);
        results.push({ slot, raw, parseError: null });
      } catch (e) {
        results.push({ slot, raw: null, parseError: e.message });
      }
    } catch (e) {
      results.push({ slot, raw: null, parseError: e.message });
    }
  }
  return results;
}

export { run };
