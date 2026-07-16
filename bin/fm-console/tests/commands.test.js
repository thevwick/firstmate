// Unit tests for pure command composition and the bridge's target resolution.
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  QUICK_ACTIONS,
  composeQuickAction,
  actionForKey,
  isSendable,
  normalizeCommand,
} from '../src/commands.js';
import { resolveSupervisor } from '../src/bridge.js';

test('composeQuickAction builds a captain-style instruction', () => {
  assert.equal(composeQuickAction('merge', 'login-k3'), 'merge login-k3');
  assert.equal(composeQuickAction('status', 'x'), 'status x');
});

test('composeQuickAction rejects missing verb or id', () => {
  assert.throws(() => composeQuickAction('', 'x'));
  assert.throws(() => composeQuickAction('merge', ''));
});

test('destructive quick-actions are flagged so the UI can require a confirm', () => {
  const merge = actionForKey('m');
  const teardown = actionForKey('t');
  const status = actionForKey('s');
  assert.equal(merge.destructive, true);
  assert.equal(teardown.destructive, true);
  assert.equal(status.destructive, false);
});

test('actionForKey returns null for an unmapped key', () => {
  assert.equal(actionForKey('z'), null);
});

test('every quick-action verb maps to a real firstmate instruction shape', () => {
  for (const a of QUICK_ACTIONS) {
    assert.equal(composeQuickAction(a.verb, 'id-1'), `${a.verb} id-1`);
  }
});

test('isSendable rejects empty/whitespace-only lines', () => {
  assert.equal(isSendable('merge x'), true);
  assert.equal(isSendable(''), false);
  assert.equal(isSendable('   '), false);
  assert.equal(isSendable(null), false);
});

test('normalizeCommand strips trailing whitespace but keeps the body', () => {
  assert.equal(normalizeCommand('merge x\n'), 'merge x');
  assert.equal(normalizeCommand('  merge x  '), '  merge x');
});

test('resolveSupervisor uses FM_SUPERVISOR_TARGET and optional backend', () => {
  const r = resolveSupervisor({ FM_SUPERVISOR_TARGET: 'default:wG:p2', FM_SUPERVISOR_BACKEND: 'herdr' });
  assert.equal(r.target, 'default:wG:p2');
  assert.equal(r.backend, 'herdr');
  assert.equal(r.error, undefined);
});

test('resolveSupervisor omits backend when not set', () => {
  const r = resolveSupervisor({ FM_SUPERVISOR_TARGET: 'firstmate:0' });
  assert.equal(r.target, 'firstmate:0');
  assert.equal(r.backend, null);
});

test('resolveSupervisor is fail-closed: no target means no bridge, never a guess', () => {
  const r = resolveSupervisor({});
  assert.equal(r.target, undefined);
  assert.ok(r.error);
  // Must not fall back to the console's own pane signals.
  const r2 = resolveSupervisor({ TMUX_PANE: '%9', HERDR_PANE_ID: 'wZ:p9' });
  assert.ok(r2.error);
  assert.equal(r2.target, undefined);
});
