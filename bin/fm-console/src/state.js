// Pure state derivation. No I/O lives here: functions take already-read data
// (the fm-fleet-snapshot.sh --json object, file mtimes, du output) and return
// the shape the UI renders. This is what the unit tests exercise directly.
//
// The snapshot itself is the one owner of fleet parsing (bin/fm-fleet-snapshot.sh);
// the console never re-parses backlog.md or meta files. It only reshapes the
// snapshot into cards and computes a few header facts the snapshot omits
// (disk, watcher liveness, afk), which are cheap, console-local reads.

import { WATCHER_GRACE_SECS } from './constants.js';

// Extract a ticket chip from a task's branch name or brief text, if one is
// present. A ticket is OPTIONAL metadata: many tasks (e.g. poc/* work) have
// none and must render as first-class without it. The pattern is a generic
// uppercase project key plus digits (SMM-2808, DPW-11976), never a hardcoded
// project list. Returns the ticket string or null.
export function extractTicket(sources) {
  const TICKET_RE = /\b([A-Z][A-Z0-9]{1,9}-\d+)\b/;
  for (const s of sources) {
    if (!s) continue;
    const m = String(s).match(TICKET_RE);
    if (m) return m[1];
  }
  return null;
}

// Map a snapshot task's current_state + hints into one of the console's card
// groups. Ordering of checks matters: a decision or block that needs the
// captain wins over a plain working state.
export function groupForTask(task) {
  const state = task?.current_state?.state || 'unknown';
  const hints = task?.hints || {};

  if (hints.pending_decision) return 'needs-you';
  if (hints.blocked_event || state === 'blocked') return 'blocked';

  switch (state) {
    case 'needs-decision':
      return 'needs-you';
    case 'done':
    case 'passed':
    case 'checks-passed':
    case 'merged':
      return 'done';
    case 'failed':
    case 'cancelled':
      // A failure needs the captain's attention above routine working cards.
      return 'needs-you';
    case 'ready':
      return 'ready';
    case 'working':
    case 'running':
    case 'fixing':
    case 'ci':
      return 'working';
    default:
      // Unknown/absent state: surface it as working so it is visible rather
      // than hidden, but it will show its raw state string on the card.
      return 'working';
  }
}

// Build a console card from one snapshot task. Pure: du size and PR-check
// status are threaded in from async side-channels keyed by task id, defaulting
// to null when not yet computed.
export function buildCard(task, { duBytes = null, prChecks = null } = {}) {
  const meta = task?.paths || {};
  const worktreePath = meta.worktree?.path || null;
  const ticket = extractTicket([task?.branch, task?.brief_excerpt, task?.id]);
  const lastEvent =
    task?.hints?.last_event_text ||
    meta.status_log?.last_event?.raw ||
    '';

  return {
    id: task?.id || '(unknown)',
    ticket,
    repo: shortRepo(task?.project),
    kind: task?.kind || 'ship',
    group: groupForTask(task),
    stateRaw: task?.current_state?.state || 'unknown',
    stateDetail: task?.current_state?.detail || '',
    lastEvent: String(lastEvent).trim(),
    worktreePath,
    duBytes,
    prUrl: task?.pr?.url || null,
    prChecks,
    endpointExists: task?.endpoint?.exists === true,
  };
}

// Reduce a full project path to a short repo label for the card. The snapshot
// records project as an absolute path; the captain wants the basename.
export function shortRepo(project) {
  if (!project) return '';
  const parts = String(project).replace(/\/+$/, '').split('/');
  return parts[parts.length - 1] || project;
}

// Group cards by their console group, preserving snapshot order within a group.
// Returns a Map keyed by group name.
export function groupCards(cards) {
  const groups = new Map();
  for (const card of cards) {
    if (!groups.has(card.group)) groups.set(card.group, []);
    groups.get(card.group).push(card);
  }
  return groups;
}

// Derive backlog queued/blocked counts from the snapshot's backlog records.
// A record is queued when state === 'queued'; blocked when it also carries a
// blocked_by. This mirrors data/backlog.md's structure without re-parsing it.
export function backlogCounts(snapshot) {
  const records = snapshot?.backlog?.records || [];
  let queued = 0;
  let blocked = 0;
  for (const r of records) {
    if (r?.state !== 'queued') continue;
    queued += 1;
    if (r?.blocked_by) blocked += 1;
  }
  return { queued, blocked };
}

// Decide whether the watcher is alive, from the beacon file's mtime in epoch
// seconds and the current epoch. A missing beacon (mtimeSecs null) is dead.
// Grace mirrors fm-guard.sh (WATCHER_GRACE_SECS).
export function watcherAlive(mtimeSecs, nowSecs, grace = WATCHER_GRACE_SECS) {
  if (mtimeSecs == null) return false;
  return nowSecs - mtimeSecs <= grace;
}

// Compose the whole header model from the pieces the UI has read.
export function buildHeader({
  diskFree = null,
  diskUsePct = null,
  watcherBeatSecs = null,
  nowSecs,
  afkPresent = false,
  snapshot = null,
}) {
  const counts = backlogCounts(snapshot);
  return {
    diskFree,
    diskUsePct,
    watcherAlive: watcherAlive(watcherBeatSecs, nowSecs),
    afk: afkPresent === true,
    queued: counts.queued,
    blocked: counts.blocked,
  };
}
