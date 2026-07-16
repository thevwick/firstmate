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

// ink-testing-library's stdout stub has no `.rows` getter, so the app's own
// dims fallback (`stdout.rows || 24`) always measures a short 24-row terminal
// in tests, unless a test opts into a taller one - the app reacts to a real
// terminal resize event, so patch `.rows` as an own property (which shadows
// nothing here, since the stub never defines one) and fire that same event.
function setTestRows(stdout, rows) {
  Object.defineProperty(stdout, 'rows', { value: rows, configurable: true });
  stdout.emit('resize');
}

// Poll until the frame stops changing for two consecutive checks. Right after
// first paint, the app's own async side-channels (snapshot re-read, age/du/PR
// mtime effects) are still landing renders; Ink's useInput effect briefly
// detaches and reattaches its stdin listener across some of those renders
// (its effect is keyed on the memoized input-handler's identity, which still
// changes when interaction state changes), and a keystroke sent into that
// exact gap is silently dropped - a real captain never types within
// milliseconds of first paint, so wait for things to settle first, the same
// way an interactive session would.
async function waitForSettled(lastFrame, timeoutMs = 4000) {
  const start = Date.now();
  let prev = lastFrame();
  for (;;) {
    await new Promise((r) => setTimeout(r, 60));
    const cur = lastFrame();
    if (cur === prev) return cur;
    prev = cur;
    if (Date.now() - start > timeoutMs) return cur;
  }
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

test('a card with harness/model/effort shows the profile chip and its branch', async () => {
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
        harness: 'claude',
        model: 'opus',
        effort: 'high',
      },
    ],
    backlog: { records: [] },
  };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
  const frame = await waitForFrame(lastFrame, /login-k3/);
  assert.match(frame, /claude\/opus high/);
  assert.match(frame, /fm\/login-k3/);
  unmount();
});

test('a card renders gracefully with no harness/model/effort/branch/pr/endpoint recorded', async () => {
  // Older or incomplete meta records may omit these fields entirely; the card
  // must still render its required lines (id, repo, kind, status) rather than
  // showing a blank chip or crashing on an undefined field.
  const snap = {
    schema: 'fm-fleet-snapshot.v1',
    tasks: [
      {
        id: 'scout-audit-x9',
        kind: 'scout',
        project: '/repos/yourapp',
        current_state: { state: 'unknown' },
        hints: {},
        paths: {},
        pr: { url: null },
      },
    ],
    backlog: { records: [] },
  };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
  const frame = await waitForFrame(lastFrame, /scout-audit-x9/);
  assert.match(frame, /scout-audit-x9/);
  assert.match(frame, /yourapp/);
  assert.doesNotMatch(frame, /fm\/scout-audit-x9/);
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
  await waitForSettled(lastFrame);
  // Select the first task (arrow down), then open the menu (Tab).
  stdin.write('[B'); // down arrow
  await waitForFrame(lastFrame, /Tab quick-actions/);
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
  const { lastFrame, stdout, unmount } = render(React.createElement(App, { bin, home }));
  // Each card is now 3 rows (health/model line, size/age/branch line, status
  // line); two IN FLIGHT groups of one card each need more than the stub's
  // default 24-row terminal to fit alongside QUEUED/RECENT DONE, so size this
  // test to a realistic full-screen console rather than a cramped one.
  setTestRows(stdout, 50);
  const frame = await waitForFrame(lastFrame, /audit-perms-x9/);
  assert.match(frame, /IN FLIGHT/);
  assert.match(frame, /NEEDS YOU/);
  assert.match(frame, /audit-perms-x9/);
  assert.match(frame, /QUEUED/);
  assert.match(frame, /RECENT DONE/);
  unmount();
});

test('regression: capRows truncates multi-row cards in order across groups, never skipping an earlier one to admit a later one', async () => {
  // Cards are now 3 rows each (CARD_ROW_HEIGHT), so the section's row-capping
  // logic (capRows in app.js) must budget by total row HEIGHT, not entry
  // count. An earlier, buggy height-aware version of capRows reserved a "+N
  // more" marker row only conditionally instead of unconditionally once over
  // budget, which let it stop consuming entries out of order: with a
  // needs-you group (1 card) followed by a working group (3 cards) at
  // exactly the row budget this scenario produces, the buggy version dropped
  // the FIRST two working cards but kept the THIRD one - reordering which
  // cards were visible - instead of dropping all three (none fit once the
  // needs-you card and both group labels are counted). Assert the earliest
  // needs-you card survives and no later working card silently takes an
  // earlier one's place.
  const snap = {
    schema: 'fm-fleet-snapshot.v1',
    tasks: [
      {
        id: 'needs-you-0',
        kind: 'ship',
        project: '/repos/yourapp',
        current_state: { state: 'needs-decision' },
        hints: { pending_decision: true, last_event_text: 'needs-decision: findings' },
        paths: { worktree: { path: '/nonexistent/wt-ny0' } },
        pr: { url: null },
      },
      ...Array.from({ length: 3 }, (_, i) => ({
        id: `working-${i}`,
        kind: 'ship',
        project: '/repos/yourapp',
        current_state: { state: 'working' },
        hints: { last_event_text: `working on task ${i}` },
        paths: { worktree: { path: `/nonexistent/wt-w${i}` } },
        pr: { url: null },
      })),
    ],
    backlog: { records: [] },
  };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, stdout, unmount } = render(React.createElement(App, { bin, home }));
  setTestRows(stdout, 30);
  const frame = await waitForFrame(lastFrame, /needs-you-0/);
  assert.match(frame, /needs-you-0/);
  assert.match(frame, /more/);
  // The discriminating check: a later working card must never appear while an
  // earlier one is dropped. All three are equally 3 rows, so a correct
  // in-order cap either keeps none of them (this scenario) or keeps a prefix
  // (working-0, then working-1) - it must never keep working-2 alone.
  assert.doesNotMatch(frame, /working-2/);
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
