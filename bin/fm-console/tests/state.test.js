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
  };
  const card = buildCard(task, { duBytes: 2048, prChecks: 'passing' });
  assert.equal(card.id, 'login-k3');
  assert.equal(card.repo, 'yourapp');
  assert.equal(card.group, 'working');
  assert.equal(card.worktreePath, '/wt/login-k3');
  assert.equal(card.duBytes, 2048);
  assert.equal(card.prUrl, 'https://github.com/o/r/pull/5');
  assert.equal(card.prChecks, 'passing');
  assert.equal(card.lastEvent, 'implementing fix');
});

test('buildCard defaults du/pr to null when not yet computed', () => {
  const card = buildCard({ id: 'x', current_state: { state: 'working' } });
  assert.equal(card.duBytes, null);
  assert.equal(card.prChecks, null);
  assert.equal(card.ticket, null);
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
  });
  assert.equal(header.diskFree, 5000);
  assert.equal(header.diskUsePct, 42);
  assert.equal(header.watcherAlive, true);
  assert.equal(header.afk, true);
  assert.equal(header.queued, 1);
  assert.equal(header.blocked, 0);
});
