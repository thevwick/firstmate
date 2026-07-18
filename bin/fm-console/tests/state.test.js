// Unit tests for the pure state-derivation logic. Run with `node --test`.
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  extractTicket,
  groupForTask,
  buildCard,
  shortRepo,
  groupCards,
  backlogCounts,
  watcherAlive,
  buildHeader,
  boardSections,
  queuedBacklogRecords,
  recentDoneBacklogRecords,
  computeRowBudget,
  inFlightContentRowCount,
  healthLevel,
  formatProfile,
  branchForTask,
  firstmateActivityLines,
  buildLabBuildCard,
  buildLabBuildCards,
} from '../src/state.js';

test('extractTicket finds a generic ticket key in branch or brief', () => {
  assert.equal(extractTicket(['fm/SMM-2808-fix-login']), 'SMM-2808');
  assert.equal(extractTicket([null, 'work on DPW-11976 today']), 'DPW-11976');
  assert.equal(extractTicket(['ABC-1']), 'ABC-1');
});

test('extractTicket returns null when no ticket is present (poc/* work is first-class)', () => {
  assert.equal(extractTicket(['poc/smm-expo-updates-ota']), null);
  assert.equal(extractTicket(['fm/fm-console-tui-x7']), null);
  assert.equal(extractTicket([undefined, '', null]), null);
});

test('extractTicket does not match lowercase or bare numbers', () => {
  assert.equal(extractTicket(['abc-123']), null);
  assert.equal(extractTicket(['12345']), null);
});

test('groupForTask maps states to console groups with correct precedence', () => {
  assert.equal(groupForTask({ hints: { pending_decision: true }, current_state: { state: 'working' } }), 'needs-you');
  assert.equal(groupForTask({ hints: { blocked_event: true }, current_state: { state: 'working' } }), 'blocked');
  assert.equal(groupForTask({ current_state: { state: 'needs-decision' } }), 'needs-you');
  assert.equal(groupForTask({ current_state: { state: 'failed' } }), 'needs-you');
  assert.equal(groupForTask({ current_state: { state: 'done' } }), 'done');
  assert.equal(groupForTask({ current_state: { state: 'ready' } }), 'ready');
  assert.equal(groupForTask({ current_state: { state: 'working' } }), 'working');
  assert.equal(groupForTask({ current_state: { state: 'ci' } }), 'working');
});

test('groupForTask defaults unknown state to working (visible, not hidden)', () => {
  assert.equal(groupForTask({ current_state: { state: 'weird' } }), 'working');
  assert.equal(groupForTask({}), 'working');
});

test('shortRepo reduces an absolute project path to its basename', () => {
  assert.equal(shortRepo('/Users/x/sitemate/firstmate'), 'firstmate');
  assert.equal(shortRepo('/a/b/c/'), 'c');
  assert.equal(shortRepo(''), '');
  assert.equal(shortRepo(null), '');
});

test('buildCard threads du/pr side-channels and derives fields', () => {
  const task = {
    id: 'login-k3',
    kind: 'ship',
    project: '/repos/yourapp',
    current_state: { state: 'working', detail: 'harness busy' },
    hints: { last_event_text: 'implementing fix' },
    paths: { worktree: { path: '/wt/login-k3' } },
    pr: { url: 'https://github.com/o/r/pull/5' },
    harness: 'claude',
    model: 'sonnet',
    effort: 'high',
    endpoint: { target: 'default:wZ:p2' },
  };
  const card = buildCard(task, { duBytes: 2048, prChecks: 'passing', ageSecs: 360, lastEventSecs: 40 });
  assert.equal(card.id, 'login-k3');
  assert.equal(card.repo, 'yourapp');
  assert.equal(card.group, 'working');
  assert.equal(card.worktreePath, '/wt/login-k3');
  assert.equal(card.duBytes, 2048);
  assert.equal(card.prUrl, 'https://github.com/o/r/pull/5');
  assert.equal(card.prChecks, 'passing');
  assert.equal(card.lastEvent, 'implementing fix');
  assert.equal(card.harness, 'claude');
  assert.equal(card.model, 'sonnet');
  assert.equal(card.effort, 'high');
  assert.equal(card.profile, 'claude/sonnet high');
  assert.equal(card.endpointTarget, 'default:wZ:p2');
  assert.equal(card.branch, 'fm/login-k3');
  assert.equal(card.ageSecs, 360);
  assert.equal(card.lastEventSecs, 40);
  assert.equal(card.health, 'green');
});

test('buildCard defaults du/pr/model/age fields to null or empty when not yet computed', () => {
  const card = buildCard({ id: 'x', current_state: { state: 'working' } });
  assert.equal(card.duBytes, null);
  assert.equal(card.prChecks, null);
  assert.equal(card.ticket, null);
  assert.equal(card.harness, '');
  assert.equal(card.model, '');
  assert.equal(card.effort, '');
  assert.equal(card.profile, null);
  assert.equal(card.endpointTarget, null);
  assert.equal(card.branch, null);
  assert.equal(card.ageSecs, null);
  assert.equal(card.lastEventSecs, null);
});

test('branchForTask derives fm/<id> for ship tasks only', () => {
  assert.equal(branchForTask({ kind: 'ship', id: 'login-k3' }), 'fm/login-k3');
  assert.equal(branchForTask({ kind: 'scout', id: 'audit-x9' }), null);
  assert.equal(branchForTask({ kind: 'secondmate', id: 'triage' }), null);
});

test('formatProfile shows harness/model with effort appended only when not default', () => {
  assert.equal(formatProfile('claude', 'haiku', 'default'), 'claude/haiku');
  assert.equal(formatProfile('claude', 'haiku', ''), 'claude/haiku');
  assert.equal(formatProfile('claude', 'opus', 'high'), 'claude/opus high');
  assert.equal(formatProfile('claude', '', ''), 'claude');
  assert.equal(formatProfile('claude', 'default', ''), 'claude');
  assert.equal(formatProfile('', 'sonnet', ''), null);
  assert.equal(formatProfile(null, null, null), null);
});

test('healthLevel maps needs-you/blocked to red regardless of raw state', () => {
  assert.equal(healthLevel({ group: 'needs-you', stateRaw: 'working' }), 'red');
  assert.equal(healthLevel({ group: 'blocked', stateRaw: 'blocked' }), 'red');
});

test('healthLevel maps a stale raw state to yellow even inside the working group', () => {
  assert.equal(healthLevel({ group: 'working', stateRaw: 'stale' }), 'yellow');
});

test('healthLevel maps provably working/ready to green', () => {
  assert.equal(healthLevel({ group: 'working', stateRaw: 'working' }), 'green');
  assert.equal(healthLevel({ group: 'ready', stateRaw: 'ready' }), 'green');
});

test('healthLevel maps done and unknown/unrecognized state to dim grey, not a false green or yellow', () => {
  assert.equal(healthLevel({ group: 'done', stateRaw: 'done' }), 'grey');
  assert.equal(healthLevel({ group: 'working', stateRaw: 'unknown' }), 'grey');
  assert.equal(healthLevel({ group: undefined, stateRaw: undefined }), 'grey');
});

test('groupCards preserves order within a group', () => {
  const cards = [
    { id: 'a', group: 'working' },
    { id: 'b', group: 'done' },
    { id: 'c', group: 'working' },
  ];
  const g = groupCards(cards);
  assert.deepEqual(g.get('working').map((c) => c.id), ['a', 'c']);
  assert.deepEqual(g.get('done').map((c) => c.id), ['b']);
});

test('backlogCounts counts queued and blocked from snapshot records', () => {
  const snap = {
    backlog: {
      records: [
        { state: 'queued', blocked_by: null },
        { state: 'queued', blocked_by: 'other' },
        { state: 'in-flight', blocked_by: null },
        { state: 'done', blocked_by: null },
      ],
    },
  };
  assert.deepEqual(backlogCounts(snap), { queued: 2, blocked: 1 });
});

test('backlogCounts is safe on a missing/empty backlog', () => {
  assert.deepEqual(backlogCounts(null), { queued: 0, blocked: 0 });
  assert.deepEqual(backlogCounts({}), { queued: 0, blocked: 0 });
});

test('watcherAlive respects the grace window and a missing beacon', () => {
  assert.equal(watcherAlive(1000, 1100, 300), true);
  assert.equal(watcherAlive(1000, 1400, 300), false);
  assert.equal(watcherAlive(null, 1100, 300), false);
});

test('buildHeader composes disk/watcher/afk/backlog into one model', () => {
  const header = buildHeader({
    diskFree: 5000,
    diskUsePct: 42,
    watcherBeatSecs: 1000,
    nowSecs: 1100,
    afkPresent: true,
    snapshot: { backlog: { records: [{ state: 'queued', blocked_by: null }] } },
    inFlightCount: 3,
  });
  assert.equal(header.diskFree, 5000);
  assert.equal(header.diskUsePct, 42);
  assert.equal(header.watcherAlive, true);
  assert.equal(header.afk, true);
  assert.equal(header.inFlight, 3);
  assert.equal(header.queued, 1);
  assert.equal(header.blocked, 0);
});

test('buildHeader defaults inFlight to 0 when not passed', () => {
  const header = buildHeader({ nowSecs: 1100 });
  assert.equal(header.inFlight, 0);
});

test('boardSections splits cards into inFlight (non-done) and done, preserving order', () => {
  const cards = [
    { id: 'a', group: 'working' },
    { id: 'b', group: 'done' },
    { id: 'c', group: 'needs-you' },
    { id: 'd', group: 'done' },
  ];
  const { inFlight, done, inFlightGrouped } = boardSections(cards);
  assert.deepEqual(inFlight.map((c) => c.id), ['a', 'c']);
  assert.deepEqual(done.map((c) => c.id), ['b', 'd']);
  assert.deepEqual(inFlightGrouped.get('working').map((c) => c.id), ['a']);
  assert.deepEqual(inFlightGrouped.get('needs-you').map((c) => c.id), ['c']);
});

test('boardSections reports a live meta-derived task as in flight even when its state is unknown', () => {
  // Regression guard for the snapshot visibility bug: a torn-down-worktree or
  // backend-target-gone task still reports current_state.state === 'unknown',
  // which groupForTask maps to 'working' (visible), so it must land in
  // inFlight, never silently dropped.
  const card = buildCard({ id: 'smm-ota-manifest-stamp-scout-v2', kind: 'scout', current_state: { state: 'unknown' } });
  const { inFlight } = boardSections([card]);
  assert.deepEqual(inFlight.map((c) => c.id), ['smm-ota-manifest-stamp-scout-v2']);
});

test('queuedBacklogRecords keeps only structured queued rows, in snapshot order', () => {
  const snapshot = {
    backlog: {
      records: [
        { structured: true, state: 'queued', id: 'a' },
        { structured: true, state: 'in_flight', id: 'b' },
        { structured: false, state: 'queued', id: null },
        { structured: true, state: 'queued', id: 'c' },
        { structured: true, state: 'done', id: 'd' },
      ],
    },
  };
  assert.deepEqual(queuedBacklogRecords(snapshot).map((r) => r.id), ['a', 'c']);
});

test('queuedBacklogRecords is safe on a missing/empty backlog', () => {
  assert.deepEqual(queuedBacklogRecords(null), []);
  assert.deepEqual(queuedBacklogRecords({}), []);
});

test('recentDoneBacklogRecords returns structured done rows, most-recent-first, capped at limit', () => {
  const snapshot = {
    backlog: {
      records: [
        { structured: true, state: 'done', id: 'a' },
        { structured: true, state: 'queued', id: 'x' },
        { structured: true, state: 'done', id: 'b' },
        { structured: true, state: 'done', id: 'c' },
      ],
    },
  };
  assert.deepEqual(recentDoneBacklogRecords(snapshot, 2).map((r) => r.id), ['c', 'b']);
  assert.deepEqual(recentDoneBacklogRecords(snapshot, 10).map((r) => r.id), ['c', 'b', 'a']);
});

test('computeRowBudget never returns a non-positive row count, even at the tightest realistic terminal size', () => {
  // Regression guard: Ink has no scrolling, so a section handed 0 or fewer
  // rows than it needs is exactly the failure mode that corrupted the board
  // during development (a fixed-height flex tree fed more content than it had
  // space for silently blanked card id lines instead of clipping cleanly).
  for (const height of [10, 20, 24, 30, 40, 60, 100]) {
    for (const hasFooter of [true, false]) {
      for (const hasInFlight of [true, false]) {
        const budget = computeRowBudget({ height, hasFooter, hasInFlight });
        assert.ok(budget.inFlightRows >= 1, `inFlightRows at height=${height}`);
        assert.ok(budget.queuedRows >= 1, `queuedRows at height=${height}`);
        assert.ok(budget.doneRows >= 1, `doneRows at height=${height}`);
      }
    }
  }
});

test('computeRowBudget gives IN FLIGHT a larger share when something is in flight than when the fleet is empty', () => {
  const withWork = computeRowBudget({ height: 40, hasFooter: true, hasInFlight: true });
  const empty = computeRowBudget({ height: 40, hasFooter: true, hasInFlight: false });
  assert.ok(withWork.inFlightRows > empty.inFlightRows);
  // The degraded-state requirement: when nothing is in flight, QUEUED/RECENT
  // DONE must get MORE room, not less, so the board never shows a void.
  assert.ok(empty.queuedRows >= withWork.queuedRows);
  assert.ok(empty.doneRows >= withWork.doneRows);
});

test('computeRowBudget grows all three sections as the terminal gets taller', () => {
  const short = computeRowBudget({ height: 24, hasFooter: false, hasInFlight: true });
  const tall = computeRowBudget({ height: 60, hasFooter: false, hasInFlight: true });
  assert.ok(tall.inFlightRows > short.inFlightRows);
  assert.ok(tall.queuedRows >= short.queuedRows);
  assert.ok(tall.doneRows >= short.doneRows);
});

test('computeRowBudget shrinks IN FLIGHT to its actual content and hands the freed rows to the bottom sections', () => {
  // The core fix for the "half-empty box" problem: a single small card must
  // not reserve the same acreage as computeRowBudget's fair-share ceiling.
  const fairShare = computeRowBudget({ height: 60, hasFooter: false, hasInFlight: true });
  const oneCard = computeRowBudget({ height: 60, hasFooter: false, hasInFlight: true, inFlightContentRows: 3 });
  assert.ok(oneCard.inFlightRows < fairShare.inFlightRows, 'a small card must shrink below the fair-share ceiling');
  assert.equal(oneCard.inFlightRows, 4, 'content rows (3) plus 1 row of margin');
  // Whatever IN FLIGHT no longer claims flows to QUEUED/RECENT DONE.
  assert.ok(oneCard.queuedRows + oneCard.doneRows > fairShare.queuedRows + fairShare.doneRows);
});

test('computeRowBudget caps IN FLIGHT at the fair-share ceiling when content exceeds it, never growing past it', () => {
  const budget = computeRowBudget({ height: 40, hasFooter: false, hasInFlight: true, inFlightContentRows: 999 });
  const fairShare = computeRowBudget({ height: 40, hasFooter: false, hasInFlight: true });
  assert.equal(budget.inFlightRows, fairShare.inFlightRows);
});

test('computeRowBudget never returns a non-positive row count across a range of inFlightContentRows values', () => {
  for (const height of [10, 20, 24, 30, 40, 60, 100]) {
    for (const inFlightContentRows of [null, 0, 1, 3, 10, 999]) {
      const budget = computeRowBudget({ height, hasFooter: true, hasInFlight: true, inFlightContentRows });
      assert.ok(budget.inFlightRows >= 1, `inFlightRows at height=${height}, content=${inFlightContentRows}`);
      assert.ok(budget.queuedRows >= 1, `queuedRows at height=${height}, content=${inFlightContentRows}`);
      assert.ok(budget.doneRows >= 1, `doneRows at height=${height}, content=${inFlightContentRows}`);
    }
  }
});

test('inFlightContentRowCount sums a label row plus CARD_ROW_HEIGHT per card, across only non-empty groups', () => {
  const grouped = new Map([
    ['needs-you', [{ id: 'a' }]],
    ['working', [{ id: 'b' }, { id: 'c' }]],
  ]);
  // 1 label + 2 card rows (needs-you) + 1 label + 4 card rows (working) = 8.
  assert.equal(inFlightContentRowCount(grouped), 8);
});

test('inFlightContentRowCount is 0 for an empty grouping', () => {
  assert.equal(inFlightContentRowCount(new Map()), 0);
});

test('firstmateActivityLines returns null/empty input as an empty list', () => {
  assert.deepEqual(firstmateActivityLines(null, 10), []);
  assert.deepEqual(firstmateActivityLines('', 10), []);
  assert.deepEqual(firstmateActivityLines(undefined, 10), []);
});

test('firstmateActivityLines drops trailing blank rows from a short-busy pane capture', () => {
  const raw = 'line one\nline two\n\n\n\n';
  assert.deepEqual(firstmateActivityLines(raw, 10), ['line one', 'line two']);
});

test('firstmateActivityLines tails to the last maxLines entries, newest at the bottom, in original order', () => {
  const raw = Array.from({ length: 10 }, (_, i) => `line ${i}`).join('\n');
  const tailed = firstmateActivityLines(raw, 3);
  assert.deepEqual(tailed, ['line 7', 'line 8', 'line 9']);
});

test('firstmateActivityLines returns every line unchanged when under the maxLines budget', () => {
  const raw = 'a\nb\nc';
  assert.deepEqual(firstmateActivityLines(raw, 10), ['a', 'b', 'c']);
});

test('firstmateActivityLines with a null maxLines returns every line (minus trailing blanks), no cap', () => {
  const raw = Array.from({ length: 50 }, (_, i) => `line ${i}`).join('\n');
  assert.equal(firstmateActivityLines(raw, null).length, 50);
});

// buildLabBuildCard: the MOBILE LAB view-model builder, exercised against
// fixtures shaped exactly like data/mobile-lab-status-contract.md v1 - a
// running build with a numeric percent, a running build with percent: null
// (the honest-indeterminate case), a terminal success, and a terminal
// failure, plus the required defensive paths (malformed JSON, absent file,
// partial/missing fields).

const CONTRACT_RUNNING_PERCENT = {
  schema: 1,
  slot: 'dashpivot-mobile-0',
  repo: 'dashpivot-mobile',
  branch: 'release/26.9',
  platform: 'device',
  target: "Thev's iPhone (iOS 26.5)",
  run_command: "react-native run-ios --scheme 'Dashpivot Dev'",
  port: 8111,
  phase: 'compile',
  phase_index: 5,
  phase_total: 7,
  percent: 62,
  status: 'running',
  started_epoch: 1000,
  updated_epoch: 1123,
  phase_started_epoch: 1100,
  message: 'Compiling React-Core (1240/2100)',
  logfile: 'state/build-dashpivot-mobile-0.log',
  error: null,
};

test('buildLabBuildCard derives the full card from a running/percent-known contract fixture', () => {
  const card = buildLabBuildCard({ slot: 'dashpivot-mobile-0', raw: CONTRACT_RUNNING_PERCENT, parseError: null }, 1130);
  assert.equal(card.available, true);
  assert.equal(card.slot, 'dashpivot-mobile-0');
  assert.equal(card.repo, 'dashpivot-mobile');
  assert.equal(card.branch, 'release/26.9');
  assert.equal(card.platform, 'device');
  assert.equal(card.target, "Thev's iPhone (iOS 26.5)");
  assert.equal(card.phase, 'compile');
  assert.equal(card.phaseKnown, true);
  assert.equal(card.phaseIndex, 5);
  assert.equal(card.phaseTotal, 7);
  assert.equal(card.percent, 62);
  assert.equal(card.percentUnknown, false);
  assert.equal(card.status, 'running');
  assert.equal(card.totalElapsedSecs, 130);
  assert.equal(card.phaseElapsedSecs, 30);
  assert.equal(card.ageSecs, 7);
  assert.equal(card.message, 'Compiling React-Core (1240/2100)');
  assert.equal(card.logfile, 'state/build-dashpivot-mobile-0.log');
  assert.equal(card.error, null);
  assert.equal(card.heartbeat, 'green');
});

test('buildLabBuildCard marks a running build stale (amber) once updated_epoch falls outside the fresh window', () => {
  const card = buildLabBuildCard({ slot: 's', raw: CONTRACT_RUNNING_PERCENT, parseError: null }, 1123 + 30);
  assert.equal(card.heartbeat, 'amber');
});

test('buildLabBuildCard renders percent: null as an honest indeterminate meter, never a fake percent', () => {
  const raw = { ...CONTRACT_RUNNING_PERCENT, phase: 'pods', phase_index: 3, percent: null };
  const card = buildLabBuildCard({ slot: 's', raw, parseError: null }, 1130);
  assert.equal(card.percent, null);
  assert.equal(card.percentUnknown, true);
});

test('buildLabBuildCard maps a terminal success status to a green heartbeat regardless of age', () => {
  const raw = { ...CONTRACT_RUNNING_PERCENT, status: 'success', percent: 100, phase: 'install', phase_index: 7 };
  const card = buildLabBuildCard({ slot: 's', raw, parseError: null }, 1123 + 999999);
  assert.equal(card.status, 'success');
  assert.equal(card.heartbeat, 'green');
});

test('buildLabBuildCard maps a terminal failure to a red heartbeat and surfaces error + logfile', () => {
  const raw = {
    ...CONTRACT_RUNNING_PERCENT,
    status: 'failed',
    phase: 'link',
    phase_index: 6,
    error: 'libavcodec has no arm64-simulator slice; use --device',
  };
  const card = buildLabBuildCard({ slot: 's', raw, parseError: null }, 1123 + 999999);
  assert.equal(card.status, 'failed');
  assert.equal(card.heartbeat, 'red');
  assert.equal(card.error, 'libavcodec has no arm64-simulator slice; use --device');
  assert.equal(card.logfile, 'state/build-dashpivot-mobile-0.log');
});

test('buildLabBuildCard falls back gracefully on a phase name outside the canonical set (forward-compat)', () => {
  const raw = { ...CONTRACT_RUNNING_PERCENT, phase: 'some-future-phase' };
  const card = buildLabBuildCard({ slot: 's', raw, parseError: null }, 1130);
  assert.equal(card.available, true);
  assert.equal(card.phaseKnown, false);
  assert.equal(card.phase, 'some-future-phase');
});

test('buildLabBuildCard renders a parse-error entry as unavailable, never throwing', () => {
  const card = buildLabBuildCard({ slot: 'broken-slot', raw: null, parseError: 'Unexpected token m in JSON' }, 1130);
  assert.equal(card.available, false);
  assert.equal(card.slot, 'broken-slot');
  assert.match(card.error, /Unexpected token/);
});

test('buildLabBuildCard renders a missing/empty raw entry as unavailable, never throwing', () => {
  assert.equal(buildLabBuildCard({ slot: 's', raw: null, parseError: null }, 1130).available, false);
  assert.equal(buildLabBuildCard({ slot: 's', raw: undefined, parseError: null }, 1130).available, false);
  assert.equal(buildLabBuildCard(undefined, 1130).available, false);
});

test('buildLabBuildCard defaults every field defensively on a partial/malformed-shape object, never throwing', () => {
  // Not a parse error (valid JSON), but a shape that violates the contract:
  // wrong types, missing fields entirely. Every field must default cleanly.
  const raw = { slot: 'x', percent: 'not-a-number', phase_index: 'nope', status: 42, updated_epoch: 'nope' };
  const card = buildLabBuildCard({ slot: 'weird-shape', raw, parseError: null }, 1130);
  assert.equal(card.available, true);
  assert.equal(card.percent, null);
  assert.equal(card.percentUnknown, true);
  assert.equal(card.phaseIndex, null);
  assert.equal(card.phaseKnown, false);
  assert.equal(card.repo, null);
  assert.equal(card.branch, null);
  assert.equal(card.message, '');
  assert.equal(card.ageSecs, null);
  // status is not a string, so the default('running')-shaped fallback still
  // applies via str()'s typeof guard - never a crash on a wrong-typed field.
  assert.equal(card.status, 'running');
});

test('buildLabBuildCard clamps an out-of-range percent into 0-100', () => {
  assert.equal(buildLabBuildCard({ slot: 's', raw: { ...CONTRACT_RUNNING_PERCENT, percent: 140 }, parseError: null }, 1130).percent, 100);
  assert.equal(buildLabBuildCard({ slot: 's', raw: { ...CONTRACT_RUNNING_PERCENT, percent: -5 }, parseError: null }, 1130).percent, 0);
});

test('buildLabBuildCards sorts by most-recently-updated first and includes unavailable entries', () => {
  const entries = [
    { slot: 'old', raw: { ...CONTRACT_RUNNING_PERCENT, updated_epoch: 100 }, parseError: null },
    { slot: 'new', raw: { ...CONTRACT_RUNNING_PERCENT, updated_epoch: 500 }, parseError: null },
    { slot: 'broken', raw: null, parseError: 'bad json' },
  ];
  const cards = buildLabBuildCards(entries, 600);
  assert.deepEqual(cards.map((c) => c.slot), ['new', 'old', 'broken']);
  assert.equal(cards[2].available, false);
});

test('buildLabBuildCards returns an empty list for no entries, never throwing', () => {
  assert.deepEqual(buildLabBuildCards([], 100), []);
  assert.deepEqual(buildLabBuildCards(null, 100), []);
  assert.deepEqual(buildLabBuildCards(undefined, 100), []);
});
