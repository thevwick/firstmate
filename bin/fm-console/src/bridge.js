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
// Supervisor-target resolution is fail-closed. The console runs in its own
// terminal tab, so its own runtime pane signals ($TMUX_PANE / $HERDR_PANE_ID)
// point at the CONSOLE, not at firstmate's pane - auto-detecting from them would
// send commands to the console itself. The console therefore requires an
// explicit target rather than guessing. It reuses the away-mode daemon's
// FM_SUPERVISOR_TARGET / FM_SUPERVISOR_BACKEND conventions (documented in
// docs/configuration.md "Away-mode supervisor backend"), so a captain who has
// set those for /afk gets the bridge for free.

import path from 'node:path';
import { run } from './io.js';

// Resolve the primary firstmate pane the bridge sends into. Returns
// { target, backend, source } on success, or { error } when it cannot be
// resolved safely. Never falls back to the console's own pane.
export function resolveSupervisor(env = process.env) {
  const target = env.FM_SUPERVISOR_TARGET;
  const backend = env.FM_SUPERVISOR_BACKEND;
  if (target && target.trim()) {
    return {
      target: target.trim(),
      // Backend is optional for fm-send (it can infer tmux/herdr from the
      // target shape), but pass it through when the captain set it.
      backend: backend && backend.trim() ? backend.trim() : null,
      source: 'FM_SUPERVISOR_TARGET',
    };
  }
  return {
    error:
      'No primary session target set. Export FM_SUPERVISOR_TARGET (and optionally ' +
      'FM_SUPERVISOR_BACKEND) to the pane running firstmate, then relaunch. ' +
      'The console will not guess a pane.',
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
