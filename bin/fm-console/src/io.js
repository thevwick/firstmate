// I/O layer: everything that touches the filesystem or shells out to firstmate
// helpers lives here, isolated from the pure logic in state.js/commands.js so
// the pure code stays unit-testable. Nothing here reimplements a helper's
// logic - it shells out to the one owner (fm-fleet-snapshot.sh, df, du) and to
// fm-send.sh for the command bridge (see bridge.js).

import { execFile } from 'node:child_process';
import { stat } from 'node:fs/promises';
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

// PR checks status for a task via gh-axi, best-effort. Returns a short status
// string ('passing' | 'failing' | 'pending' | null). Only called when the task
// records a PR url. gh-axi's own output shape is the source of truth; this
// keeps parsing to the rollup state it prints and degrades to null otherwise.
export async function readPrChecks(prUrl) {
  if (!prUrl) return null;
  try {
    const { code, stdout } = await run(
      'gh-axi',
      ['pr', 'checks', prUrl],
      { timeout: 15000 }
    );
    // gh pr checks exits 0 when all pass, 8 when pending, non-zero-non-8 on fail.
    if (code === 0) return 'passing';
    if (code === 8) return 'pending';
    if (String(stdout).length) return 'failing';
    return null;
  } catch {
    return null;
  }
}

export { run };
