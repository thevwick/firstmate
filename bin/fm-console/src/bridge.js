// Command bridge: deliver the captain's typed/confirmed command into the
// RUNNING primary firstmate session, exactly as if the captain had typed it in
// that pane. It does this by shelling out to bin/fm-send.sh with an explicit
// backend target, so fm-send's verified-submit, busy-guard, and composer-guard
// machinery applies unchanged - a command sent mid-turn defers cleanly instead
// of colliding. The console adds NO keystroke injection of its own and NO
// approval bypass: firstmate still gates merges, teardowns, and destructive
// actions exactly as before. The bridge only changes WHERE the captain issues a
// command, never WHAT is allowed without approval.
//
// Supervisor-target resolution is fail-closed but no longer requires a manual
// export on every launch: it reuses the away-mode daemon's own auto-detect
// order (FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND override, then
// $TMUX_PANE, then $HERDR_ENV=1 + $HERDR_PANE_ID - see resolveSupervisor
// below and docs/configuration.md "Away-mode supervisor backend"). A captain
// who already set FM_SUPERVISOR_TARGET for /afk gets the bridge for free, as
// before. When the console runs in a genuinely separate terminal tab whose
// own pane env points at the console rather than firstmate, none of these
// resolve to firstmate's pane and the bridge stays disabled with the warning
// below - it never falls back to a guess.

import path from 'node:path';
import { run } from './io.js';

// Resolve the primary firstmate pane the bridge sends into. Returns
// { target, backend, source } on success, or { error } when it cannot be
// resolved safely. Never falls back to the console's own pane.
//
// Priority mirrors bin/fm-supervise-daemon.sh's discover_supervisor_target /
// discover_supervisor_backend (docs/configuration.md "Away-mode supervisor
// backend"), reused rather than reinvented so the two auto-detect paths never
// drift apart:
//   1. FM_SUPERVISOR_TARGET / FM_SUPERVISOR_BACKEND - an explicit override.
//   2. $TMUX_PANE - tmux sets this in every pane's environment; when the
//      console inherits firstmate's own pane env (e.g. launched as a child
//      of the primary session rather than a separately-opened tab) this
//      resolves to the real primary pane.
//   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr's equivalent, composed into the
//      "<session>:<pane-id>" target the herdr adapter expects.
// This is auto-DETECTION of an already-verified signal, never a guess: if
// none of the above resolve, the bridge stays disabled with the same fail-
// closed warning as before. It never falls back to firstmate's legacy
// "firstmate:0" default the daemon uses, because a wrong guess here would
// silently send a captain's command into an arbitrary pane.
export function resolveSupervisor(env = process.env) {
  const explicitTarget = env.FM_SUPERVISOR_TARGET;
  const explicitBackend = env.FM_SUPERVISOR_BACKEND;
  if (explicitTarget && explicitTarget.trim()) {
    return {
      target: explicitTarget.trim(),
      // Backend is optional for fm-send (it can infer tmux/herdr from the
      // target shape), but pass it through when the captain set it.
      backend: explicitBackend && explicitBackend.trim() ? explicitBackend.trim() : null,
      source: 'FM_SUPERVISOR_TARGET',
    };
  }

  const tmuxPane = env.TMUX_PANE;
  if (tmuxPane && tmuxPane.trim()) {
    return {
      target: tmuxPane.trim(),
      backend: 'tmux',
      source: 'TMUX_PANE',
    };
  }

  const herdrPaneId = env.HERDR_PANE_ID;
  if (env.HERDR_ENV === '1' && herdrPaneId && herdrPaneId.trim()) {
    const session = (env.HERDR_SESSION && env.HERDR_SESSION.trim()) || 'default';
    return {
      target: `${session}:${herdrPaneId.trim()}`,
      backend: 'herdr',
      source: 'HERDR_ENV',
    };
  }

  return {
    error:
      'No primary session target set and none could be auto-detected. Export ' +
      'FM_SUPERVISOR_TARGET (and optionally FM_SUPERVISOR_BACKEND) to the pane ' +
      'running firstmate, then relaunch. The console will not guess a pane.',
  };
}

// Send one command line into the primary session via fm-send.sh. The command
// text is passed verbatim as fm-send's message; fm-send owns the verified
// submit and defer-on-busy behavior. Returns { ok, code, stderr }.
//
// bin is the firstmate bin/ dir, home is FM_HOME. fm-send requires FM_HOME set
// and refuses unresolved targets, so an explicit, live backend target is what
// we hand it.
export async function sendCommand({ bin, home, target, command, env = process.env }) {
  const args = [target, command];
  try {
    const { code, stderr } = await run(path.join(bin, 'fm-send.sh'), args, {
      env: { ...env, FM_HOME: home },
      timeout: 30000,
    });
    return { ok: code === 0, code, stderr: (stderr || '').trim() };
  } catch (e) {
    return { ok: false, code: 'spawn-failed', stderr: e.message };
  }
}
