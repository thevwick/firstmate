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

// Stub bin/fm-send.sh so the command-bridge tests can drive doSend's real
// sendCommand()->run() path without a real fm-send.sh or primary session.
// exitCode 0 simulates a successful send; non-zero simulates the "Enter
// swallowed / text not submitted" style failure this regression guards.
async function stubFmSend(bin, exitCode, stderrText) {
  const stub = path.join(bin, 'fm-send.sh');
  await writeFile(
    stub,
    `#!/usr/bin/env bash\n${stderrText ? `echo '${stderrText}' >&2\n` : ''}exit ${exitCode}\n`,
    { mode: 0o755 }
  );
  await chmod(stub, 0o755);
}

// Stub bin/fm-peek.sh so the FIRSTMATE ACTIVITY panel tests can drive the real
// readFirstmateActivity()->run() path without a real firstmate pane. Prints
// `lines` (one per array entry) to stdout and exits 0, mirroring fm-peek's own
// plain-text capture contract - never the styled composer-only reader.
async function stubFmPeek(bin, lines) {
  const stub = path.join(bin, 'fm-peek.sh');
  const body = lines.map((l) => `echo '${l.replace(/'/g, "'\\''")}'`).join('\n');
  await writeFile(stub, `#!/usr/bin/env bash\n${body}\nexit 0\n`, { mode: 0o755 });
  await chmod(stub, 0o755);
}

// Stub bin/fm-peek.sh to hang past the test's own patience, so a test can
// assert the render never blocks on a slow/wedged capture - the panel must
// show a stale-but-present frame (or the capturing placeholder), never freeze.
async function stubFmPeekSlow(bin, delaySeconds) {
  const stub = path.join(bin, 'fm-peek.sh');
  await writeFile(stub, `#!/usr/bin/env bash\nsleep ${delaySeconds}\necho 'too late'\n`, { mode: 0o755 });
  await chmod(stub, 0o755);
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

// Same idea for width: the stub's `.columns` is a fixed class getter (always
// 100), so an own-property override (which shadows a prototype getter) plus
// the resize event is what lets a test exercise the narrow-terminal degrade
// path (CARD_NARROW_WIDTH and below).
function setTestCols(stdout, columns) {
  Object.defineProperty(stdout, 'columns', { value: columns, configurable: true });
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

test('renders the empty-fleet resting state with IN FLIGHT\'s freed box showing FIRSTMATE ACTIVITY instead of a void', async () => {
  // An idle fleet used to leave IN FLIGHT's box showing only "Nothing in
  // flight" prose - wasted space exactly when firstmate itself may still be
  // working (reading, deciding, running commands). The panel now takes over
  // that freed box so the captain watches firstmate at a glance without ever
  // leaving the console, which is the whole point of this feature.
  const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
  const { lastFrame, unmount } = render(
    React.createElement(App, { bin, home })
  );
  const frame = await waitForFrame(lastFrame, /FIRSTMATE ACTIVITY/);
  assert.match(frame, /FIRSTMATE/);
  assert.match(frame, /0 in flight/);
  assert.match(frame, /FIRSTMATE ACTIVITY/);
  assert.doesNotMatch(frame, /\bIN FLIGHT\b/);
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

test('a card needing the captain shows a NEEDS YOU badge, not the raw state text', async () => {
  const snap = {
    schema: 'fm-fleet-snapshot.v1',
    tasks: [
      {
        id: 'audit-perms-x9',
        kind: 'ship',
        project: '/repos/yourapp',
        current_state: { state: 'needs-decision' },
        hints: { pending_decision: true, last_event_text: 'needs-decision: findings' },
        paths: { worktree: { path: '/nonexistent/wt' } },
        pr: { url: null },
      },
    ],
    backlog: { records: [] },
  };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
  const frame = await waitForFrame(lastFrame, /audit-perms-x9/);
  assert.match(frame, /NEEDS YOU/);
  unmount();
});

test('a wedged-but-not-escalated crew shows a STALE badge even though its group is working', async () => {
  // groupForTask files a raw 'stale' state under the 'working' group (a
  // crewmate that stopped reporting is not yet a captain decision), but the
  // badge must still say STALE - that distinction is the whole point of the
  // badge existing, so a stale card is never mistaken for a healthy one.
  const snap = {
    schema: 'fm-fleet-snapshot.v1',
    tasks: [
      {
        id: 'wedged-k4',
        kind: 'ship',
        project: '/repos/yourapp',
        current_state: { state: 'stale' },
        hints: {},
        paths: { worktree: { path: '/nonexistent/wt' } },
        pr: { url: null },
      },
    ],
    backlog: { records: [] },
  };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
  const frame = await waitForFrame(lastFrame, /wedged-k4/);
  // The card's own id/badge line must say STALE; the group header above it
  // legitimately still says "WORKING (1)" (groupForTask files a stale-but-
  // not-yet-escalated crew under 'working'), so scope the negative check to
  // the card's own line rather than the whole frame.
  const cardLine = frame.split('\n').find((l) => l.includes('wedged-k4'));
  assert.match(cardLine, /STALE/);
  assert.doesNotMatch(cardLine, /WORKING/);
  unmount();
});

test('the metadata row is labeled (age/seen), not a bare dot-joined run-on sentence', async () => {
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
        endpoint: { exists: true, target: 'default:w0:p2' },
      },
    ],
    backlog: { records: [] },
  };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
  const frame = await waitForFrame(lastFrame, /login-k3/);
  assert.match(frame, /age /);
  // The old design joined every metadata field with '  ·  ' into one run-on
  // sentence; the redesigned metadata row (the line with the branch chip)
  // uses plain double-space separation instead. Scope to that line - the
  // input line's own hint text legitimately uses ' · ' as a keybinding
  // separator and must not make this assertion a false negative.
  const metaLine = frame.split('\n').find((l) => l.includes('fm/login-k3'));
  assert.doesNotMatch(metaLine, / · /);
  unmount();
});

test('degraded state (a single in-flight card) still leaves QUEUED/RECENT DONE room, not a half-empty IN FLIGHT box', async () => {
  // The core layout fix: IN FLIGHT must hug its own small content instead of
  // reserving a fixed fair-share block, so the freed rows actually reach
  // QUEUED/RECENT DONE. Assert this structurally rather than by pixel-
  // counting: with only one card in flight and several queued/done records,
  // every one of those backlog rows must still be visible in a normal-height
  // terminal - if IN FLIGHT were still hogging a fixed 60% block, some of
  // these would be truncated behind a "+N more" marker instead.
  const snap = {
    schema: 'fm-fleet-snapshot.v1',
    tasks: [
      {
        id: 'solo-task-1',
        kind: 'ship',
        project: '/repos/yourapp',
        current_state: { state: 'working' },
        hints: {},
        paths: { worktree: { path: '/nonexistent/wt' } },
        pr: { url: null },
      },
    ],
    backlog: {
      records: [
        ...Array.from({ length: 4 }, (_, i) => ({
          structured: true,
          state: 'queued',
          id: `queued-${i}`,
          title: `queued item ${i}`,
          repo: 'yourapp',
        })),
      ],
    },
  };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, stdout, unmount } = render(React.createElement(App, { bin, home }));
  setTestRows(stdout, 40);
  const frame = await waitForFrame(lastFrame, /solo-task-1/);
  for (let i = 0; i < 4; i++) {
    assert.match(frame, new RegExp(`queued-${i}`), `queued-${i} should be visible, not hidden behind a fixed-height void`);
  }
  assert.doesNotMatch(frame, /more/);
  unmount();
});

test('the status strip stays a single line at a narrow width instead of wrapping onto a second row', async () => {
  // Ink's default row Box wraps overflowing children onto a second line
  // rather than clipping; that silently broke the "status strip is always
  // exactly one line" contract (and the fixed board-chrome row math every
  // other section's budget depends on) at a narrow terminal width before
  // StatusStrip gained flexWrap:'nowrap' + per-segment truncation. Assert the
  // frame's line count matches a normal-width render at the same height, so a
  // wrap regression shows up as an extra row rather than needing pixel-exact
  // string matching.
  const snap = { schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } };
  const { home, bin } = await makeHome(snap);
  const { lastFrame, stdout, unmount } = render(React.createElement(App, { bin, home }));
  setTestRows(stdout, 30);
  await waitForFrame(lastFrame, /FIRSTMATE ACTIVITY/);
  await waitForSettled(lastFrame);
  // Both widths stay below MIN_COLS_FOR_FULL_LAYOUT (70), so both renders use
  // the same stacked `compact` layout - isolating StatusStrip's own narrow
  // threshold (CARD_NARROW_WIDTH, 64) from the unrelated full/compact board
  // switch, which legitimately changes total row count on its own. Settle
  // fully after each resize before reading a frame, or a read can race the
  // resize and compare a stale pre-resize frame instead.
  setTestCols(stdout, 69);
  await waitForSettled(lastFrame);
  const wideLineCount = lastFrame().split('\n').length;
  setTestCols(stdout, 50);
  await waitForSettled(lastFrame);
  const narrowLineCount = lastFrame().split('\n').length;
  assert.equal(narrowLineCount, wideLineCount, 'narrowing the terminal at a fixed height must not add a wrapped row');
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
  assert.match(frame, /FIRSTMATE ACTIVITY/);
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
    await waitForFrame(lastFrame, /FIRSTMATE ACTIVITY/);
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

// Regression coverage for the runaway-input bug: a FAILED send used to leave
// the typed command sitting in the input line, so a captain who kept typing
// (or a repeat Enter while the send was still in flight) compounded it into a
// screen-filling wall ("hellohellohello..."). doSend now clears the input the
// moment a send starts, whether it ultimately succeeds or fails, and guards
// against re-entrant sends with sendingRef.
test('a FAILED send still clears the input line, not leaving the failed command sitting in the buffer', async () => {
  const keys = ['FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION'];
  const prev = {};
  for (const k of keys) {
    prev[k] = process.env[k];
    delete process.env[k];
  }
  process.env.TMUX_PANE = '%3';
  try {
    const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
    await stubFmSend(bin, 1, 'Enter swallowed / text not submitted');
    const { lastFrame, stdin, unmount } = render(React.createElement(App, { bin, home }));
    await waitForFrame(lastFrame, /FIRSTMATE ACTIVITY/);
    await waitForSettled(lastFrame);

    stdin.write('hello');
    await waitForFrame(lastFrame, /hello/);
    stdin.write('\r');
    const failedFrame = await waitForFrame(lastFrame, /send failed/);
    assert.match(failedFrame, /send failed/);
    // The input line is the row starting with the '❯ ' prompt; it must show
    // no leftover "hello" once the failed send has been reported.
    const inputLine = failedFrame.split('\n').find((l) => l.includes('❯'));
    assert.doesNotMatch(inputLine, /hello/);
    unmount();
  } finally {
    for (const k of keys) {
      if (prev[k] !== undefined) process.env[k] = prev[k];
      else delete process.env[k];
    }
  }
});

test('a successful send still clears the input line', async () => {
  const keys = ['FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION'];
  const prev = {};
  for (const k of keys) {
    prev[k] = process.env[k];
    delete process.env[k];
  }
  process.env.TMUX_PANE = '%3';
  try {
    const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
    await stubFmSend(bin, 0, '');
    const { lastFrame, stdin, unmount } = render(React.createElement(App, { bin, home }));
    await waitForFrame(lastFrame, /FIRSTMATE ACTIVITY/);
    await waitForSettled(lastFrame);

    stdin.write('status x');
    await waitForFrame(lastFrame, /status x/);
    stdin.write('\r');
    const sentFrame = await waitForFrame(lastFrame, /sent: status x/);
    assert.match(sentFrame, /sent: status x/);
    const inputLine = sentFrame.split('\n').find((l) => l.includes('❯'));
    assert.doesNotMatch(inputLine, /status x/);
    unmount();
  } finally {
    for (const k of keys) {
      if (prev[k] !== undefined) process.env[k] = prev[k];
      else delete process.env[k];
    }
  }
});

test('a second Enter while a send is still in flight does not start a second send', async () => {
  const keys = ['FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION'];
  const prev = {};
  for (const k of keys) {
    prev[k] = process.env[k];
    delete process.env[k];
  }
  process.env.TMUX_PANE = '%3';
  try {
    const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
    // A slow fm-send.sh that stays in flight long enough for a second Enter to
    // race it, and that records one line per invocation so the test can assert
    // on the actual call count rather than racing UI message text.
    const stub = path.join(bin, 'fm-send.sh');
    const callLog = path.join(bin, 'send-calls.log');
    await writeFile(
      stub,
      `#!/usr/bin/env bash\necho "call $$" >> '${callLog}'\nsleep 0.5\nexit 1\n`,
      { mode: 0o755 }
    );
    await chmod(stub, 0o755);
    const { lastFrame, stdin, unmount } = render(React.createElement(App, { bin, home }));
    await waitForFrame(lastFrame, /FIRSTMATE ACTIVITY/);
    await waitForSettled(lastFrame);

    stdin.write('hello');
    await waitForFrame(lastFrame, /hello/);
    stdin.write('\r');
    await waitForFrame(lastFrame, /sending: hello/);
    // Fire several more Enters while the first send is still in flight (the
    // sleep gives ample margin). None of these may start a second doSend.
    stdin.write('\r');
    stdin.write('\r');
    stdin.write('\r');
    const failedFrame = await waitForFrame(lastFrame, /send failed/, 3000);
    assert.match(failedFrame, /send failed/);
    // Give any wrongly-started second call a moment to have written its line.
    await new Promise((r) => setTimeout(r, 300));
    const { readFile } = await import('node:fs/promises');
    const calls = (await readFile(callLog, 'utf8')).trim().split('\n').filter(Boolean);
    assert.equal(calls.length, 1, `expected exactly one fm-send.sh invocation, got ${calls.length}`);
    unmount();
  } finally {
    for (const k of keys) {
      if (prev[k] !== undefined) process.env[k] = prev[k];
      else delete process.env[k];
    }
  }
});

// Regression coverage for the ACTUAL root cause: handleInput's useCallback
// depended on `input` (and other per-render-changing values), so `input`
// changing on every keystroke recreated handleInput on every keystroke,
// which churned Ink's useInput stdin listener (detach + reattach) on every
// character. A keystroke landing in that reattach gap could be delivered to
// more than one listener instance, appending more than once per keypress and
// compounding exponentially - the actual mechanism behind the reported
// "hellohellohello..." wall, independent of the doSend clear/guard fix above.
test('a single keypress appends exactly one character, not two or more', async () => {
  const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
  const { lastFrame, stdin, unmount } = render(React.createElement(App, { bin, home }));
  await waitForFrame(lastFrame, /FIRSTMATE ACTIVITY/);
  await waitForSettled(lastFrame);

  stdin.write('a');
  await waitForFrame(lastFrame, /❯ a/);
  await waitForSettled(lastFrame);
  const frame = lastFrame();
  const inputLine = frame.split('\n').find((l) => l.includes('❯')) || '';
  // Exactly one 'a' after the prompt glyph, not 'aa' or more. Match the
  // prompt-to-end-of-input span rather than counting 'a' anywhere on the
  // line, since dim hint text elsewhere on the line is irrelevant here (the
  // input line has no other text at this point).
  assert.match(inputLine, /❯ a\s/);
  assert.doesNotMatch(inputLine, /❯ aa/);
  unmount();
});

test('typing N characters yields exactly N characters in the input, across many keystrokes and re-renders', async () => {
  // Reattach-on-every-keystroke, if it regressed, would show up as
  // super-linear growth well before 20 keystrokes; this also spans the
  // REFRESH_INTERVAL_MS poll tick so an in-flight snapshot re-render landing
  // mid-typing is exercised too, not just a burst of keystrokes with no
  // competing re-render.
  const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
  const { lastFrame, stdin, unmount } = render(React.createElement(App, { bin, home }));
  await waitForFrame(lastFrame, /FIRSTMATE ACTIVITY/);
  await waitForSettled(lastFrame);

  const word = 'abcdefghijklmnopqrst'; // 20 distinct characters
  for (const ch of word) {
    stdin.write(ch);
    // eslint-disable-next-line no-await-in-loop
    await new Promise((r) => setTimeout(r, 20));
  }
  await waitForFrame(lastFrame, new RegExp(`❯ ${word}`));
  const frame = lastFrame();
  const inputLine = frame.split('\n').find((l) => l.includes('❯')) || '';
  const afterPrompt = inputLine.split('❯ ')[1] || '';
  // Strip the box's trailing border/padding, not just whitespace - the input
  // line is drawn inside a bordered box, so anything after the typed text is
  // chrome (padding spaces + the closing "│"), never part of the buffer.
  const typed = afterPrompt.replace(/[\s│]+$/, '');
  assert.equal(typed, word, `expected exactly "${word}" (${word.length} chars), got "${typed}" (${typed.length} chars)`);
  unmount();
});

// FIRSTMATE ACTIVITY panel: a live tail of firstmate's OWN pane, reusing the
// SAME resolved supervisor target the command bridge sends into, so the
// captain watches firstmate work without leaving the console.

test('FIRSTMATE ACTIVITY renders the captured pane lines, in an idle fleet\'s freed IN FLIGHT box', async () => {
  const keys = ['FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION'];
  const prev = {};
  for (const k of keys) {
    prev[k] = process.env[k];
    delete process.env[k];
  }
  process.env.TMUX_PANE = '%3';
  try {
    const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
    await stubFmPeek(bin, ['reading src/app.js', 'running fm-crew-state.sh fix-login-k3', 'deciding next step']);
    // A taller terminal so the panel's own row budget (it hugs IN FLIGHT's
    // freed box, same discipline as every other section) has room for all 3
    // lines rather than capping them behind a "+N more" marker - the default
    // 24-row test stub is realistic for a cramped terminal, but this test is
    // about the panel showing captured content, not about capRows truncation
    // (covered by its own tests elsewhere).
    const { lastFrame, stdout, unmount } = render(React.createElement(App, { bin, home }));
    setTestRows(stdout, 40);
    const frame = await waitForFrame(lastFrame, /reading src\/app\.js/);
    assert.match(frame, /FIRSTMATE ACTIVITY/);
    assert.match(frame, /reading src\/app\.js/);
    assert.match(frame, /running fm-crew-state\.sh fix-login-k3/);
    assert.match(frame, /deciding next step/);
    unmount();
  } finally {
    for (const k of keys) {
      if (prev[k] !== undefined) process.env[k] = prev[k];
      else delete process.env[k];
    }
  }
});

test('FIRSTMATE ACTIVITY tails newest-at-bottom and drops older lines beyond its row budget', async () => {
  const keys = ['FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION'];
  const prev = {};
  for (const k of keys) {
    prev[k] = process.env[k];
    delete process.env[k];
  }
  process.env.TMUX_PANE = '%3';
  try {
    const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
    // More lines than any reasonable panel row budget at a 24-row test
    // terminal, so the oldest ("line 0") must be dropped and the newest
    // ("line 39") must survive, in that relative top-to-bottom order.
    const captured = Array.from({ length: 40 }, (_, i) => `line ${i}`);
    await stubFmPeek(bin, captured);
    const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
    const frame = await waitForFrame(lastFrame, /line 39/);
    assert.match(frame, /line 39/, 'the newest captured line must be visible');
    assert.doesNotMatch(frame, /line 0\b/, 'the oldest captured line must have been trimmed, not the newest');
    const lineIndexOf = (needle) => frame.split('\n').findIndex((l) => l.includes(needle));
    const idx38 = lineIndexOf('line 38');
    const idx39 = lineIndexOf('line 39');
    if (idx38 !== -1) {
      assert.ok(idx39 > idx38, 'newest line must render below an earlier surviving line, not above it');
    }
    unmount();
  } finally {
    for (const k of keys) {
      if (prev[k] !== undefined) process.env[k] = prev[k];
      else delete process.env[k];
    }
  }
});

test('FIRSTMATE ACTIVITY shows a clear not-resolved placeholder when no supervisor target can be found, never guessing a pane', async () => {
  const keys = ['FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION'];
  const prev = {};
  for (const k of keys) {
    prev[k] = process.env[k];
    delete process.env[k];
  }
  try {
    const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
    const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
    // The panel briefly shows "capturing..." on first paint, before the async
    // side-channel's effect lands the not-resolved error - wait for the actual
    // placeholder text rather than just the panel title, or this test could
    // pass on the transient frame instead of the fail-closed state it exists
    // to verify. This mirrors the command bridge's own fail-closed message
    // (bridge.js's resolveSupervisor) - the console never guesses a pane.
    const frame = await waitForFrame(lastFrame, /FM_SUPERVISOR_TARGET/);
    assert.match(frame, /FIRSTMATE ACTIVITY/);
    assert.match(frame, /FM_SUPERVISOR_TARGET/);
    unmount();
  } finally {
    for (const k of keys) {
      if (prev[k] !== undefined) process.env[k] = prev[k];
    }
  }
});

test('a slow/wedged pane capture never blocks the render - the board keeps drawing while capture is in flight', async () => {
  const keys = ['FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION'];
  const prev = {};
  for (const k of keys) {
    prev[k] = process.env[k];
    delete process.env[k];
  }
  process.env.TMUX_PANE = '%3';
  try {
    const { home, bin } = await makeHome({ schema: 'fm-fleet-snapshot.v1', tasks: [], backlog: { records: [] } });
    // fm-peek.sh sleeps far longer than the console's own capture timeout
    // (10s in readFirstmateActivity) and the test's own patience - the board
    // must still render immediately, showing the capturing placeholder rather
    // than freezing until the (killed) capture would have returned.
    await stubFmPeekSlow(bin, 30);
    const { lastFrame, unmount } = render(React.createElement(App, { bin, home }));
    const frame = await waitForFrame(lastFrame, /FIRSTMATE ACTIVITY/, 2000);
    assert.match(frame, /FIRSTMATE ACTIVITY/);
    // The rest of the board must have rendered too - the slow capture must
    // not have wedged the whole app while it was still in flight.
    assert.match(frame, /QUEUED/);
    assert.match(frame, /RECENT DONE/);
    assert.doesNotMatch(frame, /too late/);
    unmount();
  } finally {
    for (const k of keys) {
      if (prev[k] !== undefined) process.env[k] = prev[k];
      else delete process.env[k];
    }
  }
});

test('FIRSTMATE ACTIVITY still shows in-flight cards alongside a compact activity strip at a tall terminal', async () => {
  const keys = ['FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION'];
  const prev = {};
  for (const k of keys) {
    prev[k] = process.env[k];
    delete process.env[k];
  }
  process.env.TMUX_PANE = '%3';
  try {
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
        },
      ],
      backlog: { records: [] },
    };
    const { home, bin } = await makeHome(snap);
    await stubFmPeek(bin, ['firstmate is deciding what to do next']);
    const { lastFrame, stdout, unmount } = render(React.createElement(App, { bin, home }));
    setTestRows(stdout, 50);
    const frame = await waitForFrame(lastFrame, /firstmate is deciding what to do next/);
    // Both the fleet board's own IN FLIGHT card and the activity strip must be
    // visible at once - the captain sees the fleet AND firstmate working,
    // never one at the cost of the other.
    assert.match(frame, /login-k3/);
    assert.match(frame, /IN FLIGHT/);
    assert.match(frame, /FIRSTMATE ACTIVITY/);
    assert.match(frame, /firstmate is deciding what to do next/);
    unmount();
  } finally {
    for (const k of keys) {
      if (prev[k] !== undefined) process.env[k] = prev[k];
      else delete process.env[k];
    }
  }
});
