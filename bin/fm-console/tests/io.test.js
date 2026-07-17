// Unit tests for io.js's gh-axi-backed PR-checks reader. Stubs a fake gh-axi
// on PATH (same convention render.test.js uses for fm-fleet-snapshot.sh /
// fm-send.sh / fm-peek.sh) so the mapping logic is exercised against real
// gh-axi output shapes without a network call or a real PR.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { parsePrUrl, readPrChecks } from '../src/io.js';

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
