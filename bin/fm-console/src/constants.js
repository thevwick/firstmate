// Tunable constants for fm-console. Kept in one place so cadence and thresholds
// are named, not scattered as magic numbers through the UI.

// How often the board re-reads firstmate state and redraws, in milliseconds.
export const REFRESH_INTERVAL_MS = 2000;

// How often a task's worktree size (du) is recomputed, in milliseconds.
// du walks the whole worktree, so it runs on a slower cadence than the board
// refresh and never blocks a redraw.
export const DU_INTERVAL_MS = 15000;

// The watcher's liveness beacon (state/.last-watcher-beat) is considered fresh
// when it was touched within this many seconds. Mirrors fm-guard.sh's default
// FM_GUARD_GRACE so the console and the guard agree on "is a watcher alive".
export const WATCHER_GRACE_SECS = 300;

// The macOS Data volume the engine's disk-pressure header watches. This is the
// one macOS-correct path the console hardcodes (the engine assumes macOS); the
// rest of the console is generic firstmate state only.
export const DATA_VOLUME = '/System/Volumes/Data';

// Card group order, top to bottom. Keys map to task states derived in state.js.
export const GROUP_ORDER = ['needs-you', 'ready', 'working', 'blocked', 'done'];

export const GROUP_LABELS = {
  'needs-you': 'NEEDS YOU',
  ready: 'READY',
  working: 'WORKING',
  blocked: 'BLOCKED',
  done: 'DONE',
};
