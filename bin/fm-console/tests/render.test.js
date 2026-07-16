// Render tests using ink-testing-library. These verify the app boots and draws
// meaningful frames without a real TTY. We point it at a temp firstmate home
// with a fake bin/ whose fm-fleet-snapshot.sh prints a canned snapshot, so the
// render is deterministic and touches no real fleet.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, mkdir, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import React from 'react';
import { render } from 'ink-testing-library';
import App from '../src/app.js';

// ink-testing-library renders into a fixed-width virtual terminal, so the header
// line wraps. Assertions below target the app's own short, non-wrapping content
// (group headers, the empty-fleet message, the bridge warning) rather than the
// wrapped header, so they verify behavior without being brittle about columns.

// Build a throwaway firstmate home + bin with a stub snapshot script.
async function makeHome(snapshotJson) {
  const home = await mkdtemp(path.join(tmpdir(), 'fmc-'));
  const bin = path.join(home, 'bin');
  await mkdir(bin, { recursive: true });
  await mkdir(path.join(home, 'state'), { recursive: true });
  const stub = path.join(bin, 'fm-fleet-snapshot.sh');
  // A tiny stub that echoes the canned JSON regardless of args.
  await writeFile(
    stub,
    `#!/usr/bin/env bash\ncat <<'JSON'\n${JSON.stringify(snapshotJson)}\nJSON\n`,
    { mode: 0o755 }
  );
  await chmod(stub, 0o755);
  return { home, bin };
}

// Poll the current frame until it matches, rather than sleeping a fixed amount.
// The first paint waits on an async subprocess (the snapshot stub), whose timing
// varies under CPU load, so a fixed sleep is flaky; polling is deterministic.
async function waitForFrame(lastFrame, re, timeoutMs = 4000) {
  const start = Date.now();
  for (;;) {
    const frame = lastFrame();
    if (re.test(frame)) return frame;
    if (Date.now() - start > timeoutMs) return frame;
    await new Promise((r) => setTimeout(r, 40));
  }
}

test('renders the empty-fleet resting-state message', async () => {
  const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
  const { lastFrame, unmount } = render(
    React.createElement(App, { bin, home })
  );
  const frame = await waitForFrame(lastFrame, /Fleet is empty/);
  assert.match(frame, /Fleet is empty/);
  assert.match(frame, /select a task/);
  unmount();
});

test('renders a task card grouped by state with its id and repo', async () => {
  const snap = {
    schema: 'fm-fleet-snapshot.v1',
    tasks: [
      {
        id: 'login-k3',
        kind: 'ship',
        project: '/repos/yourapp',
        current_state: { state: 'working', detail: 'harness busy' },
        hints: { last_event_text: 'implementing fix' },
        paths: { worktree: { path: '/nonexistent/wt' } },
        pr: { url: null },
        endpoint: { exists: true },
      },
    ],
    backlog: { records: [{ state: 'queued', blocked_by: null }] },
  };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
  const frame = await waitForFrame(lastFrame, /login-k3/);
  assert.match(frame, /login-k3/);
  assert.match(frame, /yourapp/);
  assert.match(frame, /WORKING/);
  unmount();
});

test('Tab opens the quick-action menu for a selected task', async () => {
  const snap = {
    schema: 'fm-fleet-snapshot.v1',
    tasks: [
      {
        id: 'login-k3',
        kind: 'ship',
        project: '/repos/yourapp',
        current_state: { state: 'working' },
        hints: {},
        paths: { worktree: { path: '/nonexistent/wt' } },
        pr: { url: null },
        endpoint: { exists: true },
      },
    ],
    backlog: { records: [] },
  };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, stdin, unmount } = render(React.createElement(App, { bin, home }));
  await waitForFrame(lastFrame, /login-k3/);
  // Select the first task (arrow down), then open the menu (Tab).
  stdin.write('[B'); // down arrow
  await new Promise((r) => setTimeout(r, 60));
  stdin.write('\t');
  const frame = await waitForFrame(lastFrame, /quick-actions for/);
  assert.match(frame, /quick-actions for login-k3/);
  assert.match(frame, /merge/);
  unmount();
});

test('shows the command-bridge-disabled warning when no supervisor target is set', async () => {
  const prev = process.env.FM_SUPERVISOR_TARGET;
  delete process.env.FM_SUPERVISOR_TARGET;
  try {
    const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
    const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
    const frame = await waitForFrame(lastFrame, /command bridge disabled/);
    assert.match(frame, /command bridge disabled/);
    unmount();
  } finally {
    if (prev !== undefined) process.env.FM_SUPERVISOR_TARGET = prev;
  }
});
