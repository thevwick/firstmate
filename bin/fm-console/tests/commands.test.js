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
  assert.equal(r.source, 'FM_SUPERVISOR_TARGET');
  assert.equal(r.error, undefined);
});

test('resolveSupervisor omits backend when not set', () => {
  const r = resolveSupervisor({ FM_SUPERVISOR_TARGET: 'firstmate:0' });
  assert.equal(r.target, 'firstmate:0');
  assert.equal(r.backend, null);
});

test('resolveSupervisor is fail-closed: no target and nothing auto-detectable means no bridge, never a guess', () => {
  const r = resolveSupervisor({});
  assert.equal(r.target, undefined);
  assert.ok(r.error);
});

test('resolveSupervisor auto-detects tmux from TMUX_PANE, mirroring the afk daemon', () => {
  const r = resolveSupervisor({ TMUX_PANE: '%9' });
  assert.equal(r.target, '%9');
  assert.equal(r.backend, 'tmux');
  assert.equal(r.source, 'TMUX_PANE');
  assert.equal(r.error, undefined);
});

test('resolveSupervisor auto-detects herdr from HERDR_ENV=1 + HERDR_PANE_ID, mirroring the afk daemon', () => {
  const r = resolveSupervisor({ HERDR_ENV: '1', HERDR_PANE_ID: 'p9', HERDR_SESSION: 'wZ' });
  assert.equal(r.target, 'wZ:p9');
  assert.equal(r.backend, 'herdr');
  assert.equal(r.source, 'HERDR_ENV');
  assert.equal(r.error, undefined);
});

test('resolveSupervisor defaults the herdr session to "default" when HERDR_SESSION is unset', () => {
  const r = resolveSupervisor({ HERDR_ENV: '1', HERDR_PANE_ID: 'p9' });
  assert.equal(r.target, 'default:p9');
  assert.equal(r.backend, 'herdr');
});

test('resolveSupervisor requires HERDR_ENV=1, not just HERDR_PANE_ID, before trusting herdr signals', () => {
  const r = resolveSupervisor({ HERDR_PANE_ID: 'p9' });
  assert.ok(r.error);
  assert.equal(r.target, undefined);
});

test('resolveSupervisor prefers an explicit FM_SUPERVISOR_TARGET over auto-detected pane signals', () => {
  const r = resolveSupervisor({
    FM_SUPERVISOR_TARGET: 'firstmate:0',
    TMUX_PANE: '%9',
    HERDR_ENV: '1',
    HERDR_PANE_ID: 'p9',
  });
  assert.equal(r.target, 'firstmate:0');
  assert.equal(r.source, 'FM_SUPERVISOR_TARGET');
});

test('resolveSupervisor prefers TMUX_PANE over herdr signals, mirroring the daemon nesting rule', () => {
  const r = resolveSupervisor({ TMUX_PANE: '%9', HERDR_ENV: '1', HERDR_PANE_ID: 'p9' });
  assert.equal(r.target, '%9');
  assert.equal(r.backend, 'tmux');
});

test('resolveSupervisor never falls back to a guessed default pane', () => {
  const r = resolveSupervisor({ SOME_UNRELATED_VAR: 'x' });
  assert.ok(r.error);
  assert.equal(r.target, undefined);
  assert.equal(r.backend, undefined);
});
