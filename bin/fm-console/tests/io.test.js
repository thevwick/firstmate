// Unit tests for io.js's gh-axi-backed PR-checks reader. Stubs a fake gh-axi
// on PATH (same convention render.test.js uses for fm-fleet-snapshot.sh /
// fm-send.sh / fm-peek.sh) so the mapping logic is exercised against real
// gh-axi output shapes without a network call or a real PR.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, mkdir, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { parsePrUrl, readPrChecks, readLabBuildStatuses, createWorktreeSizeCache } from '../src/io.js';

const PR_URL = 'https://github.com/thevwick/firstmate/pull/10';

// Prepend a temp dir holding a stub gh-axi to PATH for the duration of one
// call, then restore PATH. execFile resolves 'gh-axi' via PATH lookup, so
// this is the same shape as stubbing bin/fm-*.sh, just via PATH instead of
// an explicit bin dir argument.
async function withStubGhAxi(script, fn) {
  const dir = await mkdtemp(path.join(tmpdir(), 'fmc-ghaxi-'));
  const stub = path.join(dir, 'gh-axi');
  await writeFile(stub, script, { mode: 0o755 });
  await chmod(stub, 0o755);
  const origPath = process.env.PATH;
  process.env.PATH = `${dir}:${origPath}`;
  try {
    await fn();
  } finally {
    process.env.PATH = origPath;
  }
}

test('parsePrUrl extracts owner/repo/number from a full PR URL', () => {
  assert.deepEqual(parsePrUrl(PR_URL), {
    owner: 'thevwick',
    repo: 'firstmate',
    number: '10',
  });
});

test('parsePrUrl returns null for a non-matching string', () => {
  assert.equal(parsePrUrl('not a url'), null);
  assert.equal(parsePrUrl('https://github.com/owner/repo/issues/1'), null);
});

test('readPrChecks calls gh-axi with number + --repo, never the raw URL', async () => {
  await withStubGhAxi(
    `#!/usr/bin/env bash\nprintf '%s\\n' "$@" > "${path.join(tmpdir(), 'fmc-ghaxi-args.txt')}"\necho 'summary: "1 passed, 0 failed, 1 total"'\n`,
    async () => {
      const status = await readPrChecks(PR_URL);
      assert.equal(status, 'passing');
      const { readFile } = await import('node:fs/promises');
      const argsText = await readFile(path.join(tmpdir(), 'fmc-ghaxi-args.txt'), 'utf8');
      const argLines = argsText.trim().split('\n');
      assert.deepEqual(argLines, ['pr', 'checks', '10', '--repo', 'thevwick/firstmate']);
    }
  );
});

test('readPrChecks maps a no-checks-configured PR to "none", not "failing"', async () => {
  await withStubGhAxi(
    `#!/usr/bin/env bash\necho 'checks: "0 passed, 0 failed — this PR has no CI checks configured"'\nexit 0\n`,
    async () => {
      const status = await readPrChecks(PR_URL);
      assert.equal(status, 'none');
    }
  );
});

test('readPrChecks maps a fully-passing rollup to "passing"', async () => {
  await withStubGhAxi(
    `#!/usr/bin/env bash\necho 'summary: "3 passed, 0 failed, 3 total"'\nexit 0\n`,
    async () => {
      const status = await readPrChecks(PR_URL);
      assert.equal(status, 'passing');
    }
  );
});

test('readPrChecks maps any failed check to "failing"', async () => {
  await withStubGhAxi(
    `#!/usr/bin/env bash\necho 'summary: "2 passed, 1 failed, 3 total"'\nexit 0\n`,
    async () => {
      const status = await readPrChecks(PR_URL);
      assert.equal(status, 'failing');
    }
  );
});

test('readPrChecks maps an in-progress rollup with no failures yet to "pending"', async () => {
  await withStubGhAxi(
    `#!/usr/bin/env bash\necho 'summary: "1 passed, 0 failed, 2 pending, 3 total"'\nexit 0\n`,
    async () => {
      const status = await readPrChecks(PR_URL);
      assert.equal(status, 'pending');
    }
  );
});

test('readPrChecks degrades to null on the old URL-argument error shape', async () => {
  // Regression guard for the original bug: passing a raw URL to `gh-axi pr
  // checks` prints "error: Missing PR number" / "code: VALIDATION_ERROR" on
  // stdout with a non-zero exit. Confirms the fixed call shape (number +
  // --repo) plus text-based parsing never lands on 'failing' for an error.
  await withStubGhAxi(
    `#!/usr/bin/env bash\necho 'error: Missing PR number'\necho 'code: VALIDATION_ERROR'\nexit 2\n`,
    async () => {
      const status = await readPrChecks(PR_URL);
      assert.equal(status, null);
    }
  );
});

test('readPrChecks degrades to null on gh-axi failure (not found, timeout, etc)', async () => {
  await withStubGhAxi(
    `#!/usr/bin/env bash\necho 'error: Item #999999 does not exist in this repository'\necho 'code: NOT_FOUND'\nexit 1\n`,
    async () => {
      const status = await readPrChecks(PR_URL);
      assert.equal(status, null);
    }
  );
});

test('readPrChecks returns null for a missing PR url without shelling out', async () => {
  assert.equal(await readPrChecks(null), null);
  assert.equal(await readPrChecks(undefined), null);
  assert.equal(await readPrChecks(''), null);
});

// readLabBuildStatuses: reads state/lab-build-*.json per
// data/mobile-lab-status-contract.md v1. Exercised against a real temp home
// directory (not a stub script - this is a plain file read, not a shell-out)
// so the glob/parse/defensive-degrade behavior is verified against real files
// on disk, matching the contract's own atomic-write description.
async function makeHomeWithState() {
  const home = await mkdtemp(path.join(tmpdir(), 'fmc-lab-'));
  await mkdir(path.join(home, 'state'), { recursive: true });
  return home;
}

test('readLabBuildStatuses reads every lab-build-*.json file, deriving the slot from its filename', async () => {
  const home = await makeHomeWithState();
  await writeFile(
    path.join(home, 'state', 'lab-build-dashpivot-mobile-0.json'),
    JSON.stringify({ schema: 1, slot: 'dashpivot-mobile-0', status: 'running' })
  );
  await writeFile(
    path.join(home, 'state', 'lab-build-dashpivot-mobile-1.json'),
    JSON.stringify({ schema: 1, slot: 'dashpivot-mobile-1', status: 'success' })
  );
  const results = await readLabBuildStatuses(home);
  const slots = results.map((r) => r.slot).sort();
  assert.deepEqual(slots, ['dashpivot-mobile-0', 'dashpivot-mobile-1']);
  for (const r of results) {
    assert.equal(r.parseError, null);
    assert.equal(typeof r.raw, 'object');
  }
});

test('readLabBuildStatuses ignores unrelated files in state/', async () => {
  const home = await makeHomeWithState();
  await writeFile(path.join(home, 'state', 'lab-build-slot-a.json'), JSON.stringify({ status: 'running' }));
  await writeFile(path.join(home, 'state', 'some-task.meta'), 'window=fm-abc\n');
  await writeFile(path.join(home, 'state', '.last-watcher-beat'), '');
  const results = await readLabBuildStatuses(home);
  assert.equal(results.length, 1);
  assert.equal(results[0].slot, 'slot-a');
});

test('readLabBuildStatuses degrades a malformed JSON file to a parseError entry, never throwing', async () => {
  const home = await makeHomeWithState();
  await writeFile(path.join(home, 'state', 'lab-build-broken.json'), 'not valid json {{{');
  const results = await readLabBuildStatuses(home);
  assert.equal(results.length, 1);
  assert.equal(results[0].slot, 'broken');
  assert.equal(results[0].raw, null);
  assert.match(results[0].parseError, /.+/);
});

test('readLabBuildStatuses returns an empty list when state/ has no lab-build files, never throwing', async () => {
  const home = await makeHomeWithState();
  assert.deepEqual(await readLabBuildStatuses(home), []);
});

test('readLabBuildStatuses returns an empty list when state/ itself is absent, never throwing', async () => {
  const home = await mkdtemp(path.join(tmpdir(), 'fmc-lab-nostate-'));
  assert.deepEqual(await readLabBuildStatuses(home), []);
});

// createWorktreeSizeCache: the du-drain fix. A stubbed slow `du` (a `measure`
// override, since the real du -sk is what the audit found overlaps and stacks
// on a multi-GB worktree) proves the in-flight guard actually gates a second
// concurrent call rather than starting a second overlapping walk, and the TTL
// proves a fresh call within the window is served from cache instead of
// re-measuring at all.
function slowMeasureFactory(delayMs) {
  let calls = 0;
  let concurrent = 0;
  let maxConcurrent = 0;
  const fn = async (worktreePath) => {
    calls += 1;
    concurrent += 1;
    maxConcurrent = Math.max(maxConcurrent, concurrent);
    await new Promise((r) => setTimeout(r, delayMs));
    concurrent -= 1;
    return 12 * 1024 * 1024 * 1024; // 12GB, matching the audit's confirmed wedge case
  };
  return { fn, calls: () => calls, maxConcurrent: () => maxConcurrent };
}

test('worktree size cache never overlaps two measurements: a second get() while one is in flight returns immediately without measuring', async () => {
  const slow = slowMeasureFactory(200);
  const cache = createWorktreeSizeCache({ ttlMs: 60000, measure: slow.fn });

  const first = cache.get('/wt/a');
  // Fire a second call while the first is still in flight (before its 200ms
  // resolves) - this is exactly the overlapping-du-passes bug: the old code
  // had no guard, so a slow/huge worktree walk could still be running when
  // the next DU_INTERVAL_MS tick fired.
  await new Promise((r) => setTimeout(r, 20));
  const secondResult = await cache.get('/wt/a');
  await first;

  // The second call must not have started its own du measurement while the
  // first was in flight - it degrades to the last cached value (null, since
  // nothing had resolved yet) instead of overlapping.
  assert.equal(secondResult, null);
  assert.equal(slow.maxConcurrent(), 1);
  assert.equal(slow.calls(), 1);
});

test('worktree size cache in-flight guard applies across different worktree paths too (one pass at a time, not per-path)', async () => {
  const slow = slowMeasureFactory(150);
  const cache = createWorktreeSizeCache({ ttlMs: 60000, measure: slow.fn });

  const a = cache.get('/wt/a');
  await new Promise((r) => setTimeout(r, 10));
  const b = await cache.get('/wt/b');
  await a;

  assert.equal(b, null);
  assert.equal(slow.maxConcurrent(), 1);
  assert.equal(slow.calls(), 1);
});

test('worktree size cache reuses a cached value within the TTL instead of re-measuring', async () => {
  const slow = slowMeasureFactory(5);
  const cache = createWorktreeSizeCache({ ttlMs: 60000, measure: slow.fn });

  const first = await cache.get('/wt/a', 1000);
  assert.equal(first, 12 * 1024 * 1024 * 1024);
  assert.equal(slow.calls(), 1);

  // Well within the 60s TTL - must reuse the cached value, not measure again.
  const second = await cache.get('/wt/a', 1030);
  assert.equal(second, first);
  assert.equal(slow.calls(), 1);
});

test('worktree size cache re-measures once the TTL has elapsed', async () => {
  const slow = slowMeasureFactory(5);
  const cache = createWorktreeSizeCache({ ttlMs: 60000, measure: slow.fn });

  await cache.get('/wt/a', 1000);
  assert.equal(slow.calls(), 1);

  // Past the 60s TTL - a fresh measurement is expected.
  await cache.get('/wt/a', 1000 + 61000);
  assert.equal(slow.calls(), 2);
});

test('worktree size cache tracks separate worktree paths independently once not in flight', async () => {
  const slow = slowMeasureFactory(5);
  const cache = createWorktreeSizeCache({ ttlMs: 60000, measure: slow.fn });

  await cache.get('/wt/a', 1000);
  await cache.get('/wt/b', 1005);
  assert.equal(slow.calls(), 2);
  assert.equal(cache.peek('/wt/a'), 12 * 1024 * 1024 * 1024);
  assert.equal(cache.peek('/wt/b'), 12 * 1024 * 1024 * 1024);
});

test('worktree size cache returns null for a missing worktree path without measuring', async () => {
  const slow = slowMeasureFactory(5);
  const cache = createWorktreeSizeCache({ ttlMs: 60000, measure: slow.fn });
  assert.equal(await cache.get(null), null);
  assert.equal(await cache.get(undefined), null);
  assert.equal(await cache.get(''), null);
  assert.equal(slow.calls(), 0);
});
