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

// ink-testing-library renders into a fixed-width virtual terminal. Assertions
// below target the app's own short, non-wrapping content (section titles, the
// empty-fleet message, the bridge warning) rather than exact column layout,
// so they verify behavior without being brittle about width.

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

test('renders the empty-fleet resting state with the board filled by QUEUED/RECENT DONE, not a void', async () => {
  const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
  const { lastFrame, unmount } = render(
    React.createElement(App, { bin, home })
  );
  const frame = await waitForFrame(lastFrame, /IN FLIGHT/);
  assert.match(frame, /FIRSTMATE/);
  assert.match(frame, /0 in flight/);
  assert.match(frame, /IN FLIGHT/);
  assert.match(frame, /healthy resting state/);
  assert.match(frame, /QUEUED/);
  assert.match(frame, /RECENT DONE/);
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

test('regression: multiple groups plus backlog queued/done rows never corrupt card id lines', async () => {
  // Ink has no scrolling; a fixed-height flex tree fed more rows than it has
  // space for corrupted this exact combination during development (multiple
  // IN FLIGHT groups + non-empty QUEUED + non-empty RECENT DONE at once) -
  // every card's id-badge line silently rendered blank while its detail line
  // still showed. Guard against that regressing: every card's id must be
  // visible whenever the board renders it at all.
  const snap = {
    schema: 'fm-fleet-snapshot.v1',
    tasks: [
      {
        id: 'fix-login-k3',
        kind: 'ship',
        project: '/repos/yourapp',
        current_state: { state: 'working' },
        hints: { last_event_text: 'implementing fix' },
        paths: { worktree: { path: '/nonexistent/wt1' } },
        pr: { url: null },
      },
      {
        id: 'audit-perms-x9',
        kind: 'ship',
        project: '/repos/yourapp',
        current_state: { state: 'needs-decision' },
        hints: { pending_decision: true, last_event_text: 'needs-decision: findings' },
        paths: { worktree: { path: '/nonexistent/wt2' } },
        pr: { url: null },
      },
    ],
    backlog: {
      records: [
        { structured: true, state: 'queued', id: 'refactor-db-q1', title: 'refactor db layer', repo: 'yourapp' },
        { structured: true, state: 'done', id: 'old-fix-1', title: 'fixed the old bug', completion: { verb: 'merged', date: '2026-07-14' } },
      ],
    },
  };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
  const frame = await waitForFrame(lastFrame, /audit-perms-x9/);
  assert.match(frame, /IN FLIGHT/);
  assert.match(frame, /NEEDS YOU/);
  assert.match(frame, /audit-perms-x9/);
  assert.match(frame, /QUEUED/);
  assert.match(frame, /RECENT DONE/);
  unmount();
});

test('degraded state: no in-flight tasks still fills the board with QUEUED and RECENT DONE rows', async () => {
  const snap = {
    schema: 'fm-fleet-snapshot.v1',
    tasks: [],
    backlog: {
      records: [
        { structured: true, state: 'queued', id: 'next-thing', title: 'do the next thing', repo: 'yourapp' },
        { structured: true, state: 'done', id: 'shipped-x', title: 'shipped x', completion: { verb: 'merged', date: '2026-07-01' } },
      ],
    },
  };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
  const frame = await waitForFrame(lastFrame, /next-thing/);
  assert.match(frame, /0 in flight/);
  assert.match(frame, /healthy resting state/);
  assert.match(frame, /next-thing/);
  assert.match(frame, /shipped-x/);
  unmount();
});

test('auto-detects the bridge target from TMUX_PANE when no explicit FM_SUPERVISOR_TARGET is set', async () => {
  const keys = ['FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION'];
  const prev = {};
  for (const k of keys) {
    prev[k] = process.env[k];
    delete process.env[k];
  }
  process.env.TMUX_PANE = '%3';
  try {
    const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
    const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
    await waitForFrame(lastFrame, /IN FLIGHT/);
    const frame = lastFrame();
    assert.doesNotMatch(frame, /command bridge disabled/);
    unmount();
  } finally {
    for (const k of keys) {
      if (prev[k] !== undefined) process.env[k] = prev[k];
      else delete process.env[k];
    }
  }
});

test('shows the command-bridge-disabled warning when nothing resolves a supervisor target', async () => {
  // Auto-detect now also consults TMUX_PANE / HERDR_ENV+HERDR_PANE_ID (mirroring
  // the afk daemon), so this test's own runtime env (which may legitimately have
  // one of those set, e.g. a herdr-backed crewmate pane) must be cleared too, or
  // the bridge would resolve to THIS process's own pane instead of showing the
  // disabled warning the test expects.
  const keys = ['FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION'];
  const prev = {};
  for (const k of keys) {
    prev[k] = process.env[k];
    delete process.env[k];
  }
  try {
    const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
    const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
    const frame = await waitForFrame(lastFrame, /command bridge disabled/);
    assert.match(frame, /command bridge disabled/);
    unmount();
  } finally {
    for (const k of keys) {
      if (prev[k] !== undefined) process.env[k] = prev[k];
    }
  }
});
